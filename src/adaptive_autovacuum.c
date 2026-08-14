/*
 * adaptive_autovacuum.c
 *
 * PostgreSQL 18+ adaptive autovacuum controller.
 *
 * The C layer deliberately owns only process orchestration, host metric
 * collection, and the guarded manual VACUUM execution path.  The control
 * policy and reversible table-reloption changes live in the extension SQL
 * script so they can evolve without relying on additional PostgreSQL internals.
 */

#include "postgres.h"

#include <errno.h>
#include <signal.h>
#ifdef WIN32
#include <windows.h>
#else
#include <unistd.h>
#endif

#include "access/xact.h"
#include "catalog/pg_database.h"
#include "catalog/pg_type_d.h"
#include "commands/vacuum.h"
#include "executor/spi.h"
#include "fmgr.h"
#include "libpq/pqsignal.h"
#include "miscadmin.h"
#include "nodes/makefuncs.h"
#include "nodes/parsenodes.h"
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
#include "utils/jsonb.h"
#include "utils/memutils.h"
#include "utils/resowner.h"
#include "utils/snapmgr.h"
#include "utils/timeout.h"
#include "utils/timestamp.h"
#include "utils/wait_event.h"

/* PostgreSQL 17 is the floor: pg_stat_progress_vacuum gained the
   *_dead_tuple_bytes columns in 17.  On 17 the PG18-only surface degrades
   gracefully: no eager-freeze tuning on emergency vacuums (below), and the
   SQL policy skips autovacuum_vacuum_max_threshold, autovacuum_worker_slots,
   delay_time accounting, and the automatic autovacuum_max_workers apply
   (PGC_POSTMASTER on 17). */
#if PG_VERSION_NUM < 170000
#error "adaptive_autovacuum requires PostgreSQL 17 or later"
#endif

PG_MODULE_MAGIC;

PGDLLEXPORT void _PG_init(void);
PGDLLEXPORT void adaptive_autovacuum_launcher_main(Datum main_arg);
PGDLLEXPORT void adaptive_autovacuum_database_main(Datum main_arg);
PGDLLEXPORT void adaptive_autovacuum_emergency_main(Datum main_arg);

PG_FUNCTION_INFO_V1(adaptive_autovacuum_host_metrics);

static bool aav_enabled = false;
static char *aav_control_database = NULL;
static int aav_naptime_seconds = 60;
static int aav_database_worker_timeout_seconds = 3600;
static int aav_emergency_timeout_seconds = 86400;
static bool aav_log_cycle_summary = true;

static volatile sig_atomic_t aav_got_sigterm = false;
static volatile sig_atomic_t aav_got_sighup = false;
static volatile sig_atomic_t aav_emergency_timed_out = false;


/* ---------- host metrics ---------- */

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
} AAVDatabaseEntry;

typedef struct AAVEmergencyRequest
{
    int64 request_id;
    Oid relid;
    int work_mem_mb;
    int cost_limit;
    int cost_delay_ms;
    int lock_timeout_ms;
    bool is_wraparound;
} AAVEmergencyRequest;

/* Fixed capacity for per-GUC apply timestamps; must cover the whitelist. */
#define AAV_GLOBAL_GUC_SLOTS 16

typedef struct AAVSharedState
{
    slock_t mutex;
    pid_t emergency_worker_pid;
    Oid emergency_database_oid;
    /* Last successful cluster-wide apply per whitelisted GUC, indexed by the
       GUC's position in aav_allowed_global_gucs.  Every database evaluates
       the cluster from its own tables only, so without a shared brake N busy
       databases could each double the same setting within one launcher
       sweep; this limits any one GUC to one apply per cooldown window
       cluster-wide. */
    TimestampTz global_applied_at[AAV_GLOBAL_GUC_SLOTS];
} AAVSharedState;

static AAVSharedState *aav_shared_state = NULL;
static shmem_request_hook_type prev_shmem_request_hook = NULL;
static shmem_startup_hook_type prev_shmem_startup_hook = NULL;

