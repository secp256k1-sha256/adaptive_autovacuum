\echo Use "ALTER EXTENSION adaptive_autovacuum UPDATE TO '1.4.0'" to load this file. \quit

/* 1.3.2 -> 1.4.0: emergency takeover terminates the stalled anti-wraparound autovacuum worker (pg_terminate_backend)
   instead of cancelling its current operation, and records a refused or failed signal on the decision; stale
   emergency-request recovery no longer fails a request whose worker is still running. No schema
   change; policy rows and persistent state are untouched. assemble.sh appends parts 02-04 with CREATE OR REPLACE, so
   every function and view below is rebuilt. */

