/* adaptive_autovacuum.c: one launcher, one cluster controller, per-database workers; policy is SQL. */

#include "postgres.h"

#include <errno.h>
#include <signal.h>
#include <sys/stat.h>
#ifdef WIN32
#include <windows.h>
#else
#include <unistd.h>
#endif

#include "access/heapam.h"
#include "access/htup_details.h"
#include "access/tableam.h"
#include "access/transam.h"
#include "access/xact.h"
#include "access/xlog.h"
#include "catalog/pg_database.h"
#include "catalog/pg_type_d.h"
#include "commands/vacuum.h"
#include "executor/spi.h"
#include "fmgr.h"
#include "funcapi.h"
#include "lib/stringinfo.h"
#include "libpq/pqsignal.h"
#include "miscadmin.h"
#include "nodes/makefuncs.h"
#include "nodes/parsenodes.h"
#include "pgstat.h"
#include "postmaster/bgworker.h"
#include "storage/fd.h"
#include "storage/ipc.h"
#include "storage/latch.h"
#include "storage/lwlock.h"
#include "storage/proc.h"
#include "storage/procarray.h"
#include "storage/shmem.h"
#include "storage/spin.h"
#include "utils/builtins.h"
#include "utils/guc.h"
#include "utils/json.h"
#include "utils/jsonb.h"
#include "utils/memutils.h"
#include "utils/rel.h"
#include "utils/resowner.h"
#include "utils/snapmgr.h"
#include "utils/timeout.h"
#include "utils/timestamp.h"
#include "utils/wait_event.h"

/* PG17 floor (dead_tuple_bytes columns); PG18-only surface degrades gracefully. */
#if PG_VERSION_NUM < 170000
#error "adaptive_autovacuum requires PostgreSQL 17 or later"
#endif

PG_MODULE_MAGIC;

PGDLLEXPORT void _PG_init(void);
PGDLLEXPORT void adaptive_autovacuum_launcher_main(Datum main_arg);
PGDLLEXPORT void adaptive_autovacuum_controller_main(Datum main_arg);
PGDLLEXPORT void adaptive_autovacuum_database_main(Datum main_arg);
PGDLLEXPORT void adaptive_autovacuum_emergency_main(Datum main_arg);

PG_FUNCTION_INFO_V1(adaptive_autovacuum_host_metrics);
PG_FUNCTION_INFO_V1(adaptive_autovacuum_controller_status);

static bool aav_enabled = true;
static char *aav_control_database = NULL;
static int aav_naptime_seconds = 60;
static int aav_max_database_workers = 2;
static int aav_database_worker_timeout_seconds = 3600;
static int aav_emergency_timeout_seconds = 86400;
static bool aav_log_cycle_summary = true;
/* Session-level handoff between the worker process and the SQL program it runs. */
static char *aav_worker_input = NULL;
static char *aav_worker_output = NULL;

static volatile sig_atomic_t aav_got_sigterm = false;
static volatile sig_atomic_t aav_got_sighup = false;
static volatile sig_atomic_t aav_emergency_timed_out = false;

/* Worker handoff files live under pg_stat_tmp: excluded from base backups, cleaned at startup. */
#define AAV_TMP_DIR PG_STAT_TMP_DIR "/adaptive_autovacuum"
#define AAV_PROGRAM_TAG "$aav_program$"
#define AAV_STATE_LEN 64


/* ---------- shared types ---------- */

typedef struct AAVHostMetrics
{
    double load1;
    int cpu_count;
    int64 mem_total_bytes;
    int64 mem_available_bytes;
} AAVHostMetrics;

typedef struct AAVDatabaseEntry
{
    Oid dboid;
    char *dbname;
    bool excluded;
} AAVDatabaseEntry;

/* Handed to the emergency worker through bgw_extra. */
typedef struct AAVEmergencyRequest
{
    int64 request_id;
    Oid dboid;
    Oid relid;
    int32 work_mem_mb;
    int32 cost_limit;
    int32 cost_delay_ms;
    int32 lock_timeout_ms;
    bool is_wraparound;
} AAVEmergencyRequest;

StaticAssertDecl(sizeof(AAVEmergencyRequest) <= BGW_EXTRALEN,
                 "AAVEmergencyRequest does not fit in bgw_extra");

/* One control plane per cluster: identity, sweep generation, emergency slot. */
typedef struct AAVSharedState
{
    slock_t mutex;
    pid_t launcher_pid;
    pid_t controller_pid;
    Oid control_database_oid;
    char controller_state[AAV_STATE_LEN];
    int controller_failures;
    TimestampTz controller_restart_at;
    pid_t emergency_worker_pid;
    Oid emergency_database_oid;
    int64 current_generation;
    int64 last_complete_generation;
    int expected_databases;
    int completed_databases;
    int failed_databases;
    TimestampTz generation_started_at;
    TimestampTz generation_completed_at;
    double observed_sweep_seconds;
} AAVSharedState;

static bool aav_preloaded = false;
static AAVSharedState *aav_shared_state = NULL;
static shmem_request_hook_type prev_shmem_request_hook = NULL;
static shmem_startup_hook_type prev_shmem_startup_hook = NULL;

static void aav_sigterm(SIGNAL_ARGS);
static void aav_sighup(SIGNAL_ARGS);
static void aav_shmem_request(void);
static void aav_shmem_startup(void);
static void aav_attach_shared_state(void);
static void aav_set_controller_state(const char *state);
static bool aav_try_acquire_emergency_slot(Oid dboid);
static void aav_release_emergency_slot(int code, Datum arg);
static void aav_release_controller_slot(int code, Datum arg);
static void aav_collect_host_metrics(AAVHostMetrics *metrics);
#ifdef __linux__
static bool aav_read_int64_file(const char *path, int64 *value);
static void aav_apply_cgroup_memory_limit(AAVHostMetrics *metrics);
#endif
#ifdef WIN32
static double aav_windows_cpu_busy_fraction(void);
#endif
static bool aav_lookup_control_database(const char *name, Oid *dboid, char **problem);
static bool aav_start_controller(Oid dboid, BackgroundWorkerHandle **handle);
static void aav_ensure_tmp_dir(void);
static void aav_tmp_path(char *buf, size_t len, const char *name);
static bool aav_write_file(const char *path, const char *text);
static char *aav_read_file(const char *path);
static bool aav_control_plane_ready(void);
static bool aav_policy_enabled(void);
static void aav_run_sweep(MemoryContext sweep_context);
static List *aav_discover_databases(void);
static char *aav_fetch_text(const char *sql, int nargs, Oid *argtypes, Datum *values, const char *nulls);
static bool aav_prepare_worker_input(const AAVDatabaseEntry *entry, int64 generation,
                                     const AAVHostMetrics *metrics);
static bool aav_absorb_worker_result(const AAVDatabaseEntry *entry, int64 generation,
                                     int *dup_installs, bool *emergency_pending);
static bool aav_start_database_worker(Oid dboid, const char *dbname,
                                      BackgroundWorkerHandle **handle);
static void aav_run_database_workers(List *databases, int64 generation,
                                     const AAVHostMetrics *metrics, int *completed, int *failed,
                                     int *dup_installs);
static void aav_run_global_controller(const AAVHostMetrics *metrics, int64 generation,
                                      bool complete);
static void aav_apply_global_settings(void);
static void aav_service_emergency(void);
static bool aav_start_emergency_worker(const AAVEmergencyRequest *request, const char *dbname,
                                       BackgroundWorkerHandle **handle);
static void aav_emergency_timeout_handler(void);
static void aav_run_emergency_vacuum(const AAVEmergencyRequest *request);
static void aav_abort_transaction_if_needed(void);
static char *aav_copy_error_message(void);

PGDLLEXPORT void
_PG_init(void)
{
    BackgroundWorker worker;

    /* On by default: installing (preload + CREATE EXTENSION) is the opt-in; off pauses the cluster. */
    DefineCustomBoolVariable("adaptive_autovacuum.enabled",
                             "Enable the adaptive autovacuum controller.",
                             "Cluster-wide switch, on by default; the cluster policy in the control database must also be enabled.",
                             &aav_enabled,
                             true,
                             PGC_SIGHUP,
                             0,
                             NULL,
                             NULL,
                             NULL);

    /* PGC_SIGHUP: a PGC_POSTMASTER custom GUC is FATAL when loaded on demand; read at controller start. */
    DefineCustomStringVariable("adaptive_autovacuum.control_database",
                               "Database holding the extension's persistent state.",
                               "Install the extension once, here; every connectable database is managed from it.",
                               &aav_control_database,
                               "postgres",
                               PGC_SIGHUP,
                               0,
                               NULL,
                               NULL,
                               NULL);

    /* Real revisit period = runtime of the databases ahead plus this naptime. */
    DefineCustomIntVariable("adaptive_autovacuum.naptime_seconds",
                            "Seconds the controller sleeps after finishing one sweep of all databases.",
                            NULL,
                            &aav_naptime_seconds,
                            60,
                            5,
                            86400,
                            PGC_SIGHUP,
                            GUC_UNIT_S,
                            NULL,
                            NULL,
                            NULL);

    /* Concurrent database workers so one slow database cannot delay the others; 1 = serial. */
    DefineCustomIntVariable("adaptive_autovacuum.max_database_workers",
                            "Database workers the controller may run concurrently.",
                            NULL,
                            &aav_max_database_workers,
                            2,
                            1,
                            16,
                            PGC_SIGHUP,
                            0,
                            NULL,
                            NULL,
                            NULL);

    DefineCustomIntVariable("adaptive_autovacuum.database_worker_timeout_seconds",
                            "Maximum time the controller waits for one database worker.",
                            "Covers the policy scan only; emergency VACUUMs run in a "
                            "dedicated worker governed by emergency_timeout_seconds.",
                            &aav_database_worker_timeout_seconds,
                            3600,
                            10,
                            86400,
                            PGC_SIGHUP,
                            GUC_UNIT_S,
                            NULL,
                            NULL,
                            NULL);

    /* Own, longer budget for emergency VACUUMs (worker timeout livelocked them); 0 = off. */
    DefineCustomIntVariable("adaptive_autovacuum.emergency_timeout_seconds",
                            "Maximum runtime of one guarded emergency VACUUM.",
                            "Applies per queued relation inside the dedicated emergency worker; 0 disables the limit.",
                            &aav_emergency_timeout_seconds,
                            86400,
                            0,
                            604800,
                            PGC_SIGHUP,
                            GUC_UNIT_S,
                            NULL,
                            NULL,
                            NULL);

    DefineCustomBoolVariable("adaptive_autovacuum.log_cycle_summary",
                             "Log one summary line per database scan and per sweep.",
                             NULL,
                             &aav_log_cycle_summary,
                             true,
                             PGC_SIGHUP,
                             0,
                             NULL,
                             NULL,
                             NULL);

    /* Handoff slots for the database program: set by the worker, read by the program, and back. */
    DefineCustomStringVariable("adaptive_autovacuum.worker_input",
                               "Internal: input document of the running database program.",
                               NULL,
                               &aav_worker_input,
                               "",
                               PGC_SUSET,
                               GUC_NO_SHOW_ALL | GUC_NOT_IN_SAMPLE | GUC_DISALLOW_IN_FILE,
                               NULL,
                               NULL,
                               NULL);
    DefineCustomStringVariable("adaptive_autovacuum.worker_output",
                               "Internal: output document of the running database program.",
                               NULL,
                               &aav_worker_output,
                               "",
                               PGC_SUSET,
                               GUC_NO_SHOW_ALL | GUC_NOT_IN_SAMPLE | GUC_DISALLOW_IN_FILE,
                               NULL,
                               NULL,
                               NULL);

    MarkGUCPrefixReserved("adaptive_autovacuum");

    aav_preloaded = process_shared_preload_libraries_in_progress;
    if (!aav_preloaded)
        return;

    prev_shmem_request_hook = shmem_request_hook;
    shmem_request_hook = aav_shmem_request;
    prev_shmem_startup_hook = shmem_startup_hook;
    shmem_startup_hook = aav_shmem_startup;

    MemSet(&worker, 0, sizeof(worker));
    snprintf(worker.bgw_name, BGW_MAXLEN, "adaptive autovacuum launcher");
    snprintf(worker.bgw_type, BGW_MAXLEN, "adaptive autovacuum launcher");
    worker.bgw_flags = BGWORKER_SHMEM_ACCESS |
                       BGWORKER_BACKEND_DATABASE_CONNECTION;
    worker.bgw_start_time = BgWorkerStart_RecoveryFinished;
    worker.bgw_restart_time = 10;
    snprintf(worker.bgw_library_name, MAXPGPATH, "adaptive_autovacuum");
    snprintf(worker.bgw_function_name, BGW_MAXLEN,
             "adaptive_autovacuum_launcher_main");
    worker.bgw_main_arg = (Datum) 0;
    worker.bgw_notify_pid = 0;

    RegisterBackgroundWorker(&worker);
}