static void aav_sigterm(SIGNAL_ARGS);
static void aav_sighup(SIGNAL_ARGS);
static void aav_shmem_request(void);
static void aav_shmem_startup(void);
static void aav_attach_shared_state(void);
static bool aav_try_acquire_emergency_slot(Oid dboid);
static void aav_release_emergency_slot(int code, Datum arg);
static void aav_collect_host_metrics(AAVHostMetrics *metrics);
#ifdef __linux__
static bool aav_read_int64_file(const char *path, int64 *value);
static void aav_apply_cgroup_memory_limit(AAVHostMetrics *metrics);
#endif
#ifdef WIN32
static double aav_windows_cpu_busy_fraction(void);
#endif
static List *aav_list_databases(void);
static bool aav_run_database_worker(Oid dboid, const char *dbname);
static bool aav_extension_enabled_in_database(void);
static void aav_execute_policy_cycle(const AAVHostMetrics *metrics);
static void aav_apply_global_settings(void);
static bool aav_has_pending_emergency_request(void);
static bool aav_start_emergency_worker(Oid dboid);
static void aav_emergency_timeout_handler(void);
static bool aav_claim_emergency_request(AAVEmergencyRequest *request);
static void aav_finish_emergency_request(const AAVEmergencyRequest *request,
                                         const char *status,
                                         const char *error_text);
static void aav_run_emergency_vacuum(const AAVEmergencyRequest *request);
static void aav_abort_transaction_if_needed(void);

PGDLLEXPORT void
_PG_init(void)
{
    BackgroundWorker worker;

    DefineCustomBoolVariable("adaptive_autovacuum.enabled",
                             "Enable the adaptive autovacuum launcher.",
                             "The SQL policy in each database must also be enabled.",
                             &aav_enabled,
                             false,
                             PGC_SIGHUP,
                             0,
                             NULL,
                             NULL,
                             NULL);

    /* PGC_SIGHUP, not PGC_POSTMASTER: _PG_init also runs when the library is
       loaded on demand (CREATE EXTENSION without shared_preload_libraries),
       and defining a PGC_POSTMASTER custom variable after startup is FATAL.
       The launcher reads this at startup; changes take effect when it
       restarts. */
    DefineCustomStringVariable("adaptive_autovacuum.control_database",
                               "Database used by the cluster launcher.",
                               "The launcher reads pg_database here and starts one database worker at a time.",
                               &aav_control_database,
                               "postgres",
                               PGC_SIGHUP,
                               0,
                               NULL,
                               NULL,
                               NULL);

    DefineCustomIntVariable("adaptive_autovacuum.naptime_seconds",
                            "Seconds between complete cluster scans.",
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

    DefineCustomIntVariable("adaptive_autovacuum.database_worker_timeout_seconds",
                            "Maximum time the launcher waits for one database worker.",
                            "Covers the policy cycle only; emergency VACUUMs run in a "
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

    /* A long emergency VACUUM must never be killed by the database-worker
       supervision timeout (that produced an abort/retry livelock on tables
       whose freeze pass exceeds one hour), so the dedicated emergency worker
       carries its own, much longer budget.  0 disables the timeout. */
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
                             "Log one summary line for every database cycle.",
                             NULL,
                             &aav_log_cycle_summary,
                             true,
                             PGC_SIGHUP,
                             0,
                             NULL,
                             NULL,
                             NULL);

    MarkGUCPrefixReserved("adaptive_autovacuum");

    if (!process_shared_preload_libraries_in_progress)
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
    }
    LWLockRelease(AddinShmemInitLock);
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
             "adaptive autovacuum shared state is unavailable; emergency VACUUM is disabled for this cycle");
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
/*
 * Windows has no load average.  Sample the system-wide CPU busy fraction
 * over a short window instead.  GetSystemTimes() kernel time includes idle
 * time, so busy = (kernel + user - idle) / (kernel + user).
 */
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

        /*
         * CPU busy fraction scaled by CPU count approximates a load average.
         * Unlike a Unix load average it has no run-queue component and so
         * cannot exceed the CPU count; Windows deployments should size
         * policy.high_load_per_cpu accordingly (e.g. 0.85 instead of 1.5).
         */
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


/* ---------- launcher ---------- */

