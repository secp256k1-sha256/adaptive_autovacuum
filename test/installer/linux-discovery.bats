#!/usr/bin/env bats
# Unit tests for the pure parts of adaptive-autovacuum-setup: preload list handling,
# candidate merging, installation attachment, argument validation and exit codes.
# Runs without PostgreSQL (jq required).

SETUP="${BATS_TEST_DIRNAME}/../../packaging/linux/adaptive-autovacuum-setup"

setup() {
    export AAV_STATE_DIR="$BATS_TEST_TMPDIR/state" AAV_LOG_DIR="$BATS_TEST_TMPDIR/log"
}

lib() {  # run a snippet with the helper sourced in library mode
    AAV_SETUP_LIBRARY_MODE=1 bash -c "source '$SETUP'; $1"
}

@test "preload_lists recognises plain, quoted, \$libdir and suffixed entries" {
    lib "preload_lists 'adaptive_autovacuum'"
    lib "preload_lists 'pg_stat_statements, adaptive_autovacuum'"
    lib "preload_lists '\"\$libdir/adaptive_autovacuum\"'"
    lib "preload_lists 'adaptive_autovacuum.so'"
    lib "preload_lists \"'adaptive_autovacuum'\""
}

@test "preload_lists rejects absent, empty and near-miss names" {
    ! lib "preload_lists ''"
    ! lib "preload_lists 'pg_stat_statements,auto_explain'"
    ! lib "preload_lists 'adaptive_autovacuum_extra'"
    ! lib "preload_lists 'my_adaptive_autovacuum'"
}

@test "preload_append keeps existing entries and their order" {
    [ "$(lib "preload_append ''")" = "adaptive_autovacuum" ]
    [ "$(lib "preload_append 'pg_stat_statements,auto_explain'")" = "pg_stat_statements,auto_explain,adaptive_autovacuum" ]
    [ "$(lib "preload_append '  pg_stat_statements  '")" = "pg_stat_statements,adaptive_autovacuum" ]
}

@test "preload_remove drops only our library and preserves order" {
    [ "$(lib "preload_remove 'pg_stat_statements, adaptive_autovacuum, auto_explain'")" = "pg_stat_statements,auto_explain" ]
    [ "$(lib "preload_remove 'adaptive_autovacuum'")" = "" ]
    [ "$(lib "preload_remove '\$libdir/adaptive_autovacuum,pg_stat_statements'")" = "pg_stat_statements" ]
    [ "$(lib "preload_remove 'pg_stat_statements'")" = "pg_stat_statements" ]
}

@test "add_cluster merges records by canonical data directory and unions sources" {
    out=$(lib "CLUSTERS='[]'; add_cluster data_directory=/var/lib/pgsql/18/data service_name=postgresql-18.service discovery_sources=systemd;
                add_cluster data_directory=/var/lib/pgsql/18/data port=5432 pid=42 discovery_sources=process;
                add_cluster data_directory=/var/lib/pgsql/17/data port=5433 discovery_sources=process; printf '%s' \"\$CLUSTERS\"")
    [ "$(jq length <<<"$out")" = "2" ]
    [ "$(jq -r '.[0].service_name' <<<"$out")" = "postgresql-18.service" ]
    [ "$(jq -r '.[0].port' <<<"$out")" = "5432" ]
    [ "$(jq -r '.[0].pid' <<<"$out")" = "42" ]
    [ "$(jq -c '.[0].discovery_sources' <<<"$out")" = '["process","systemd"]' ]
}

@test "finalize_candidates attaches the unique installation of the same major and marks support" {
    out=$(lib "CLUSTERS='[{\"data_directory\":\"/d18\",\"postgres_major\":18,\"port\":5432},{\"data_directory\":\"/d16\",\"postgres_major\":16,\"port\":5433}]';
                INSTALLS='[{\"bindir\":\"/usr/pgsql-18/bin\",\"postgres_full_version\":\"18.6\",\"postgres_major\":18,\"pkglibdir\":\"/usr/pgsql-18/lib\",\"sharedir\":\"/usr/pgsql-18/share\"}]';
                finalize_candidates; printf '%s' \"\$CLUSTERS\"")
    [ "$(jq -r '.[0].bindir' <<<"$out")" = "/usr/pgsql-18/bin" ]
    [ "$(jq -r '.[0].psql_path' <<<"$out")" = "/usr/pgsql-18/bin/psql" ]
    [ "$(jq -r '.[0].supported' <<<"$out")" = "true" ]
    [ "$(jq -r '.[1].supported' <<<"$out")" = "false" ]
    [ "$(jq -r '.[1].bindir // "none"' <<<"$out")" = "none" ]
    [ "$(jq -r '.[0].candidate_id' <<<"$out")" != "$(jq -r '.[1].candidate_id' <<<"$out")" ]
}

@test "finalize_candidates never guesses between two installations of the same major" {
    out=$(lib "CLUSTERS='[{\"data_directory\":\"/d18\",\"postgres_major\":18}]';
                INSTALLS='[{\"bindir\":\"/a/bin\",\"postgres_major\":18,\"postgres_full_version\":\"18.6\"},{\"bindir\":\"/b/bin\",\"postgres_major\":18,\"postgres_full_version\":\"18.5\"}]';
                finalize_candidates; printf '%s' \"\$CLUSTERS\"")
    [ "$(jq -r '.[0].bindir // "none"' <<<"$out")" = "none" ]
}

@test "unknown command and bad options exit 2" {
    run bash "$SETUP" bogus
    [ "$status" -eq 2 ]
    run bash "$SETUP" check --format xml
    [ "$status" -eq 2 ]
    run bash "$SETUP" check --port abc
    [ "$status" -eq 2 ]
    run bash "$SETUP" check --cluster main
    [ "$status" -eq 2 ]
    run bash "$SETUP" check --data-dir /nonexistent/pgdata
    [ "$status" -eq 2 ]
}

@test "version and help exit 0" {
    run bash "$SETUP" version
    [ "$status" -eq 0 ]
    [ "$output" = "1.2.0" ]
    run bash "$SETUP" --help
    [ "$status" -eq 0 ]
}

@test "check exits 3 and prints valid JSON when no supported major exists" {
    AAV_SUPPORTED_MAJORS=99 run bash "$SETUP" check --json
    [ "$status" -eq 3 ]
    jq -e '.supported_majors == [99] and (.selectable | length) == 0 and (.clusters | type == "array")' <<<"$output"
}

@test "check without --json exits 3 when no supported major exists" {
    AAV_SUPPORTED_MAJORS=99 run bash "$SETUP" check
    [ "$status" -eq 3 ]
    [[ "$output" == *"No supported PostgreSQL cluster found"* ]]
}

@test "install refuses to run without root" {
    if [ "$(id -u)" -eq 0 ]; then skip "running as root"; fi
    run bash "$SETUP" install --control-database postgres --yes
    [ "$status" -eq 7 ]
}