static void
aav_shmem_request(void)
{
    if (prev_shmem_request_hook != NULL)
        prev_shmem_request_hook();

    RequestAddinShmemSpace(MAXALIGN(sizeof(AAVSharedState)));
}

static void
aav_shmem_startup(void)
{
    if (prev_shmem_startup_hook != NULL)
        prev_shmem_startup_hook();

    aav_attach_shared_state();
}

static void
aav_attach_shared_state(void)
{
    bool found;

    LWLockAcquire(AddinShmemInitLock, LW_EXCLUSIVE);
    aav_shared_state = ShmemInitStruct("adaptive autovacuum shared state",
                                      sizeof(AAVSharedState),
                                      &found);
    if (!found)
    {
        MemSet(aav_shared_state, 0, sizeof(AAVSharedState));
        SpinLockInit(&aav_shared_state->mutex);
        strlcpy(aav_shared_state->controller_state, "not started", AAV_STATE_LEN);
    }
    LWLockRelease(AddinShmemInitLock);
}

static void
aav_set_controller_state(const char *state)
{
    if (aav_shared_state == NULL)
        return;
    SpinLockAcquire(&aav_shared_state->mutex);
    strlcpy(aav_shared_state->controller_state, state, AAV_STATE_LEN);
    SpinLockRelease(&aav_shared_state->mutex);
}

/* SQL: adaptive_autovacuum.controller_status() - controller identity and sweep-generation tracking. */
Datum
adaptive_autovacuum_controller_status(PG_FUNCTION_ARGS)
{
    TupleDesc tupdesc;
    Datum values[15];
    bool nulls[15];
    AAVSharedState snap;
    bool available = false;

    if (get_call_result_type(fcinfo, NULL, &tupdesc) != TYPEFUNC_COMPOSITE)
        elog(ERROR, "return type must be a row type");

    /* Without preload there is no shared state to attach to. */
    if (aav_shared_state == NULL && aav_preloaded)
        aav_attach_shared_state();

    MemSet(&snap, 0, sizeof(snap));
    if (aav_shared_state != NULL)
    {
        available = true;
        SpinLockAcquire(&aav_shared_state->mutex);
        snap = *aav_shared_state;
        SpinLockRelease(&aav_shared_state->mutex);
    }

    MemSet(nulls, 0, sizeof(nulls));
    values[0] = BoolGetDatum(available);
    values[1] = Int32GetDatum((int32) snap.launcher_pid);
    nulls[1] = !available || snap.launcher_pid == 0;
    values[2] = Int32GetDatum((int32) snap.controller_pid);
    nulls[2] = !available || snap.controller_pid == 0;
    values[3] = CStringGetTextDatum(available ? snap.controller_state : "not preloaded");
    values[4] = ObjectIdGetDatum(snap.control_database_oid);
    nulls[4] = !available || snap.control_database_oid == InvalidOid;
    values[5] = Int64GetDatum(snap.current_generation);
    nulls[5] = !available;
    values[6] = Int64GetDatum(snap.last_complete_generation);
    nulls[6] = !available || snap.last_complete_generation == 0;
    values[7] = Int32GetDatum(snap.expected_databases);
    nulls[7] = !available;
    values[8] = Int32GetDatum(snap.completed_databases);
    nulls[8] = !available;
    values[9] = Int32GetDatum(snap.failed_databases);
    nulls[9] = !available;
    values[10] = TimestampTzGetDatum(snap.generation_started_at);
    nulls[10] = !available || snap.generation_started_at == 0;
    values[11] = TimestampTzGetDatum(snap.generation_completed_at);
    nulls[11] = !available || snap.generation_completed_at == 0;
    values[12] = Float8GetDatum(snap.observed_sweep_seconds);
    nulls[12] = !available || snap.observed_sweep_seconds <= 0;
    values[13] = Int32GetDatum((int32) snap.emergency_worker_pid);
    nulls[13] = !available || snap.emergency_worker_pid == 0;
    values[14] = ObjectIdGetDatum(snap.emergency_database_oid);
    nulls[14] = !available || snap.emergency_database_oid == InvalidOid;

    PG_RETURN_DATUM(HeapTupleGetDatum(heap_form_tuple(tupdesc, values, nulls)));
}

static bool
aav_try_acquire_emergency_slot(Oid dboid)
{
    pid_t owner_pid;

    if (aav_shared_state == NULL)
        aav_attach_shared_state();

    if (aav_shared_state == NULL)
    {
        elog(WARNING,
             "adaptive autovacuum shared state is unavailable; emergency VACUUM is disabled for this request");
        return false;
    }

    for (;;)
    {
        SpinLockAcquire(&aav_shared_state->mutex);
        owner_pid = aav_shared_state->emergency_worker_pid;
        if (owner_pid == 0)
        {
            aav_shared_state->emergency_worker_pid = MyProcPid;
            aav_shared_state->emergency_database_oid = dboid;
            SpinLockRelease(&aav_shared_state->mutex);
            before_shmem_exit(aav_release_emergency_slot, (Datum) 0);
            return true;
        }
        SpinLockRelease(&aav_shared_state->mutex);

        /* Reap an owner left behind by an abnormal worker exit. */
        if (BackendPidGetProc(owner_pid) != NULL)
            return false;

        SpinLockAcquire(&aav_shared_state->mutex);
        if (aav_shared_state->emergency_worker_pid == owner_pid)
        {
            aav_shared_state->emergency_worker_pid = 0;
            aav_shared_state->emergency_database_oid = InvalidOid;
        }
        SpinLockRelease(&aav_shared_state->mutex);
    }
}

static void
aav_release_emergency_slot(int code, Datum arg)
{
    (void) code;
    (void) arg;

    if (aav_shared_state == NULL)
        return;

    SpinLockAcquire(&aav_shared_state->mutex);
    if (aav_shared_state->emergency_worker_pid == MyProcPid)
    {
        aav_shared_state->emergency_worker_pid = 0;
        aav_shared_state->emergency_database_oid = InvalidOid;
    }
    SpinLockRelease(&aav_shared_state->mutex);
}

static void
aav_release_controller_slot(int code, Datum arg)
{
    (void) code;
    (void) arg;

    if (aav_shared_state == NULL)
        return;

    SpinLockAcquire(&aav_shared_state->mutex);
    if (aav_shared_state->controller_pid == MyProcPid)
    {
        aav_shared_state->controller_pid = 0;
        strlcpy(aav_shared_state->controller_state, "stopped", AAV_STATE_LEN);
    }
    SpinLockRelease(&aav_shared_state->mutex);
}

static void
aav_sigterm(SIGNAL_ARGS)
{
    int save_errno = errno;

    aav_got_sigterm = true;
    InterruptPending = true;
    ProcDiePending = true;
    SetLatch(MyLatch);
    errno = save_errno;
}

static void
aav_sighup(SIGNAL_ARGS)
{
    int save_errno = errno;

    aav_got_sighup = true;
    SetLatch(MyLatch);
    errno = save_errno;
}


/* ---------- host metrics ---------- */

#ifdef __linux__
static bool
aav_read_int64_file(const char *path, int64 *value)
{
    FILE *file;
    char buffer[128];
    char *endptr;
    long long parsed;

    file = AllocateFile(path, "r");
    if (file == NULL)
        return false;

    if (fgets(buffer, sizeof(buffer), file) == NULL)
    {
        FreeFile(file);
        return false;
    }
    FreeFile(file);

    if (strncmp(buffer, "max", 3) == 0)
        return false;

    errno = 0;
    parsed = strtoll(buffer, &endptr, 10);
    if (errno != 0 || endptr == buffer || parsed < 0)
        return false;

    *value = (int64) parsed;
    return true;
}