PGDLLEXPORT void
adaptive_autovacuum_launcher_main(Datum main_arg)
{
    MemoryContext cycle_context;

    (void) main_arg;

    pqsignal(SIGTERM, aav_sigterm);
    pqsignal(SIGHUP, aav_sighup);
    BackgroundWorkerUnblockSignals();

    BackgroundWorkerInitializeConnection(aav_control_database, NULL, 0);

    cycle_context = AllocSetContextCreate(TopMemoryContext,
                                          "adaptive autovacuum launcher cycle",
                                          ALLOCSET_DEFAULT_SIZES);

    elog(LOG, "adaptive autovacuum launcher started on control database \"%s\"",
         aav_control_database);

    while (!aav_got_sigterm)
    {
        int rc;

        if (aav_got_sighup)
        {
            aav_got_sighup = false;
            ProcessConfigFile(PGC_SIGHUP);
        }

        if (aav_enabled)
        {
            MemoryContext old_context;
            List *databases;
            ListCell *lc;

            MemoryContextReset(cycle_context);
            old_context = MemoryContextSwitchTo(cycle_context);
            databases = aav_list_databases();

            foreach(lc, databases)
            {
                AAVDatabaseEntry *entry = lfirst(lc);
                Oid dboid = entry->dboid;
                char *dbname = entry->dbname;

                if (aav_got_sigterm)
                    break;

                (void) aav_run_database_worker(dboid, dbname);
            }

            MemoryContextSwitchTo(old_context);
        }

        rc = WaitLatch(MyLatch,
                       WL_LATCH_SET | WL_TIMEOUT | WL_POSTMASTER_DEATH,
                       (long) aav_naptime_seconds * 1000L,
                       PG_WAIT_EXTENSION);
        ResetLatch(MyLatch);

        if (rc & WL_POSTMASTER_DEATH)
            proc_exit(1);

        /*
         * Absorb pending interrupts, notably ProcSignalBarriers: DROP
         * DATABASE waits on every process in the cluster, so a wait loop
         * without this blocks it indefinitely.
         */
        CHECK_FOR_INTERRUPTS();
    }

    elog(LOG, "adaptive autovacuum launcher shutting down");
    proc_exit(0);
}

static List *
aav_list_databases(void)
{
    MemoryContext caller_context = CurrentMemoryContext;
    List *result = NIL;
    int spi_rc;
    uint64 i;

    StartTransactionCommand();
    SPI_connect();
    PushActiveSnapshot(GetTransactionSnapshot());

    spi_rc = SPI_execute(
        "SELECT oid, datname "
        "FROM pg_catalog.pg_database "
        "WHERE datallowconn "
        "  AND NOT datistemplate "
        "ORDER BY oid",
        true,
        0);

    if (spi_rc != SPI_OK_SELECT)
        elog(ERROR, "adaptive autovacuum could not list databases: SPI code %d",
             spi_rc);

    for (i = 0; i < SPI_processed; i++)
    {
        HeapTuple tuple = SPI_tuptable->vals[i];
        TupleDesc tupdesc = SPI_tuptable->tupdesc;
        bool isnull;
        Oid dboid;
        char *dbname;
        MemoryContext old_context;
        AAVDatabaseEntry *entry;

        dboid = DatumGetObjectId(SPI_getbinval(tuple, tupdesc, 1, &isnull));
        if (isnull)
            continue;

        dbname = SPI_getvalue(tuple, tupdesc, 2);
        if (dbname == NULL)
            continue;

        old_context = MemoryContextSwitchTo(caller_context);
        entry = palloc0(sizeof(*entry));
        entry->dboid = dboid;
        entry->dbname = pstrdup(dbname);
        result = lappend(result, entry);
        MemoryContextSwitchTo(old_context);
    }

    PopActiveSnapshot();
    SPI_finish();
    CommitTransactionCommand();

    return result;
}

