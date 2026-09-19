#!/usr/bin/env bats
# Integration tests for adaptive-autovacuum-setup against a real cluster.
# Skipped unless AAV_TEST_LIVE=1 and the helper can select a supported running cluster
# (CI runs this as root inside a container with one cluster and the extension files installed).
# With several supported clusters on the host, pass selection args: AAV_TEST_ARGS="--pg-major 18".

SETUP="${BATS_TEST_DIRNAME}/../../packaging/linux/adaptive-autovacuum-setup"

setup() {
    [ "${AAV_TEST_LIVE:-0}" = "1" ] || skip "set AAV_TEST_LIVE=1 to run against a live cluster"
    [ "$(id -u)" -eq 0 ] || skip "needs root"
    bash "$SETUP" check --json ${AAV_TEST_ARGS:-} >/dev/null 2>&1 || skip "no supported running cluster"
}

@test "install --dry-run changes nothing and exits 0" {
    before=$(bash "$SETUP" check --json ${AAV_TEST_ARGS:-} | jq -c '.selectable[0] | {shared_preload_libraries}')
    run bash "$SETUP" install --database postgres --dry-run ${AAV_TEST_ARGS:-}
    [ "$status" -eq 0 ]
    [[ "$output" == *"Dry run: nothing changed."* ]]
    after=$(bash "$SETUP" check --json ${AAV_TEST_ARGS:-} | jq -c '.selectable[0] | {shared_preload_libraries}')
    [ "$before" = "$after" ]
}

@test "install without an activation target exits 2 in non-interactive mode" {
    run bash "$SETUP" install --yes </dev/null ${AAV_TEST_ARGS:-}
    [ "$status" -eq 2 ]
}

@test "install --database postgres --yes completes and doctor reports no FAIL" {
    run bash "$SETUP" install --database postgres --yes ${AAV_TEST_ARGS:-}
    [ "$status" -eq 0 ]
    [[ "$output" == *"Installation complete."* ]]
    run --separate-stderr bash "$SETUP" doctor --format json ${AAV_TEST_ARGS:-}
    [ "$status" -eq 0 ]
    jq -e '.databases[] | select(.database == "postgres") | .status.extension_version != null and (.checks | map(select(.status == "FAIL")) | length == 0)' <<<"$output"
    [ "$(jq -r '.last_run.final_state' <<<"$output")" = "completed" ]
}

@test "rerun is idempotent: no preload change, no restart" {
    run bash "$SETUP" install --database postgres --yes ${AAV_TEST_ARGS:-}
    [ "$status" -eq 0 ]
    [[ "$output" == *"Preload change:   none"* ]]
    [[ "$output" == *"Restart:          not needed"* ]]
}

@test "disable and enable toggle the launcher GUC" {
    run bash "$SETUP" disable --yes ${AAV_TEST_ARGS:-}
    [ "$status" -eq 0 ]
    run --separate-stderr bash "$SETUP" doctor --format json ${AAV_TEST_ARGS:-}
    [ "$(jq -r '.databases[0].status.launcher_enabled' <<<"$output")" = "false" ]
    run bash "$SETUP" enable --yes ${AAV_TEST_ARGS:-}
    [ "$status" -eq 0 ]
    run --separate-stderr bash "$SETUP" doctor --format json ${AAV_TEST_ARGS:-}
    [ "$(jq -r '.databases[0].status.launcher_enabled' <<<"$output")" = "true" ]
}

@test "remove-preload keeps other libraries and restarts cleanly" {
    run bash "$SETUP" remove-preload --yes ${AAV_TEST_ARGS:-}
    [ "$status" -eq 0 ]
    [[ "$output" == *"restarted without adaptive_autovacuum"* ]]
    run --separate-stderr bash "$SETUP" doctor --format json ${AAV_TEST_ARGS:-}
    [ "$status" -eq 10 ]
    [ "$(jq -r '.databases[0].checks[] | select(.check_name == "library_preloaded") | .status' <<<"$output")" = "FAIL" ]
    # Put it back for the following tests.
    run bash "$SETUP" install --database postgres --yes ${AAV_TEST_ARGS:-}
    [ "$status" -eq 0 ]
}