static void
aav_apply_cgroup_memory_limit(AAVHostMetrics *metrics)
{
    FILE *file;
    char line[1024];
    char cgroup_path[MAXPGPATH] = "";
    bool unified = false;
    char limit_path[MAXPGPATH];
    char usage_path[MAXPGPATH];
    int64 limit_bytes;
    int64 usage_bytes;

    file = AllocateFile("/proc/self/cgroup", "r");
    if (file == NULL)
        return;

    while (fgets(line, sizeof(line), file) != NULL)
    {
        char *first_colon;
        char *second_colon;
        char *controllers;
        char *path;
        char *newline;

        first_colon = strchr(line, ':');
        if (first_colon == NULL)
            continue;
        second_colon = strchr(first_colon + 1, ':');
        if (second_colon == NULL)
            continue;

        *first_colon = '\0';
        *second_colon = '\0';
        controllers = first_colon + 1;
        path = second_colon + 1;
        newline = strchr(path, '\n');
        if (newline != NULL)
            *newline = '\0';

        if (controllers[0] == '\0')
        {
            unified = true;
            strlcpy(cgroup_path, path, sizeof(cgroup_path));
            break;
        }

        if (strstr(controllers, "memory") != NULL)
        {
            unified = false;
            strlcpy(cgroup_path, path, sizeof(cgroup_path));
        }
    }
    FreeFile(file);

    if (cgroup_path[0] == '\0')
        return;

    if (unified)
    {
        snprintf(limit_path, sizeof(limit_path),
                 "/sys/fs/cgroup%s/memory.max", cgroup_path);
        snprintf(usage_path, sizeof(usage_path),
                 "/sys/fs/cgroup%s/memory.current", cgroup_path);
    }
    else
    {
        snprintf(limit_path, sizeof(limit_path),
                 "/sys/fs/cgroup/memory%s/memory.limit_in_bytes", cgroup_path);
        snprintf(usage_path, sizeof(usage_path),
                 "/sys/fs/cgroup/memory%s/memory.usage_in_bytes", cgroup_path);
    }

    if (!aav_read_int64_file(limit_path, &limit_bytes) ||
        !aav_read_int64_file(usage_path, &usage_bytes))
        return;

    /* cgroup v1 represents "unlimited" with a very large sentinel. */
    if (limit_bytes <= 0 || limit_bytes >= ((int64) 1 << 60))
        return;

    if (metrics->mem_total_bytes <= 0 ||
        limit_bytes < metrics->mem_total_bytes)
    {
        metrics->mem_total_bytes = limit_bytes;
        metrics->mem_available_bytes = Max((int64) 0,
                                           limit_bytes - usage_bytes);
    }
}
#endif

#ifdef WIN32
/* Windows has no load average: use the CPU busy fraction (kernel time includes idle). */
static double
aav_windows_cpu_busy_fraction(void)
{
    FILETIME idle_a, kernel_a, user_a;
    FILETIME idle_b, kernel_b, user_b;
    ULARGE_INTEGER ia, ka, ua, ib, kb, ub;
    ULONGLONG idle_delta, total_delta;

    if (!GetSystemTimes(&idle_a, &kernel_a, &user_a))
        return 0.0;

    pg_usleep(200000L);         /* 200 ms sampling window */

    if (!GetSystemTimes(&idle_b, &kernel_b, &user_b))
        return 0.0;

    ia.LowPart = idle_a.dwLowDateTime;
    ia.HighPart = idle_a.dwHighDateTime;
    ka.LowPart = kernel_a.dwLowDateTime;
    ka.HighPart = kernel_a.dwHighDateTime;
    ua.LowPart = user_a.dwLowDateTime;
    ua.HighPart = user_a.dwHighDateTime;
    ib.LowPart = idle_b.dwLowDateTime;
    ib.HighPart = idle_b.dwHighDateTime;
    kb.LowPart = kernel_b.dwLowDateTime;
    kb.HighPart = kernel_b.dwHighDateTime;
    ub.LowPart = user_b.dwLowDateTime;
    ub.HighPart = user_b.dwHighDateTime;

    idle_delta = ib.QuadPart - ia.QuadPart;
    total_delta = (kb.QuadPart - ka.QuadPart) + (ub.QuadPart - ua.QuadPart);

    if (total_delta == 0 || idle_delta > total_delta)
        return 0.0;

    return (double) (total_delta - idle_delta) / (double) total_delta;
}
#endif

static void
aav_collect_host_metrics(AAVHostMetrics *metrics)
{
    MemSet(metrics, 0, sizeof(*metrics));

#ifdef WIN32
    {
        SYSTEM_INFO system_info;
        MEMORYSTATUSEX memory_status;

        GetSystemInfo(&system_info);
        metrics->cpu_count = (int) system_info.dwNumberOfProcessors;
        if (metrics->cpu_count <= 0)
            metrics->cpu_count = 1;

        MemSet(&memory_status, 0, sizeof(memory_status));
        memory_status.dwLength = sizeof(memory_status);
        if (GlobalMemoryStatusEx(&memory_status))
        {
            metrics->mem_total_bytes = (int64) memory_status.ullTotalPhys;
            metrics->mem_available_bytes = (int64) memory_status.ullAvailPhys;
        }

        /* Busy fraction x CPU count approximates load but cannot exceed the CPU count. */
        metrics->load1 = aav_windows_cpu_busy_fraction() * metrics->cpu_count;
    }
#else
    {
        long pages;
        long page_size;
        double load_values[3] = {0.0, 0.0, 0.0};

        metrics->cpu_count = (int) sysconf(_SC_NPROCESSORS_ONLN);
        if (metrics->cpu_count <= 0)
            metrics->cpu_count = 1;

        if (getloadavg(load_values, 3) >= 1)
            metrics->load1 = load_values[0];

#ifdef __linux__
        {
            FILE *file;
            char line[256];

            file = AllocateFile("/proc/meminfo", "r");
            if (file != NULL)
            {
                int64 total_kb = 0;
                int64 available_kb = 0;

                while (fgets(line, sizeof(line), file) != NULL)
                {
                    long long value;

                    if (sscanf(line, "MemTotal: %lld kB", &value) == 1)
                        total_kb = (int64) value;
                    else if (sscanf(line, "MemAvailable: %lld kB", &value) == 1)
                        available_kb = (int64) value;
                }
                FreeFile(file);

                if (total_kb > 0)
                    metrics->mem_total_bytes = total_kb * 1024;
                if (available_kb > 0)
                    metrics->mem_available_bytes = available_kb * 1024;
            }
        }
#endif

        page_size = sysconf(_SC_PAGESIZE);
        if (page_size <= 0)
            page_size = 4096;

        if (metrics->mem_total_bytes <= 0)
        {
            pages = sysconf(_SC_PHYS_PAGES);
            if (pages > 0)
                metrics->mem_total_bytes = (int64) pages * page_size;
        }

        if (metrics->mem_available_bytes <= 0)
        {
            pages = sysconf(_SC_AVPHYS_PAGES);
            if (pages > 0)
                metrics->mem_available_bytes = (int64) pages * page_size;
        }

#ifdef __linux__
        aav_apply_cgroup_memory_limit(metrics);
#endif
    }
#endif
}

Datum
adaptive_autovacuum_host_metrics(PG_FUNCTION_ARGS)
{
    AAVHostMetrics metrics;
    char *json;

    aav_collect_host_metrics(&metrics);
    json = psprintf("{\"load1\":%.6f,\"cpu_count\":%d,"
                    "\"mem_total_bytes\":" INT64_FORMAT ","
                    "\"mem_available_bytes\":" INT64_FORMAT "}",
                    metrics.load1,
                    metrics.cpu_count,
                    metrics.mem_total_bytes,
                    metrics.mem_available_bytes);

    PG_RETURN_DATUM(DirectFunctionCall1(jsonb_in, CStringGetDatum(json)));
}


/* ---------- launcher: supervises the one controller, never touches a database ---------- */

/* Shared-catalog lookup from a backend without a database (like core autovacuum's launcher). */
static bool
aav_lookup_control_database(const char *name, Oid *dboid, char **problem)
{
    Relation rel;
    TableScanDesc scan;
    HeapTuple tup;
    bool found = false;

    *dboid = InvalidOid;
    *problem = NULL;

    StartTransactionCommand();
    rel = table_open(DatabaseRelationId, AccessShareLock);
    scan = table_beginscan_catalog(rel, 0, NULL);
    while ((tup = heap_getnext(scan, ForwardScanDirection)) != NULL)
    {
        Form_pg_database pgdb = (Form_pg_database) GETSTRUCT(tup);

        if (strcmp(NameStr(pgdb->datname), name) != 0)
            continue;
        found = true;
        if (pgdb->datistemplate)
            *problem = "is a template database";
        else if (!pgdb->datallowconn)
            *problem = "does not allow connections";
        else
            *dboid = pgdb->oid;
        break;
    }
    table_endscan(scan);
    table_close(rel, AccessShareLock);
    CommitTransactionCommand();

    if (!found)
        *problem = "does not exist";
    return OidIsValid(*dboid);
}

static bool
aav_start_controller(Oid dboid, BackgroundWorkerHandle **handle)
{
    BackgroundWorker worker;

    MemSet(&worker, 0, sizeof(worker));
    snprintf(worker.bgw_name, BGW_MAXLEN, "adaptive autovacuum controller");
    snprintf(worker.bgw_type, BGW_MAXLEN, "adaptive autovacuum controller");
    worker.bgw_flags = BGWORKER_SHMEM_ACCESS |
                       BGWORKER_BACKEND_DATABASE_CONNECTION;
    worker.bgw_start_time = BgWorkerStart_RecoveryFinished;
    worker.bgw_restart_time = BGW_NEVER_RESTART;
    snprintf(worker.bgw_library_name, MAXPGPATH, "adaptive_autovacuum");
    snprintf(worker.bgw_function_name, BGW_MAXLEN,
             "adaptive_autovacuum_controller_main");
    worker.bgw_main_arg = ObjectIdGetDatum(dboid);
    worker.bgw_notify_pid = MyProcPid;

    return RegisterDynamicBackgroundWorker(&worker, handle);
}