static bool
aav_run_database_worker(Oid dboid, const char *dbname)
{
    BackgroundWorker worker;
    BackgroundWorkerHandle *handle;
    BgwHandleStatus status;
    pid_t pid;
    TimestampTz started_at;

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

    if (!RegisterDynamicBackgroundWorker(&worker, &handle))
    {
        elog(WARNING,
             "adaptive autovacuum could not register worker for database \"%s\"; check max_worker_processes",
             dbname);
        return false;
    }

    status = WaitForBackgroundWorkerStartup(handle, &pid);
    (void) pid;
    if (status != BGWH_STARTED)
    {
        if (status == BGWH_POSTMASTER_DIED)
            proc_exit(1);

        elog(WARNING,
             "adaptive autovacuum worker for database \"%s\" did not start",
             dbname);
        return false;
    }

    started_at = GetCurrentTimestamp();

    for (;;)
    {
        BgwHandleStatus pid_status;
        pid_t current_pid;
        long elapsed_ms;
        int rc;

        pid_status = GetBackgroundWorkerPid(handle, &current_pid);
        (void) current_pid;
        if (pid_status == BGWH_STOPPED)
            return true;
        if (pid_status == BGWH_POSTMASTER_DIED)
            proc_exit(1);

        elapsed_ms = (long) ((GetCurrentTimestamp() - started_at) / 1000);
        if (elapsed_ms >= (long) aav_database_worker_timeout_seconds * 1000L)
        {
            elog(WARNING,
                 "adaptive autovacuum database worker \"%s\" exceeded timeout; requesting termination",
                 dbname);
            TerminateBackgroundWorker(handle);
            (void) WaitForBackgroundWorkerShutdown(handle);
            return false;
        }

        rc = WaitLatch(MyLatch,
                       WL_LATCH_SET | WL_TIMEOUT | WL_POSTMASTER_DEATH,
                       1000L,
                       PG_WAIT_EXTENSION);
        ResetLatch(MyLatch);

        if (rc & WL_POSTMASTER_DEATH)
            proc_exit(1);

        /* Keep ProcSignalBarriers (e.g. DROP DATABASE) moving. */
        CHECK_FOR_INTERRUPTS();
        if (aav_got_sigterm)
        {
            TerminateBackgroundWorker(handle);
            (void) WaitForBackgroundWorkerShutdown(handle);
            return false;
        }
    }
}

/* ---------- per-database worker ---------- */

PGDLLEXPORT void
adaptive_autovacuum_database_main(Datum main_arg)
{
    Oid dboid = DatumGetObjectId(main_arg);
    AAVHostMetrics metrics;
    bool started_emergency = false;

    pqsignal(SIGTERM, aav_sigterm);
    pqsignal(SIGHUP, aav_sighup);
    BackgroundWorkerUnblockSignals();

    BackgroundWorkerInitializeConnectionByOid(dboid, InvalidOid, 0);

    PG_TRY();
    {
        if (!aav_extension_enabled_in_database())
            proc_exit(0);

        aav_collect_host_metrics(&metrics);
        aav_execute_policy_cycle(&metrics);
        aav_apply_global_settings();

        /*
         * Emergency VACUUMs run in a dedicated worker (fire-and-forget):
         * executing them here put the vacuum under the launcher's
         * database_worker_timeout_seconds, so a freeze pass longer than that
         * was killed and retried forever, and it stalled the launcher's scan
         * of the remaining databases for up to the whole timeout.
         */
        if (!aav_got_sigterm && aav_has_pending_emergency_request())
            started_emergency = aav_start_emergency_worker(dboid);

        if (aav_log_cycle_summary)
            elog(LOG,
                 "adaptive autovacuum cycle completed for database %u%s",
                 dboid,
                 started_emergency ? "; emergency VACUUM worker started" : "");
    }
    PG_CATCH();
    {
        ErrorData *edata;
        MemoryContext old_context;
        char *message;

        old_context = MemoryContextSwitchTo(TopMemoryContext);
        edata = CopyErrorData();
        message = pstrdup(edata->message ? edata->message : "unknown error");
        MemoryContextSwitchTo(old_context);

        FlushErrorState();
        aav_abort_transaction_if_needed();
        elog(WARNING,
             "adaptive autovacuum database cycle failed for database %u: %s",
             dboid,
             message);
        FreeErrorData(edata);
    }
    PG_END_TRY();

    proc_exit(0);
}

