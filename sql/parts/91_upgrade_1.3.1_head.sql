\echo Use "ALTER EXTENSION adaptive_autovacuum UPDATE TO '1.3.2'" to load this file. \quit

/* 1.3.1 -> 1.3.2: PostgreSQL 19 support. No schema change: the vacuum initiator and mode from pg_stat_progress_vacuum
   (PG19 started_by/mode, NULL before) feed the wraparound/initiator flags, the stall fingerprint and the takeover guard
   (a failsafe-mode vacuum is never replaced); active_vacuums gains started_by and mode.
   assemble.sh appends parts 02-04 with CREATE OR REPLACE, so every function and view below is rebuilt. */