PGDLLEXPORT void
adaptive_autovacuum_launcher_main(Datum main_arg)
{
    BackgroundWorkerHandle *controller = NULL;
    TimestampTz restart_at = 0;
    int failures = 0;

    (void) main_arg;

    pqsignal(SIGTERM, aav_sigterm);
    pqsignal(SIGHUP, aav_sighup);
    BackgroundWorkerUnblockSignals();

    /* No database: pg_database is a shared catalog, which is all the launcher needs. */
    BackgroundWorkerInitializeConnection(NULL, NULL, 0);

    if (aav_shared_state != NULL)
    {
        SpinLockAcquire(&aav_shared_state->mutex);
        aav_shared_state->launcher_pid = MyProcPid;
        SpinLockRelease(&aav_shared_state->mutex);
    }

    elog(LOG, "adaptive autovacuum launcher started (control database \"%s\")",
         aav_control_database);

    while (!aav_got_sigterm)
    {
        int rc;
        long wait_ms = 10000L;

        if (aav_got_sighup)
        {
            aav_got_sighup = false;
            ProcessConfigFile(PGC_SIGHUP);
        }

        if (controller != NULL)
        {
            pid_t pid;
            BgwHandleStatus status = GetBackgroundWorkerPid(controller, &pid);

            if (status == BGWH_POSTMASTER_DIED)
                proc_exit(1);
            if (status == BGWH_STOPPED)
            {
                long backoff_s;

                pfree(controller);
                controller = NULL;
                failures = Min(failures + 1, 8);
                backoff_s = Min(10L << (failures - 1), 600L);
                restart_at = TimestampTzPlusMilliseconds(GetCurrentTimestamp(), backoff_s * 1000);
                if (!aav_got_sigterm)
                    elog(WARNING,
                         "adaptive autovacuum controller exited; restarting in %ld s (check the server log for its error)",
                         backoff_s);
                aav_set_controller_state("restarting after exit");
            }
        }

        /* Standby guard (defense in depth): stay observational during recovery. */
        if (RecoveryInProgress())
        {
            aav_set_controller_state("idle: server in recovery");
        }
        else if (!aav_enabled)
        {
            if (controller == NULL)
                aav_set_controller_state("disabled (adaptive_autovacuum.enabled = off)");
        }
        else if (controller == NULL && GetCurrentTimestamp() >= restart_at)
        {
            Oid dboid;
            char *problem;

            /* Never start a controller toward a database that cannot be reached. */
            if (!aav_lookup_control_database(aav_control_database, &dboid, &problem))
            {
                long backoff_s;

                failures = Min(failures + 1, 8);
                backoff_s = Min(10L << (failures - 1), 600L);
                restart_at = TimestampTzPlusMilliseconds(GetCurrentTimestamp(), backoff_s * 1000);
                ereport(WARNING,
                        (errmsg("adaptive autovacuum control database \"%s\" %s; the controller is not started (retry in %ld s)",
                                aav_control_database, problem, backoff_s),
                         errhint("Create the database or point adaptive_autovacuum.control_database at an existing one and reload.")));
                aav_set_controller_state("waiting for control database");
            }
            else if (!aav_start_controller(dboid, &controller))
            {
                failures = Min(failures + 1, 8);
                restart_at = TimestampTzPlusMilliseconds(GetCurrentTimestamp(), 30 * 1000);
                elog(WARNING,
                     "adaptive autovacuum could not register the controller worker; check max_worker_processes (retry in 30 s)");
                aav_set_controller_state("waiting for a background worker slot");
            }
            else
            {
                aav_set_controller_state("starting");
            }
        }

        /* Forget the failure history once the restarted controller has completed a sweep. */
        if (controller != NULL && failures > 0 && aav_shared_state != NULL)
        {
            SpinLockAcquire(&aav_shared_state->mutex);
            if (aav_shared_state->generation_completed_at > restart_at)
                failures = 0;
            SpinLockRelease(&aav_shared_state->mutex);
        }

        rc = WaitLatch(MyLatch,
                       WL_LATCH_SET | WL_TIMEOUT | WL_POSTMASTER_DEATH,
                       wait_ms,
                       PG_WAIT_EXTENSION);
        ResetLatch(MyLatch);

        if (rc & WL_POSTMASTER_DEATH)
            proc_exit(1);

        /* Absorb interrupts (ProcSignalBarriers) or DROP DATABASE waits forever. */
        CHECK_FOR_INTERRUPTS();
    }

    if (controller != NULL)
    {
        TerminateBackgroundWorker(controller);
        (void) WaitForBackgroundWorkerShutdown(controller);
    }

    elog(LOG, "adaptive autovacuum launcher shutting down");
    proc_exit(0);
}


/* ---------- handoff files ---------- */

static void
aav_ensure_tmp_dir(void)
{
    struct stat st;

    if (stat(AAV_TMP_DIR, &st) == 0)
        return;
    if (MakePGDirectory(AAV_TMP_DIR) < 0 && errno != EEXIST)
        ereport(ERROR,
                (errcode_for_file_access(),
                 errmsg("adaptive autovacuum could not create directory \"%s\": %m", AAV_TMP_DIR)));
}

static void
aav_tmp_path(char *buf, size_t len, const char *name)
{
    snprintf(buf, len, "%s/%s", AAV_TMP_DIR, name);
}

/* Write-then-rename so a reader never sees a half-written file. */
static bool
aav_write_file(const char *path, const char *text)
{
    char tmp[MAXPGPATH];
    FILE *file;
    size_t len = strlen(text);

    snprintf(tmp, sizeof(tmp), "%s.tmp", path);
    file = AllocateFile(tmp, "wb");
    if (file == NULL)
    {
        elog(WARNING, "adaptive autovacuum could not create \"%s\": %m", tmp);
        return false;
    }
    if (len > 0 && fwrite(text, 1, len, file) != len)
    {
        elog(WARNING, "adaptive autovacuum could not write \"%s\": %m", tmp);
        FreeFile(file);
        unlink(tmp);
        return false;
    }
    if (FreeFile(file) != 0)
    {
        elog(WARNING, "adaptive autovacuum could not close \"%s\": %m", tmp);
        unlink(tmp);
        return false;
    }
    unlink(path);
    if (rename(tmp, path) != 0)
    {
        elog(WARNING, "adaptive autovacuum could not rename \"%s\" to \"%s\": %m", tmp, path);
        unlink(tmp);
        return false;
    }
    return true;
}

/* Whole file as a palloc'd string, NULL when absent or unreadable. */
static char *
aav_read_file(const char *path)
{
    FILE *file;
    StringInfoData buf;
    char chunk[8192];
    size_t n;

    file = AllocateFile(path, "rb");
    if (file == NULL)
        return NULL;
    initStringInfo(&buf);
    while ((n = fread(chunk, 1, sizeof(chunk), file)) > 0)
        appendBinaryStringInfo(&buf, chunk, (int) n);
    if (ferror(file))
    {
        elog(WARNING, "adaptive autovacuum could not read \"%s\": %m", path);
        FreeFile(file);
        pfree(buf.data);
        return NULL;
    }
    FreeFile(file);
    return buf.data;
}


/* ---------- controller: discovery, scheduling, absorption, the one global decision ---------- */

static char *
aav_copy_error_message(void)
{
    ErrorData *edata;
    MemoryContext old_context;
    char *message;

    old_context = MemoryContextSwitchTo(TopMemoryContext);
    edata = CopyErrorData();
    message = pstrdup(edata->message ? edata->message : "unknown error");
    MemoryContextSwitchTo(old_context);
    FlushErrorState();
    FreeErrorData(edata);
    return message;
}

/* One-row, one-column text query in its own transaction; NULL when no row or NULL. */
static char *
aav_fetch_text(const char *sql, int nargs, Oid *argtypes, Datum *values, const char *nulls)
{
    MemoryContext caller_context = CurrentMemoryContext;
    char *result = NULL;
    int spi_rc;

    StartTransactionCommand();
    SPI_connect();
    PushActiveSnapshot(GetTransactionSnapshot());

    spi_rc = SPI_execute_with_args(sql, nargs, argtypes, values, nulls, false, 1);
    if (spi_rc < 0)
        elog(ERROR, "adaptive autovacuum query failed: SPI code %d", spi_rc);
    if (SPI_processed >= 1 && SPI_tuptable != NULL)
    {
        char *value = SPI_getvalue(SPI_tuptable->vals[0], SPI_tuptable->tupdesc, 1);

        if (value != NULL)
        {
            MemoryContext old_context = MemoryContextSwitchTo(caller_context);

            result = pstrdup(value);
            MemoryContextSwitchTo(old_context);
        }
    }

    PopActiveSnapshot();
    SPI_finish();
    CommitTransactionCommand();
    return result;
}

/* The 1.2.0 SQL objects exist in the control database. */
static bool
aav_control_plane_ready(void)
{
    char *value = aav_fetch_text(
        "SELECT (to_regprocedure('adaptive_autovacuum._begin_generation()') IS NOT NULL"
        "        AND to_regclass('adaptive_autovacuum.database_state') IS NOT NULL)::text",
        0, NULL, NULL, NULL);

    return value != NULL && strcmp(value, "true") == 0;
}

static bool
aav_policy_enabled(void)
{
    char *value = aav_fetch_text(
        "SELECT p.enabled::text FROM adaptive_autovacuum.policy p WHERE p.singleton",
        0, NULL, NULL, NULL);

    return value != NULL && strcmp(value, "true") == 0;
}

static List *
aav_discover_databases(void)
{
    MemoryContext caller_context = CurrentMemoryContext;
    List *result = NIL;
    int spi_rc;
    uint64 i;

    StartTransactionCommand();
    SPI_connect();
    PushActiveSnapshot(GetTransactionSnapshot());

    spi_rc = SPI_execute(
        "SELECT database_oid, database_name, excluded FROM adaptive_autovacuum._discover_databases()",
        false,
        0);
    if (spi_rc != SPI_OK_SELECT)
        elog(ERROR, "adaptive autovacuum could not discover databases: SPI code %d", spi_rc);

    for (i = 0; i < SPI_processed; i++)
    {
        HeapTuple tuple = SPI_tuptable->vals[i];
        TupleDesc tupdesc = SPI_tuptable->tupdesc;
        bool isnull;
        Oid dboid;
        char *dbname;
        bool excluded;
        MemoryContext old_context;
        AAVDatabaseEntry *entry;

        dboid = DatumGetObjectId(SPI_getbinval(tuple, tupdesc, 1, &isnull));
        if (isnull)
            continue;
        dbname = SPI_getvalue(tuple, tupdesc, 2);
        if (dbname == NULL)
            continue;
        excluded = DatumGetBool(SPI_getbinval(tuple, tupdesc, 3, &isnull));
        if (isnull)
            excluded = false;

        old_context = MemoryContextSwitchTo(caller_context);
        entry = palloc0(sizeof(*entry));
        entry->dboid = dboid;
        entry->dbname = pstrdup(dbname);
        entry->excluded = excluded;
        result = lappend(result, entry);
        MemoryContextSwitchTo(old_context);
    }

    PopActiveSnapshot();
    SPI_finish();
    CommitTransactionCommand();

    return result;
}

/* Build the worker's input document in the control database and hand it over as a file. */
static bool
aav_prepare_worker_input(const AAVDatabaseEntry *entry, int64 generation,
                         const AAVHostMetrics *metrics)
{
    Oid argtypes[7] = {OIDOID, NAMEOID, INT8OID, FLOAT8OID, INT4OID, INT8OID, INT8OID};
    Datum values[7];
    NameData dbname;
    char *doc;
    char path[MAXPGPATH];
    char name[64];

    namestrcpy(&dbname, entry->dbname);
    values[0] = ObjectIdGetDatum(entry->dboid);
    values[1] = NameGetDatum(&dbname);
    values[2] = Int64GetDatum(generation);
    values[3] = Float8GetDatum(metrics->load1);
    values[4] = Int32GetDatum(metrics->cpu_count);
    values[5] = Int64GetDatum(metrics->mem_available_bytes);
    values[6] = Int64GetDatum(metrics->mem_total_bytes);

    doc = aav_fetch_text(
        "SELECT adaptive_autovacuum._worker_input($1, $2, $3, $4, $5, $6, $7)",
        7, argtypes, values, NULL);
    if (doc == NULL)
        return false;

    snprintf(name, sizeof(name), "%u.in", entry->dboid);
    aav_tmp_path(path, sizeof(path), name);
    return aav_write_file(path, doc);
}