static bool
aav_extension_enabled_in_database(void)
{
    bool installed = false;
    bool enabled = false;
    int spi_rc;
    bool isnull;

    StartTransactionCommand();
    SPI_connect();
    PushActiveSnapshot(GetTransactionSnapshot());

    spi_rc = SPI_execute(
        "SELECT EXISTS ("
        "  SELECT 1 FROM pg_catalog.pg_extension "
        "  WHERE extname = 'adaptive_autovacuum'"
        ")",
        true,
        1);

    if (spi_rc == SPI_OK_SELECT && SPI_processed == 1)
    {
        installed = DatumGetBool(SPI_getbinval(SPI_tuptable->vals[0],
                                              SPI_tuptable->tupdesc,
                                              1,
                                              &isnull));
        if (isnull)
            installed = false;
    }

    if (installed)
    {
        spi_rc = SPI_execute(
            "SELECT COALESCE(("
            "  SELECT enabled FROM adaptive_autovacuum.policy WHERE singleton"
            "), false)",
            true,
            1);

        if (spi_rc == SPI_OK_SELECT && SPI_processed == 1)
        {
            enabled = DatumGetBool(SPI_getbinval(SPI_tuptable->vals[0],
                                                SPI_tuptable->tupdesc,
                                                1,
                                                &isnull));
            if (isnull)
                enabled = false;
        }
    }

    PopActiveSnapshot();
    SPI_finish();
    CommitTransactionCommand();

    return installed && enabled;
}

static void
aav_execute_policy_cycle(const AAVHostMetrics *metrics)
{
    Oid argtypes[4] = {FLOAT8OID, INT4OID, INT8OID, INT8OID};
    Datum values[4];
    char nulls[4] = {' ', ' ', ' ', ' '};
    int spi_rc;

    values[0] = Float8GetDatum(metrics->load1);
    values[1] = Int32GetDatum(metrics->cpu_count);
    values[2] = Int64GetDatum(metrics->mem_available_bytes);
    values[3] = Int64GetDatum(metrics->mem_total_bytes);

    StartTransactionCommand();
    SPI_connect();
    PushActiveSnapshot(GetTransactionSnapshot());

    spi_rc = SPI_execute_with_args(
        "SELECT adaptive_autovacuum._run_cycle($1, $2, $3, $4)",
        4,
        argtypes,
        values,
        nulls,
        false,
        0);

    if (spi_rc != SPI_OK_SELECT)
        elog(ERROR, "adaptive autovacuum policy cycle returned SPI code %d",
             spi_rc);

    PopActiveSnapshot();
    SPI_finish();
    CommitTransactionCommand();
}

/*
 * GUCs the policy is allowed to change cluster-wide.  Everything else queued
 * in global_apply_queue is rejected and marked failed.
 */
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
};

StaticAssertDecl(lengthof(aav_allowed_global_gucs) <= AAV_GLOBAL_GUC_SLOTS,
                 "aav_allowed_global_gucs exceeds AAV_GLOBAL_GUC_SLOTS");

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

/*
 * Apply pending cluster-wide setting changes queued by the SQL policy.
 *
 * ALTER SYSTEM cannot be executed through SPI (PreventInTransactionBlock
 * rejects utility statements coming from functions), so this calls the
 * exported AlterSystemSetConfigFile() entry point directly and then signals
 * the postmaster to reload.  Autovacuum settings changed here are all
 * PGC_SIGHUP in PostgreSQL 18, so they take effect without a restart.
 */
