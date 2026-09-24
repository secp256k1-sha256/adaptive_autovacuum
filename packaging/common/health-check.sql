-- adaptive_autovacuum health check; run it in the control database (postgres by default).
-- Run with:  psql -X -v ON_ERROR_STOP=1 -d postgres -f health-check.sql
-- Statuses: OK, WARN, FAIL, RESTART_REQUIRED. Remediation is a command to run.
SELECT check_name, status, detail, remediation
FROM adaptive_autovacuum.doctor();