/* Persist a finished worker's result; a missing or failed result marks the database failed. */
static bool
aav_absorb_worker_result(const AAVDatabaseEntry *entry, int64 generation,
                         int *dup_installs, bool *emergency_pending)
{
    char in_path[MAXPGPATH];
    char out_path[MAXPGPATH];
    char name[64];
    NameData dbname;
    char *doc;
    bool ok = false;

    namestrcpy(&dbname, entry->dbname);
    snprintf(name, sizeof(name), "%u.in", entry->dboid);
    aav_tmp_path(in_path, sizeof(in_path), name);
    snprintf(name, sizeof(name), "%u.out", entry->dboid);
    aav_tmp_path(out_path, sizeof(out_path), name);

    doc = aav_read_file(out_path);
    unlink(in_path);
    unlink(out_path);

    if (doc == NULL)
    {
        Oid argtypes[4] = {OIDOID, NAMEOID, INT8OID, TEXTOID};
        Datum values[4];

        values[0] = ObjectIdGetDatum(entry->dboid);
        values[1] = NameGetDatum(&dbname);
        values[2] = Int64GetDatum(generation);
        values[3] = CStringGetTextDatum("worker exited without a result (crash, timeout or connection failure)");
        (void) aav_fetch_text(
            "SELECT adaptive_autovacuum._record_database_failure($1, $2, $3, $4)",
            4, argtypes, values, NULL);
        return false;
    }

    {
        Oid argtypes[4] = {OIDOID, NAMEOID, INT8OID, TEXTOID};
        Datum values[4];
        int spi_rc;

        values[0] = ObjectIdGetDatum(entry->dboid);
        values[1] = NameGetDatum(&dbname);
        values[2] = Int64GetDatum(generation);
        values[3] = CStringGetTextDatum(doc);

        StartTransactionCommand();
        SPI_connect();
        PushActiveSnapshot(GetTransactionSnapshot());

        spi_rc = SPI_execute_with_args(
            "SELECT ok, eligible, overdue, emergency_relations, extension_installed, emergency_pending "
            "FROM adaptive_autovacuum._absorb_database_result($1, $2, $3, $4::jsonb)",
            4, argtypes, values, NULL, false, 1);
        if (spi_rc != SPI_OK_SELECT)
            elog(ERROR, "adaptive autovacuum could not absorb the result of database \"%s\": SPI code %d",
                 entry->dbname, spi_rc);
        if (SPI_processed == 1)
        {
            HeapTuple tuple = SPI_tuptable->vals[0];
            TupleDesc tupdesc = SPI_tuptable->tupdesc;
            bool isnull;
            Datum d;
            int eligible = 0, overdue = 0, emergencies = 0;
            bool installed = false, pending = false;

            d = SPI_getbinval(tuple, tupdesc, 1, &isnull);
            ok = !isnull && DatumGetBool(d);
            d = SPI_getbinval(tuple, tupdesc, 2, &isnull);
            eligible = isnull ? 0 : DatumGetInt32(d);
            d = SPI_getbinval(tuple, tupdesc, 3, &isnull);
            overdue = isnull ? 0 : DatumGetInt32(d);
            d = SPI_getbinval(tuple, tupdesc, 4, &isnull);
            emergencies = isnull ? 0 : DatumGetInt32(d);
            d = SPI_getbinval(tuple, tupdesc, 5, &isnull);
            installed = !isnull && DatumGetBool(d);
            d = SPI_getbinval(tuple, tupdesc, 6, &isnull);
            pending = !isnull && DatumGetBool(d);

            if (installed && entry->dboid != MyDatabaseId)
                (*dup_installs)++;
            if (pending)
                *emergency_pending = true;
            if (aav_log_cycle_summary && ok)
                elog(LOG,
                     "adaptive autovacuum scanned database \"%s\": %d eligible, %d overdue, %d emergency relation(s)",
                     entry->dbname, eligible, overdue, emergencies);
        }

        PopActiveSnapshot();
        SPI_finish();
        CommitTransactionCommand();
    }
    pfree(doc);
    return ok;
}

static bool
aav_start_database_worker(Oid dboid, const char *dbname,
                          BackgroundWorkerHandle **handle)
{
    BackgroundWorker worker;

    MemSet(&worker, 0, sizeof(worker));
    snprintf(worker.bgw_name, BGW_MAXLEN,
             "adaptive autovacuum database %s", dbname);
    snprintf(worker.bgw_type, BGW_MAXLEN,
             "adaptive autovacuum database worker");
    worker.bgw_flags = BGWORKER_SHMEM_ACCESS |
                       BGWORKER_BACKEND_DATABASE_CONNECTION;
    worker.bgw_start_time = BgWorkerStart_RecoveryFinished;
    worker.bgw_restart_time = BGW_NEVER_RESTART;
    snprintf(worker.bgw_library_name, MAXPGPATH, "adaptive_autovacuum");
    snprintf(worker.bgw_function_name, BGW_MAXLEN,
             "adaptive_autovacuum_database_main");
    worker.bgw_main_arg = ObjectIdGetDatum(dboid);
    worker.bgw_notify_pid = MyProcPid;

    if (!RegisterDynamicBackgroundWorker(&worker, handle))
    {
        elog(WARNING,
             "adaptive autovacuum could not register worker for database \"%s\"; check max_worker_processes",
             dbname);
        return false;
    }

    return true;
}

/* One occupied scheduling slot: a database worker in flight. */
typedef struct AAVWorkerSlot
{
    BackgroundWorkerHandle *handle;
    const AAVDatabaseEntry *entry;
    TimestampTz started_at;
    bool in_use;
} AAVWorkerSlot;

/* Run database workers, at most max_database_workers concurrently, absorbing each result as it lands. */
static void
aav_run_database_workers(List *databases, int64 generation,
                         const AAVHostMetrics *metrics, int *completed, int *failed,
                         int *dup_installs)
{
    int max_workers = Max(aav_max_database_workers, 1);
    AAVWorkerSlot *slots = palloc0(sizeof(AAVWorkerSlot) * max_workers);
    ListCell *next_db = list_head(databases);
    int active = 0;
    bool emergency_pending = false;

    for (;;)
    {
        int i;
        int rc;

        /* Fill free slots with the next databases in scan order. */
        while (next_db != NULL && !aav_got_sigterm)
        {
            AAVDatabaseEntry *entry = lfirst(next_db);
            int free_slot = -1;

            if (entry->excluded)
            {
                next_db = lnext(databases, next_db);
                continue;
            }

            for (i = 0; i < max_workers; i++)
            {
                if (!slots[i].in_use)
                {
                    free_slot = i;
                    break;
                }
            }
            if (free_slot < 0)
                break;

            if (aav_prepare_worker_input(entry, generation, metrics)
                && aav_start_database_worker(entry->dboid, entry->dbname,
                                             &slots[free_slot].handle))
            {
                slots[free_slot].entry = entry;
                slots[free_slot].started_at = GetCurrentTimestamp();
                slots[free_slot].in_use = true;
                active++;
            }
            else
            {
                (*failed)++;
                (void) aav_absorb_worker_result(entry, generation, dup_installs, &emergency_pending);
            }
            next_db = lnext(databases, next_db);
        }

        if (active == 0 && (next_db == NULL || aav_got_sigterm))
            break;

        rc = WaitLatch(MyLatch,
                       WL_LATCH_SET | WL_TIMEOUT | WL_POSTMASTER_DEATH,
                       1000L,
                       PG_WAIT_EXTENSION);
        ResetLatch(MyLatch);

        if (rc & WL_POSTMASTER_DEATH)
            proc_exit(1);

        /* Keep ProcSignalBarriers (e.g. DROP DATABASE) moving. */
        CHECK_FOR_INTERRUPTS();

        for (i = 0; i < max_workers; i++)
        {
            BgwHandleStatus status;
            pid_t pid;
            long elapsed_ms;
            bool finished = false;

            if (!slots[i].in_use)
                continue;

            status = GetBackgroundWorkerPid(slots[i].handle, &pid);
            (void) pid;
            if (status == BGWH_POSTMASTER_DIED)
                proc_exit(1);
            if (status == BGWH_STOPPED)
                finished = true;
            else
            {
                elapsed_ms = (long) ((GetCurrentTimestamp() - slots[i].started_at) / 1000);
                if (aav_got_sigterm ||
                    elapsed_ms >= (long) aav_database_worker_timeout_seconds * 1000L)
                {
                    if (!aav_got_sigterm)
                        elog(WARNING,
                             "adaptive autovacuum database worker \"%s\" exceeded timeout; requesting termination",
                             slots[i].entry->dbname);
                    TerminateBackgroundWorker(slots[i].handle);
                    (void) WaitForBackgroundWorkerShutdown(slots[i].handle);
                    finished = true;
                }
            }

            if (finished)
            {
                if (aav_absorb_worker_result(slots[i].entry, generation, dup_installs,
                                             &emergency_pending))
                    (*completed)++;
                else
                    (*failed)++;
                pfree(slots[i].handle);
                slots[i].in_use = false;
                active--;
                if (aav_shared_state != NULL)
                {
                    SpinLockAcquire(&aav_shared_state->mutex);
                    aav_shared_state->completed_databases = *completed;
                    aav_shared_state->failed_databases = *failed;
                    SpinLockRelease(&aav_shared_state->mutex);
                }
            }
        }

        /* Emergency requests are dispatched as soon as a database publishes them. */
        aav_service_emergency();
    }

    pfree(slots);
}

static void
aav_run_global_controller(const AAVHostMetrics *metrics, int64 generation, bool complete)
{
    Oid argtypes[7] = {FLOAT8OID, INT4OID, INT8OID, INT8OID, INT8OID, BOOLOID, INT8OID};
    Datum values[7];

    values[0] = Float8GetDatum(metrics->load1);
    values[1] = Int32GetDatum(metrics->cpu_count);
    values[2] = Int64GetDatum(metrics->mem_available_bytes);
    values[3] = Int64GetDatum(metrics->mem_total_bytes);
    values[4] = Int64GetDatum(generation);
    values[5] = BoolGetDatum(complete);
    /* The next XID, read from shared memory: no transaction ID is assigned to measure the rate. */
    values[6] = Int64GetDatum((int64) U64FromFullTransactionId(ReadNextFullTransactionId()));

    (void) aav_fetch_text(
        "SELECT adaptive_autovacuum._global_controller($1, $2, $3, $4, $5, $6, $7)",
        7, argtypes, values, NULL);
}