static void
aav_apply_global_settings(void)
{
    int spi_rc;
    bool isnull;
    uint64 nrows;
    uint64 i;
    int64 *ids;
    char **names;
    char **values;
    int applied_count = 0;

    StartTransactionCommand();
    SPI_connect();
    PushActiveSnapshot(GetTransactionSnapshot());

    /* Tolerate an older extension SQL version without the queue table. */
    spi_rc = SPI_execute(
        "SELECT to_regclass('adaptive_autovacuum.global_apply_queue') IS NOT NULL",
        true, 1);
    if (spi_rc != SPI_OK_SELECT || SPI_processed != 1 ||
        !DatumGetBool(SPI_getbinval(SPI_tuptable->vals[0],
                                    SPI_tuptable->tupdesc, 1, &isnull)) ||
        isnull)
    {
        PopActiveSnapshot();
        SPI_finish();
        CommitTransactionCommand();
        return;
    }

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

        /*
         * Cross-database cooldown: each database recommends cluster settings
         * from its own tables only, so several busy databases could each
         * double the same GUC within one launcher sweep (2^N escalation).
         * Allow one cluster-wide apply per GUC per two naptimes; a skipped
         * row simply stays pending and is retried on a later cycle.
         */
        if (aav_shared_state == NULL)
            aav_attach_shared_state();
        if (aav_shared_state != NULL)
        {
            TimestampTz last_applied;

            SpinLockAcquire(&aav_shared_state->mutex);
            last_applied = aav_shared_state->global_applied_at[guc_index];
            SpinLockRelease(&aav_shared_state->mutex);

            if (last_applied != 0 &&
                !TimestampDifferenceExceeds(last_applied,
                                            GetCurrentTimestamp(),
                                            2 * aav_naptime_seconds * 1000))
                continue;
        }

        if (values[i] == NULL || values[i][0] == '\0' ||
            strlen(values[i]) >= 32 ||
            strspn(values[i], "0123456789.-") != strlen(values[i]))
        {
            aav_mark_global_change(ids[i], "failed", NULL,
                                   "Value is not a plain numeric literal.");
            continue;
        }

        /*
         * autovacuum_max_workers must not exceed autovacuum_worker_slots:
         * the server ACCEPTS a larger value (it only warns and caps the
         * effective worker count at runtime), so neither the GUC bounds
         * validation below nor the SQL policy's queue-time pg_settings check
         * would reject it.  The policy caps its own recommendation, but a
         * queued row can outlive a restart that lowered the slot count
         * (autovacuum_worker_slots is postmaster-context), and manual queue
         * inserts bypass the policy entirely.  The slots GUC does not exist
         * before PostgreSQL 18, so this check is inert there.
         */
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

        /*
         * AlterSystemSetConfigFile() runs the GUC's own parse/bounds
         * validation and ERRORs on a value the server would not accept.
         * Isolate each row in a subtransaction so one bad value is marked
         * failed and the remaining rows still apply; without this the whole
         * apply transaction aborts, every row stays pending, and the worker
         * re-hits the same error each cycle until the one-hour queue expiry.
         */
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

        if (aav_shared_state != NULL)
        {
            SpinLockAcquire(&aav_shared_state->mutex);
            aav_shared_state->global_applied_at[guc_index] = GetCurrentTimestamp();
            SpinLockRelease(&aav_shared_state->mutex);
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

/* ---------- emergency worker ---------- */

static bool
aav_has_pending_emergency_request(void)
{
    bool pending = false;
    int spi_rc;
    bool isnull;

    StartTransactionCommand();
    SPI_connect();
    PushActiveSnapshot(GetTransactionSnapshot());

    spi_rc = SPI_execute(
        "SELECT EXISTS ("
        "  SELECT 1 FROM adaptive_autovacuum.emergency_queue "
        "  WHERE status = 'pending' "
        "    AND next_retry_at <= clock_timestamp()"
        ")",
        true,
        1);

    if (spi_rc == SPI_OK_SELECT && SPI_processed == 1)
    {
        pending = DatumGetBool(SPI_getbinval(SPI_tuptable->vals[0],
                                             SPI_tuptable->tupdesc,
                                             1,
                                             &isnull));
        if (isnull)
            pending = false;
    }

    PopActiveSnapshot();
    SPI_finish();
    CommitTransactionCommand();

    return pending;
}

/*
 * Fire-and-forget: the database worker only registers the emergency worker
 * and exits.  Serialization happens inside the emergency worker via the
 * shared-memory slot; if another emergency VACUUM is already running
 * cluster-wide the new worker exits immediately and the queued request is
 * retried on a later cycle.
 */
static bool
aav_start_emergency_worker(Oid dboid)
{
    BackgroundWorker worker;

    MemSet(&worker, 0, sizeof(worker));
    snprintf(worker.bgw_name, BGW_MAXLEN,
             "adaptive autovacuum emergency worker");
    snprintf(worker.bgw_type, BGW_MAXLEN,
             "adaptive autovacuum emergency worker");
    worker.bgw_flags = BGWORKER_SHMEM_ACCESS |
                       BGWORKER_BACKEND_DATABASE_CONNECTION;
    worker.bgw_start_time = BgWorkerStart_RecoveryFinished;
    worker.bgw_restart_time = BGW_NEVER_RESTART;
    snprintf(worker.bgw_library_name, MAXPGPATH, "adaptive_autovacuum");
    snprintf(worker.bgw_function_name, BGW_MAXLEN,
             "adaptive_autovacuum_emergency_main");
    worker.bgw_main_arg = ObjectIdGetDatum(dboid);
    worker.bgw_notify_pid = 0;

    if (!RegisterDynamicBackgroundWorker(&worker, NULL))
    {
        elog(WARNING,
             "adaptive autovacuum could not register the emergency worker for database %u; check max_worker_processes",
             dboid);
        return false;
    }

    return true;
}

/*
 * SIGALRM context: flags only.  QueryCancelPending makes the next
 * CHECK_FOR_INTERRUPTS() inside vacuum() throw a cancel error, which the
 * per-request PG_CATCH turns into a 'failed' queue row.
 */
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
    int processed = 0;

    pqsignal(SIGTERM, aav_sigterm);
    pqsignal(SIGHUP, aav_sighup);
    BackgroundWorkerUnblockSignals();

    BackgroundWorkerInitializeConnectionByOid(dboid, InvalidOid, 0);

    /* One emergency VACUUM cluster-wide; the slot is released by the
       before_shmem_exit hook even on abnormal exit. */
    if (!aav_try_acquire_emergency_slot(dboid))
        proc_exit(0);

    timeout_id = RegisterTimeout(USER_TIMEOUT, aav_emergency_timeout_handler);

    /* Drain the queue serially; each request gets its own timeout budget. */
    while (!aav_got_sigterm && aav_claim_emergency_request(&request))
    {
        PG_TRY();
        {
            aav_emergency_timed_out = false;
            if (aav_emergency_timeout_seconds > 0)
                enable_timeout_after(timeout_id,
                                     aav_emergency_timeout_seconds * 1000);

            aav_run_emergency_vacuum(&request);

            disable_timeout(timeout_id, false);
            if (aav_emergency_timed_out)
            {
                /* The vacuum finished in the same instant the timeout fired;
                   do not let the stale cancel abort the bookkeeping. */
                aav_emergency_timed_out = false;
                QueryCancelPending = false;
            }
            aav_finish_emergency_request(&request, "completed", NULL);
        }
        PG_CATCH();
        {
            ErrorData *edata;
            MemoryContext old_context;
            char *message;

            disable_timeout(timeout_id, false);
            QueryCancelPending = false;

            old_context = MemoryContextSwitchTo(TopMemoryContext);
            edata = CopyErrorData();
            message = pstrdup(edata->message ? edata->message : "unknown error");
            MemoryContextSwitchTo(old_context);

            FlushErrorState();
            aav_abort_transaction_if_needed();

            if (aav_emergency_timed_out)
            {
                message = psprintf("adaptive_autovacuum.emergency_timeout_seconds (%d s) exceeded: %s",
                                   aav_emergency_timeout_seconds, message);
                aav_emergency_timed_out = false;
            }

            aav_finish_emergency_request(&request, "failed", message);
            FreeErrorData(edata);

            elog(WARNING,
                 "adaptive autovacuum emergency VACUUM failed for relation %u: %s",
                 request.relid,
                 message);
        }
        PG_END_TRY();

        processed++;
    }

    if (aav_log_cycle_summary)
        elog(LOG,
             "adaptive autovacuum emergency worker for database %u processed %d request(s)",
             dboid,
             processed);

    proc_exit(0);
}

static bool
aav_claim_emergency_request(AAVEmergencyRequest *request)
{
    int spi_rc;
    bool isnull;
    bool claimed = false;

    MemSet(request, 0, sizeof(*request));

    StartTransactionCommand();
    SPI_connect();
    PushActiveSnapshot(GetTransactionSnapshot());

    spi_rc = SPI_execute(
        "WITH candidate AS ("
        "  SELECT id "
        "  FROM adaptive_autovacuum.emergency_queue "
        "  WHERE status = 'pending' "
        "    AND next_retry_at <= clock_timestamp() "
        "  ORDER BY priority DESC, requested_at "
        "  LIMIT 1 "
        "  FOR UPDATE SKIP LOCKED"
        ") "
        "UPDATE adaptive_autovacuum.emergency_queue q "
        "SET status = 'running', "
        "    started_at = clock_timestamp(), "
        "    worker_pid = pg_backend_pid(), "
        "    attempts = attempts + 1 "
        "FROM candidate "
        "WHERE q.id = candidate.id "
        "RETURNING q.id, q.relid, q.work_mem_mb, q.cost_limit, "
        "          q.cost_delay_ms, q.lock_timeout_ms, q.is_wraparound",
        false,
        1);

    if (spi_rc != SPI_OK_UPDATE_RETURNING)
        elog(ERROR, "adaptive autovacuum could not claim emergency request: SPI code %d",
             spi_rc);

    if (SPI_processed == 1)
    {
        HeapTuple tuple = SPI_tuptable->vals[0];
        TupleDesc tupdesc = SPI_tuptable->tupdesc;

        request->request_id = DatumGetInt64(SPI_getbinval(tuple, tupdesc, 1, &isnull));
        request->relid = DatumGetObjectId(SPI_getbinval(tuple, tupdesc, 2, &isnull));
        request->work_mem_mb = DatumGetInt32(SPI_getbinval(tuple, tupdesc, 3, &isnull));
        request->cost_limit = DatumGetInt32(SPI_getbinval(tuple, tupdesc, 4, &isnull));
        request->cost_delay_ms = DatumGetInt32(SPI_getbinval(tuple, tupdesc, 5, &isnull));
        request->lock_timeout_ms = DatumGetInt32(SPI_getbinval(tuple, tupdesc, 6, &isnull));
        request->is_wraparound = DatumGetBool(SPI_getbinval(tuple, tupdesc, 7, &isnull));
        claimed = true;
    }

    PopActiveSnapshot();
    SPI_finish();
    CommitTransactionCommand();

    return claimed;
}

static void
aav_finish_emergency_request(const AAVEmergencyRequest *request,
                             const char *status,
                             const char *error_text)
{
    Oid argtypes[3] = {INT8OID, TEXTOID, TEXTOID};
    Datum values[3];
    char nulls[3] = {' ', ' ', ' '};
    int spi_rc;

    values[0] = Int64GetDatum(request->request_id);
    values[1] = CStringGetTextDatum(status);
    if (error_text != NULL)
        values[2] = CStringGetTextDatum(error_text);
    else
    {
        values[2] = (Datum) 0;
        nulls[2] = 'n';
    }

    StartTransactionCommand();
    SPI_connect();
    PushActiveSnapshot(GetTransactionSnapshot());

    /* Escalating backoff: the Nth recent failure for the same relation waits
       N x 5 minutes (capped at 2 hours) before the policy may requeue it, so
       a vacuum that keeps failing cannot become a fixed-cadence retry storm. */
    spi_rc = SPI_execute_with_args(
        "UPDATE adaptive_autovacuum.emergency_queue q "
        "SET status = $2, "
        "    finished_at = clock_timestamp(), "
        "    last_error = $3, "
        "    next_retry_at = CASE WHEN $2 = 'failed' "
        "                         THEN clock_timestamp() "
        "                              + LEAST(24, 1 + (SELECT count(*) "
        "                                               FROM adaptive_autovacuum.emergency_queue f "
        "                                               WHERE f.relid = q.relid "
        "                                                 AND f.id <> q.id "
        "                                                 AND f.status = 'failed' "
        "                                                 AND f.finished_at > clock_timestamp() - interval '24 hours')) "
        "                                * interval '5 minutes' "
        "                         ELSE q.next_retry_at END "
        "WHERE q.id = $1",
        3,
        argtypes,
        values,
        nulls,
        false,
        0);

    if (spi_rc != SPI_OK_UPDATE)
        elog(WARNING,
             "adaptive autovacuum could not update emergency request " INT64_FORMAT,
             request->request_id);

    PopActiveSnapshot();
    SPI_finish();
    CommitTransactionCommand();
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

    /*
     * Emergency profile, matching PostgreSQL's own wraparound failsafe: the
     * goal is advancing relfrozenxid, not reclaiming space.  Freeze
     * everything visible (min ages 0), force an aggressive scan (table ages
     * 0), skip index vacuuming (the most expensive phase, irrelevant to
     * freezing; a later normal vacuum cleans the indexes), and skip the
     * tail-truncation phase (needs ACCESS EXCLUSIVE).  TOAST is still
     * processed because it carries its own relfrozenxid.
     */
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

    /*
     * vacuum() is PostgreSQL's exported internal entry point.  Like the core
     * utility command, it expects an outer command transaction and manages
     * per-relation transactions itself.
     */
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