/* One sweep generation: discover, scan every database, decide once, apply once. */
static void
aav_run_sweep(MemoryContext sweep_context)
{
    MemoryContext old_context;
    AAVHostMetrics metrics;
    List *databases;
    ListCell *lc;
    char *generation_text;
    int64 generation;
    int expected = 0;
    int completed = 0;
    int failed = 0;
    int dup_installs = 0;
    char *program;
    char path[MAXPGPATH];
    TimestampTz started_at = GetCurrentTimestamp();

    MemoryContextReset(sweep_context);
    old_context = MemoryContextSwitchTo(sweep_context);

    (void) aav_fetch_text("SELECT adaptive_autovacuum._recover_stale_emergencies()::text",
                          0, NULL, NULL, NULL);

    if (!aav_policy_enabled())
    {
        aav_set_controller_state("idle: policy.enabled = false");
        MemoryContextSwitchTo(old_context);
        return;
    }

    /* The database program is fetched once per sweep and shared by every worker through a file. */
    program = aav_fetch_text("SELECT adaptive_autovacuum._database_program()", 0, NULL, NULL, NULL);
    if (program == NULL || strstr(program, AAV_PROGRAM_TAG) != NULL)
        elog(ERROR, "adaptive autovacuum database program is missing or contains the quoting tag");
    aav_tmp_path(path, sizeof(path), "program.sql");
    if (!aav_write_file(path, program))
        elog(ERROR, "adaptive autovacuum could not publish the database program");

    generation_text = aav_fetch_text("SELECT adaptive_autovacuum._begin_generation()::text",
                                     0, NULL, NULL, NULL);
    if (generation_text == NULL)
        elog(ERROR, "adaptive autovacuum could not begin a sweep generation");
    generation = strtoll(generation_text, NULL, 10);

    aav_collect_host_metrics(&metrics);
    databases = aav_discover_databases();
    foreach(lc, databases)
    {
        AAVDatabaseEntry *entry = lfirst(lc);

        if (!entry->excluded)
            expected++;
    }

    if (aav_shared_state != NULL)
    {
        SpinLockAcquire(&aav_shared_state->mutex);
        aav_shared_state->current_generation = generation;
        aav_shared_state->expected_databases = expected;
        aav_shared_state->completed_databases = 0;
        aav_shared_state->failed_databases = 0;
        aav_shared_state->generation_started_at = started_at;
        aav_shared_state->generation_completed_at = 0;
        SpinLockRelease(&aav_shared_state->mutex);
    }
    aav_set_controller_state("sweeping");

    aav_run_database_workers(databases, generation, &metrics, &completed, &failed, &dup_installs);

    if (aav_got_sigterm)
    {
        MemoryContextSwitchTo(old_context);
        return;
    }

    /* Decide once, from fresh host metrics and the evidence this sweep collected. */
    aav_collect_host_metrics(&metrics);
    aav_run_global_controller(&metrics, generation, failed == 0 && completed == expected);
    aav_apply_global_settings();

    if (aav_shared_state != NULL)
    {
        TimestampTz now = GetCurrentTimestamp();
        double seconds = (double) (now - started_at) / 1000000.0;

        SpinLockAcquire(&aav_shared_state->mutex);
        aav_shared_state->generation_completed_at = now;
        aav_shared_state->observed_sweep_seconds =
            aav_shared_state->observed_sweep_seconds > 0
            ? 0.5 * seconds + 0.5 * aav_shared_state->observed_sweep_seconds
            : seconds;
        if (failed == 0 && completed == expected)
            aav_shared_state->last_complete_generation = generation;
        aav_shared_state->controller_failures = 0;
        SpinLockRelease(&aav_shared_state->mutex);
    }

    if (dup_installs > 0)
        ereport(WARNING,
                (errmsg("adaptive autovacuum: the extension is also created in %d database(s) other than the control database; those copies are ignored",
                        dup_installs),
                 errhint("Install adaptive_autovacuum once per cluster, in the control database; see adaptive_autovacuum.doctor().")));

    if (aav_log_cycle_summary)
        elog(LOG,
             "adaptive autovacuum sweep " INT64_FORMAT " completed: %d database(s) scanned, %d failed, %.1f s",
             generation, completed, failed,
             (double) (GetCurrentTimestamp() - started_at) / 1000000.0);

    MemoryContextSwitchTo(old_context);
}

PGDLLEXPORT void
adaptive_autovacuum_controller_main(Datum main_arg)
{
    Oid control_oid = DatumGetObjectId(main_arg);
    MemoryContext sweep_context;
    MemoryContext loop_context;
    int not_ready_warnings = 0;

    pqsignal(SIGTERM, aav_sigterm);
    pqsignal(SIGHUP, aav_sighup);
    BackgroundWorkerUnblockSignals();

    BackgroundWorkerInitializeConnectionByOid(control_oid, InvalidOid, 0);

    if (aav_shared_state != NULL)
    {
        SpinLockAcquire(&aav_shared_state->mutex);
        aav_shared_state->controller_pid = MyProcPid;
        aav_shared_state->control_database_oid = control_oid;
        SpinLockRelease(&aav_shared_state->mutex);
        before_shmem_exit(aav_release_controller_slot, (Datum) 0);
    }
    aav_set_controller_state("starting");

    sweep_context = AllocSetContextCreate(TopMemoryContext,
                                          "adaptive autovacuum sweep",
                                          ALLOCSET_DEFAULT_SIZES);
    loop_context = AllocSetContextCreate(TopMemoryContext,
                                         "adaptive autovacuum controller loop",
                                         ALLOCSET_DEFAULT_SIZES);

    elog(LOG, "adaptive autovacuum controller started on control database \"%s\"",
         aav_control_database);

    while (!aav_got_sigterm)
    {
        int rc;
        long wait_ms = (long) aav_naptime_seconds * 1000L;

        /* Per-iteration scratch: a transaction abort may have left us in TopMemoryContext. */
        MemoryContextReset(loop_context);
        MemoryContextSwitchTo(loop_context);

        if (aav_got_sighup)
        {
            aav_got_sighup = false;
            ProcessConfigFile(PGC_SIGHUP);
        }

        PG_TRY();
        {
            if (RecoveryInProgress())
            {
                aav_set_controller_state("idle: server in recovery");
            }
            else if (!aav_enabled)
            {
                aav_set_controller_state("disabled (adaptive_autovacuum.enabled = off)");
            }
            else
            {
                aav_ensure_tmp_dir();
                if (!aav_control_plane_ready())
                {
                    aav_set_controller_state("waiting for CREATE EXTENSION in the control database");
                    if (not_ready_warnings++ % 10 == 0)
                        ereport(WARNING,
                                (errmsg("adaptive autovacuum: the extension objects are missing or outdated in control database \"%s\"; nothing is managed",
                                        aav_control_database),
                                 errhint("Run CREATE EXTENSION adaptive_autovacuum (or ALTER EXTENSION adaptive_autovacuum UPDATE) in that database.")));
                }
                else
                {
                    not_ready_warnings = 0;
                    aav_run_sweep(sweep_context);
                    if (!aav_got_sigterm)
                        aav_set_controller_state("running");
                }
            }
        }
        PG_CATCH();
        {
            char *message = aav_copy_error_message();

            aav_abort_transaction_if_needed();
            elog(WARNING, "adaptive autovacuum sweep failed: %s", message);
            aav_set_controller_state("sweep failed; retrying after naptime");
            pfree(message);
        }
        PG_END_TRY();

        /* Emergency work keeps flowing between sweeps; wake on worker exit or the naptime. */
        while (!aav_got_sigterm && wait_ms > 0)
        {
            TimestampTz before = GetCurrentTimestamp();

            PG_TRY();
            {
                if (aav_enabled && !RecoveryInProgress() && aav_control_plane_ready())
                    aav_service_emergency();
            }
            PG_CATCH();
            {
                char *message = aav_copy_error_message();

                aav_abort_transaction_if_needed();
                elog(WARNING, "adaptive autovacuum emergency dispatch failed: %s", message);
                pfree(message);
            }
            PG_END_TRY();

            rc = WaitLatch(MyLatch,
                           WL_LATCH_SET | WL_TIMEOUT | WL_POSTMASTER_DEATH,
                           wait_ms,
                           PG_WAIT_EXTENSION);
            ResetLatch(MyLatch);
            if (rc & WL_POSTMASTER_DEATH)
                proc_exit(1);
            /* Absorb interrupts (ProcSignalBarriers) or DROP DATABASE waits forever. */
            CHECK_FOR_INTERRUPTS();
            /* A reload takes effect here; it does not trigger an extra sweep. */
            if (aav_got_sighup)
            {
                aav_got_sighup = false;
                ProcessConfigFile(PGC_SIGHUP);
            }
            wait_ms -= (long) ((GetCurrentTimestamp() - before) / 1000);
        }
    }

    elog(LOG, "adaptive autovacuum controller shutting down");
    proc_exit(0);
}


/* ---------- cluster settings: applied only by the controller ---------- */

/* GUCs the policy may change cluster-wide; anything else is marked failed. */
static const char *const aav_allowed_global_gucs[] = {
    "autovacuum_vacuum_cost_limit",
    "autovacuum_vacuum_cost_delay",
    "autovacuum_max_workers",
    "autovacuum_work_mem",
    "vacuum_buffer_usage_limit",
    "autovacuum_vacuum_scale_factor",
    "autovacuum_vacuum_threshold",
    "autovacuum_vacuum_max_threshold",
    "autovacuum_vacuum_insert_scale_factor",
    "autovacuum_vacuum_insert_threshold",
    "autovacuum_analyze_scale_factor",
    "autovacuum_analyze_threshold",
    /* Repair only: the policy queues 'on' and the apply path refuses any other value. */
    "autovacuum",
};

/* Whitelist position, or -1 when the GUC is not managed. */
static int
aav_global_guc_index(const char *name)
{
    int i;

    for (i = 0; i < (int) lengthof(aav_allowed_global_gucs); i++)
    {
        if (strcmp(name, aav_allowed_global_gucs[i]) == 0)
            return i;
    }
    return -1;
}

static void
aav_mark_global_change(int64 id, const char *status,
                       const char *old_value, const char *error_text)
{
    Oid argtypes[4] = {INT8OID, TEXTOID, TEXTOID, TEXTOID};
    Datum values[4];
    char nulls[4] = {' ', ' ', ' ', ' '};

    values[0] = Int64GetDatum(id);
    values[1] = CStringGetTextDatum(status);
    if (old_value != NULL)
        values[2] = CStringGetTextDatum(old_value);
    else
    {
        values[2] = (Datum) 0;
        nulls[2] = 'n';
    }
    if (error_text != NULL)
        values[3] = CStringGetTextDatum(error_text);
    else
    {
        values[3] = (Datum) 0;
        nulls[3] = 'n';
    }

    (void) SPI_execute_with_args(
        "UPDATE adaptive_autovacuum.global_apply_queue "
        "SET status = $2, "
        "    applied_at = clock_timestamp(), "
        "    old_value = $3, "
        "    error = $4 "
        "WHERE id = $1",
        4, argtypes, values, nulls, false, 0);
}

/* Apply queued cluster settings via AlterSystemSetConfigFile() + reload (SPI cannot). */
static void
aav_apply_global_settings(void)
{
    int spi_rc;
    uint64 nrows;
    uint64 i;
    int64 *ids;
    char **names;
    char **values;
    int applied_count = 0;

    StartTransactionCommand();
    SPI_connect();
    PushActiveSnapshot(GetTransactionSnapshot());

    spi_rc = SPI_execute(
        "SELECT q.id, q.guc_name, q.desired_value "
        "FROM adaptive_autovacuum.global_apply_queue q "
        "WHERE q.status = 'pending' "
        "ORDER BY q.id "
        "FOR UPDATE SKIP LOCKED",
        false, 0);
    if (spi_rc != SPI_OK_SELECT || SPI_processed == 0)
    {
        PopActiveSnapshot();
        SPI_finish();
        CommitTransactionCommand();
        return;
    }

    /* Copy the rows out before issuing further SPI calls. */
    nrows = SPI_processed;
    ids = palloc(sizeof(int64) * nrows);
    names = palloc(sizeof(char *) * nrows);
    values = palloc(sizeof(char *) * nrows);
    for (i = 0; i < nrows; i++)
    {
        HeapTuple tuple = SPI_tuptable->vals[i];
        TupleDesc tupdesc = SPI_tuptable->tupdesc;
        bool isnull;

        ids[i] = DatumGetInt64(SPI_getbinval(tuple, tupdesc, 1, &isnull));
        names[i] = SPI_getvalue(tuple, tupdesc, 2);
        values[i] = SPI_getvalue(tuple, tupdesc, 3);
    }

    for (i = 0; i < nrows; i++)
    {
        const char *old_value;
        VariableSetStmt *setstmt;
        AlterSystemStmt *stmt;
        A_Const *aconst;
        MemoryContext oldcontext;
        ResourceOwner oldowner;
        char *volatile apply_error = NULL;
        int guc_index;

        guc_index = (names[i] != NULL) ? aav_global_guc_index(names[i]) : -1;
        if (guc_index < 0)
        {
            aav_mark_global_change(ids[i], "failed", NULL,
                                   "GUC is not in the managed whitelist.");
            continue;
        }

        /* autovacuum is repair-only: 'on' is the single accepted value. */
        if (strcmp(names[i], "autovacuum") == 0)
        {
            if (values[i] == NULL || strcmp(values[i], "on") != 0)
            {
                aav_mark_global_change(ids[i], "failed", NULL,
                                       "autovacuum may only be set to 'on' by the extension.");
                continue;
            }
        }
        else if (values[i] == NULL || values[i][0] == '\0' ||
                 strlen(values[i]) >= 32 ||
                 strspn(values[i], "0123456789.-") != strlen(values[i]))
        {
            aav_mark_global_change(ids[i], "failed", NULL,
                                   "Value is not a plain numeric literal.");
            continue;
        }

        /* autovacuum_max_workers must not exceed autovacuum_worker_slots; inert before PG18. */
        if (strcmp(names[i], "autovacuum_max_workers") == 0)
        {
            const char *slots = GetConfigOption("autovacuum_worker_slots",
                                                true, false);

            if (slots != NULL && atoi(values[i]) > atoi(slots))
            {
                char *slots_error = psprintf(
                    "Value exceeds autovacuum_worker_slots (%s); the excess workers could never start.",
                    slots);

                aav_mark_global_change(ids[i], "failed", NULL, slots_error);
                pfree(slots_error);
                continue;
            }
        }

        old_value = GetConfigOption(names[i], true, false);

        aconst = makeNode(A_Const);
        aconst->val.sval.type = T_String;
        aconst->val.sval.sval = pstrdup(values[i]);
        aconst->location = -1;

        setstmt = makeNode(VariableSetStmt);
        setstmt->kind = VAR_SET_VALUE;
        setstmt->name = pstrdup(names[i]);
        setstmt->args = list_make1(aconst);

        stmt = makeNode(AlterSystemStmt);
        stmt->setstmt = setstmt;

        /* Subtransaction per row so one rejected value does not block the rest. */
        oldcontext = CurrentMemoryContext;
        oldowner = CurrentResourceOwner;
        BeginInternalSubTransaction(NULL);
        PG_TRY();
        {
            AlterSystemSetConfigFile(stmt);
            ReleaseCurrentSubTransaction();
            MemoryContextSwitchTo(oldcontext);
            CurrentResourceOwner = oldowner;
        }
        PG_CATCH();
        {
            ErrorData *edata;

            MemoryContextSwitchTo(oldcontext);
            edata = CopyErrorData();
            FlushErrorState();
            RollbackAndReleaseCurrentSubTransaction();
            MemoryContextSwitchTo(oldcontext);
            CurrentResourceOwner = oldowner;

            apply_error = pstrdup(edata->message != NULL
                                  ? edata->message : "unknown error");
            FreeErrorData(edata);
        }
        PG_END_TRY();

        if (apply_error != NULL)
        {
            aav_mark_global_change(ids[i], "failed", NULL, apply_error);
            elog(WARNING,
                 "adaptive autovacuum could not set %s = %s cluster-wide: %s",
                 names[i], values[i], apply_error);
            pfree(apply_error);
            continue;
        }

        aav_mark_global_change(ids[i], "applied", old_value, NULL);
        applied_count++;

        elog(LOG,
             "adaptive autovacuum set %s = %s cluster-wide (was %s)",
             names[i], values[i],
             old_value != NULL ? old_value : "default");
    }

    PopActiveSnapshot();
    SPI_finish();
    CommitTransactionCommand();

    if (applied_count > 0)
        (void) kill(PostmasterPid, SIGHUP);
}


/* ---------- per-database worker: collector and executor, never a controller ---------- */

PGDLLEXPORT void
adaptive_autovacuum_database_main(Datum main_arg)
{
    Oid dboid = DatumGetObjectId(main_arg);
    char in_path[MAXPGPATH];
    char out_path[MAXPGPATH];
    char program_path[MAXPGPATH];
    char name[64];
    char *volatile output = NULL;

    pqsignal(SIGTERM, aav_sigterm);
    pqsignal(SIGHUP, aav_sighup);
    BackgroundWorkerUnblockSignals();

    BackgroundWorkerInitializeConnectionByOid(dboid, InvalidOid, 0);

    snprintf(name, sizeof(name), "%u.in", dboid);
    aav_tmp_path(in_path, sizeof(in_path), name);
    snprintf(name, sizeof(name), "%u.out", dboid);
    aav_tmp_path(out_path, sizeof(out_path), name);
    aav_tmp_path(program_path, sizeof(program_path), "program.sql");

    PG_TRY();
    {
        Oid argtypes[1] = {TEXTOID};
        Datum values[1];
        char *input;
        char *program;
        StringInfoData stmt;
        const char *result;
        int spi_rc;

        input = aav_read_file(in_path);
        if (input == NULL)
            elog(ERROR, "input document \"%s\" is missing", in_path);
        program = aav_read_file(program_path);
        if (program == NULL)
            elog(ERROR, "database program \"%s\" is missing", program_path);
        if (strstr(program, AAV_PROGRAM_TAG) != NULL)
            elog(ERROR, "database program contains the quoting tag");

        initStringInfo(&stmt);
        appendStringInfoString(&stmt, "DO " AAV_PROGRAM_TAG);
        appendStringInfoString(&stmt, program);
        appendStringInfoString(&stmt, AAV_PROGRAM_TAG);

        /* The whole scan is one transaction; the program isolates each DDL in its own subtransaction. */
        StartTransactionCommand();
        SPI_connect();
        PushActiveSnapshot(GetTransactionSnapshot());

        values[0] = CStringGetTextDatum(input);
        spi_rc = SPI_execute_with_args(
            "SELECT pg_catalog.set_config('adaptive_autovacuum.worker_input', $1, false)",
            1, argtypes, values, NULL, false, 0);
        if (spi_rc != SPI_OK_SELECT)
            elog(ERROR, "could not hand the input document to the program: SPI code %d", spi_rc);
        spi_rc = SPI_execute(
            "SELECT pg_catalog.set_config('adaptive_autovacuum.worker_output', '', false)",
            false, 0);
        if (spi_rc != SPI_OK_SELECT)
            elog(ERROR, "could not reset the output slot: SPI code %d", spi_rc);

        spi_rc = SPI_execute(stmt.data, false, 0);
        if (spi_rc != SPI_OK_UTILITY)
            elog(ERROR, "database program returned SPI code %d", spi_rc);

        result = GetConfigOption("adaptive_autovacuum.worker_output", true, false);
        if (result == NULL || result[0] == '\0')
            elog(ERROR, "database program produced no output");
        output = MemoryContextStrdup(TopMemoryContext, result);

        PopActiveSnapshot();
        SPI_finish();
        CommitTransactionCommand();
    }
    PG_CATCH();
    {
        char *message = aav_copy_error_message();
        StringInfoData doc;

        aav_abort_transaction_if_needed();
        MemoryContextSwitchTo(TopMemoryContext);
        elog(WARNING,
             "adaptive autovacuum database scan failed for database %u: %s",
             dboid, message);
        initStringInfo(&doc);
        appendStringInfoString(&doc, "{\"ok\": false, \"error\": ");
        escape_json(&doc, message);
        appendStringInfoString(&doc, "}");
        output = doc.data;
    }
    PG_END_TRY();

    (void) aav_write_file(out_path, output);

    if (aav_log_cycle_summary)
        elog(DEBUG1, "adaptive autovacuum database scan completed for database %u", dboid);

    proc_exit(0);
}


/* ---------- emergency worker: one request per process, dispatched by the controller ---------- */

static BackgroundWorkerHandle *aav_emergency_handle = NULL;
static AAVEmergencyRequest aav_emergency_current;
static bool aav_emergency_pid_recorded = false;

static bool
aav_start_emergency_worker(const AAVEmergencyRequest *request, const char *dbname,
                           BackgroundWorkerHandle **handle)
{
    BackgroundWorker worker;

    MemSet(&worker, 0, sizeof(worker));
    snprintf(worker.bgw_name, BGW_MAXLEN,
             "adaptive autovacuum emergency %s", dbname);
    snprintf(worker.bgw_type, BGW_MAXLEN,
             "adaptive autovacuum emergency worker");
    worker.bgw_flags = BGWORKER_SHMEM_ACCESS |
                       BGWORKER_BACKEND_DATABASE_CONNECTION;
    worker.bgw_start_time = BgWorkerStart_RecoveryFinished;
    worker.bgw_restart_time = BGW_NEVER_RESTART;
    snprintf(worker.bgw_library_name, MAXPGPATH, "adaptive_autovacuum");
    snprintf(worker.bgw_function_name, BGW_MAXLEN,
             "adaptive_autovacuum_emergency_main");
    worker.bgw_main_arg = ObjectIdGetDatum(request->dboid);
    memcpy(worker.bgw_extra, request, sizeof(*request));
    worker.bgw_notify_pid = MyProcPid;

    return RegisterDynamicBackgroundWorker(&worker, handle);
}

/* Finish the running emergency request if its worker is done, then dispatch the next one. */
static void
aav_service_emergency(void)
{
    if (aav_emergency_handle != NULL)
    {
        pid_t pid;
        BgwHandleStatus status = GetBackgroundWorkerPid(aav_emergency_handle, &pid);

        if (status == BGWH_POSTMASTER_DIED)
            proc_exit(1);
        if (status == BGWH_STARTED && !aav_emergency_pid_recorded)
        {
            Oid argtypes[2] = {INT8OID, INT4OID};
            Datum values[2];

            values[0] = Int64GetDatum(aav_emergency_current.request_id);
            values[1] = Int32GetDatum((int32) pid);
            (void) aav_fetch_text("SELECT adaptive_autovacuum._set_emergency_worker_pid($1, $2)",
                                  2, argtypes, values, NULL);
            aav_emergency_pid_recorded = true;
        }
        if (status == BGWH_STOPPED)
        {
            char path[MAXPGPATH];
            char name[64];
            char *result;
            const char *outcome = "failed";
            const char *error_text = "emergency worker exited without a result";
            Oid argtypes[3] = {INT8OID, TEXTOID, TEXTOID};
            Datum values[3];
            char nulls[3] = {' ', ' ', ' '};

            snprintf(name, sizeof(name), "emergency_" INT64_FORMAT ".out",
                     aav_emergency_current.request_id);
            aav_tmp_path(path, sizeof(path), name);
            result = aav_read_file(path);
            unlink(path);
            if (result != NULL)
            {
                char *newline = strchr(result, '\n');

                if (newline != NULL)
                {
                    *newline = '\0';
                    error_text = newline + 1;
                }
                else
                    error_text = NULL;
                outcome = result;
            }

            values[0] = Int64GetDatum(aav_emergency_current.request_id);
            values[1] = CStringGetTextDatum(outcome);
            if (error_text != NULL && error_text[0] != '\0')
                values[2] = CStringGetTextDatum(error_text);
            else
            {
                values[2] = (Datum) 0;
                nulls[2] = 'n';
            }
            (void) aav_fetch_text("SELECT adaptive_autovacuum._finish_emergency_request($1, $2, $3)",
                                  3, argtypes, values, nulls);
            if (aav_log_cycle_summary)
                elog(LOG,
                     "adaptive autovacuum emergency VACUUM of relation %u in database %u %s%s%s",
                     aav_emergency_current.relid, aav_emergency_current.dboid, outcome,
                     error_text != NULL && error_text[0] != '\0' ? ": " : "",
                     error_text != NULL ? error_text : "");
            pfree(aav_emergency_handle);
            aav_emergency_handle = NULL;
        }
    }

    if (aav_emergency_handle == NULL && !aav_got_sigterm)
    {
        int spi_rc;

        StartTransactionCommand();
        SPI_connect();
        PushActiveSnapshot(GetTransactionSnapshot());

        spi_rc = SPI_execute(
            "SELECT id, database_oid, database_name, relid, work_mem_mb, cost_limit, "
            "       cost_delay_ms, lock_timeout_ms, is_wraparound "
            "FROM adaptive_autovacuum._claim_emergency_request()",
            false, 1);
        if (spi_rc != SPI_OK_SELECT)
            elog(ERROR, "adaptive autovacuum could not claim an emergency request: SPI code %d", spi_rc);

        if (SPI_processed == 1)
        {
            HeapTuple tuple = SPI_tuptable->vals[0];
            TupleDesc tupdesc = SPI_tuptable->tupdesc;
            bool isnull;
            AAVEmergencyRequest request;
            char *dbname;

            MemSet(&request, 0, sizeof(request));
            request.request_id = DatumGetInt64(SPI_getbinval(tuple, tupdesc, 1, &isnull));
            request.dboid = DatumGetObjectId(SPI_getbinval(tuple, tupdesc, 2, &isnull));
            dbname = SPI_getvalue(tuple, tupdesc, 3);
            request.relid = DatumGetObjectId(SPI_getbinval(tuple, tupdesc, 4, &isnull));
            request.work_mem_mb = DatumGetInt32(SPI_getbinval(tuple, tupdesc, 5, &isnull));
            request.cost_limit = DatumGetInt32(SPI_getbinval(tuple, tupdesc, 6, &isnull));
            request.cost_delay_ms = DatumGetInt32(SPI_getbinval(tuple, tupdesc, 7, &isnull));
            request.lock_timeout_ms = DatumGetInt32(SPI_getbinval(tuple, tupdesc, 8, &isnull));
            request.is_wraparound = DatumGetBool(SPI_getbinval(tuple, tupdesc, 9, &isnull));

            {
                MemoryContext old_context = MemoryContextSwitchTo(TopMemoryContext);

                if (aav_start_emergency_worker(&request, dbname != NULL ? dbname : "?",
                                               &aav_emergency_handle))
                {
                    aav_emergency_current = request;
                    aav_emergency_pid_recorded = false;
                }
                MemoryContextSwitchTo(old_context);
            }

            if (aav_emergency_handle == NULL)
            {
                Oid argtypes[3] = {INT8OID, TEXTOID, TEXTOID};
                Datum values[3];

                values[0] = Int64GetDatum(request.request_id);
                values[1] = CStringGetTextDatum("failed");
                values[2] = CStringGetTextDatum("could not register the emergency worker; check max_worker_processes");
                (void) SPI_execute_with_args(
                    "SELECT adaptive_autovacuum._finish_emergency_request($1, $2, $3)",
                    3, argtypes, values, NULL, false, 0);
                elog(WARNING,
                     "adaptive autovacuum could not register the emergency worker for database %u; check max_worker_processes",
                     request.dboid);
            }
        }

        PopActiveSnapshot();
        SPI_finish();
        CommitTransactionCommand();
    }
}

/* SIGALRM context: flags only; the cancel surfaces at the next CHECK_FOR_INTERRUPTS(). */
static void
aav_emergency_timeout_handler(void)
{
    aav_emergency_timed_out = true;
    QueryCancelPending = true;
    InterruptPending = true;
    SetLatch(MyLatch);
}

PGDLLEXPORT void
adaptive_autovacuum_emergency_main(Datum main_arg)
{
    Oid dboid = DatumGetObjectId(main_arg);
    AAVEmergencyRequest request;
    TimeoutId timeout_id;
    char path[MAXPGPATH];
    char name[64];
    StringInfoData result;

    pqsignal(SIGTERM, aav_sigterm);
    pqsignal(SIGHUP, aav_sighup);
    BackgroundWorkerUnblockSignals();

    memcpy(&request, MyBgworkerEntry->bgw_extra, sizeof(request));
    snprintf(name, sizeof(name), "emergency_" INT64_FORMAT ".out", request.request_id);
    aav_tmp_path(path, sizeof(path), name);
    MemoryContextSwitchTo(TopMemoryContext);
    initStringInfo(&result);

    BackgroundWorkerInitializeConnectionByOid(dboid, InvalidOid, 0);

    /* One emergency VACUUM cluster-wide; slot released by the before_shmem_exit hook. */
    if (!aav_try_acquire_emergency_slot(dboid))
    {
        appendStringInfoString(&result, "failed\nanother emergency VACUUM is already running in this cluster");
        (void) aav_write_file(path, result.data);
        proc_exit(0);
    }

    timeout_id = RegisterTimeout(USER_TIMEOUT, aav_emergency_timeout_handler);

    PG_TRY();
    {
        aav_emergency_timed_out = false;
        if (aav_emergency_timeout_seconds > 0)
            enable_timeout_after(timeout_id, aav_emergency_timeout_seconds * 1000);

        aav_run_emergency_vacuum(&request);

        disable_timeout(timeout_id, false);
        if (aav_emergency_timed_out)
        {
            /* Vacuum finished as the timeout fired; ignore the stale cancel. */
            aav_emergency_timed_out = false;
            QueryCancelPending = false;
        }
        appendStringInfoString(&result, "completed");
    }
    PG_CATCH();
    {
        char *message;

        disable_timeout(timeout_id, false);
        QueryCancelPending = false;
        message = aav_copy_error_message();
        aav_abort_transaction_if_needed();
        MemoryContextSwitchTo(TopMemoryContext);

        if (aav_emergency_timed_out)
        {
            message = psprintf("adaptive_autovacuum.emergency_timeout_seconds (%d s) exceeded: %s",
                               aav_emergency_timeout_seconds, message);
            aav_emergency_timed_out = false;
        }

        appendStringInfo(&result, "failed\n%s", message);
        elog(WARNING,
             "adaptive autovacuum emergency VACUUM failed for relation %u in database %u: %s",
             request.relid, dboid, message);
    }
    PG_END_TRY();

    (void) aav_write_file(path, result.data);
    proc_exit(0);
}

static void
aav_run_emergency_vacuum(const AAVEmergencyRequest *request)
{
    VacuumParams params;
    MemoryContext vac_context;
    MemoryContext old_context;
    List *relations;
    char *work_mem;
    char *cost_limit;
    char *cost_delay;
    char *lock_timeout;

    if (!OidIsValid(request->relid))
        elog(ERROR, "adaptive autovacuum emergency request has invalid relation OID");

    work_mem = psprintf("%dMB", request->work_mem_mb);
    cost_limit = psprintf("%d", request->cost_limit);
    cost_delay = psprintf("%dms", request->cost_delay_ms);
    lock_timeout = psprintf("%dms", request->lock_timeout_ms);

    SetConfigOption("maintenance_work_mem", work_mem, PGC_USERSET, PGC_S_SESSION);
    SetConfigOption("vacuum_cost_limit", cost_limit, PGC_USERSET, PGC_S_SESSION);
    SetConfigOption("vacuum_cost_delay", cost_delay, PGC_USERSET, PGC_S_SESSION);
    SetConfigOption("lock_timeout", lock_timeout, PGC_USERSET, PGC_S_SESSION);

    /* Failsafe-style profile: freeze everything, skip index vacuuming and truncation, TOAST included. */
    MemSet(&params, 0, sizeof(params));
    params.options = VACOPT_VACUUM |
                     VACOPT_PROCESS_MAIN |
                     VACOPT_PROCESS_TOAST;
    params.freeze_min_age = 0;
    params.freeze_table_age = 0;
    params.multixact_freeze_min_age = 0;
    params.multixact_freeze_table_age = 0;
    params.is_wraparound = request->is_wraparound;
    params.log_min_duration = 0;
    params.index_cleanup = VACOPTVALUE_DISABLED;
    params.truncate = VACOPTVALUE_DISABLED;
    params.toast_parent = InvalidOid;
#if PG_VERSION_NUM >= 180000
    params.max_eager_freeze_failure_rate = vacuum_max_eager_freeze_failure_rate;
#endif
    params.nworkers = 0;

    vac_context = AllocSetContextCreate(TopMemoryContext,
                                        "adaptive autovacuum emergency vacuum",
                                        ALLOCSET_DEFAULT_SIZES);
    old_context = MemoryContextSwitchTo(vac_context);
    relations = list_make1(makeVacuumRelation(NULL, request->relid, NIL));
    MemoryContextSwitchTo(old_context);

    /* vacuum() expects an outer command transaction and manages per-relation ones itself. */
    StartTransactionCommand();
    vacuum(relations, &params, NULL, vac_context, true);
    CommitTransactionCommand();

    MemoryContextDelete(vac_context);
}

static void
aav_abort_transaction_if_needed(void)
{
    if (IsTransactionState())
        AbortCurrentTransaction();
}
