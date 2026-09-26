#!/bin/bash
# Assemble the current SQL scripts from sql/parts (edit the parts, then run this). Released scripts (1.2.0) stay frozen.
# The upgrade script = hand-written head (schema changes, drops) + parts 02-04 with CREATE OR REPLACE.
set -e
cd "$(dirname "$0")"
cat parts/01_schema.sql parts/02_program.sql parts/03_control_plane.sql parts/04_views_api.sql > adaptive_autovacuum--1.3.0.sql
{
  cat parts/90_upgrade_1.2.0_head.sql
  sed -e 's/^CREATE FUNCTION/CREATE OR REPLACE FUNCTION/' -e 's/^CREATE VIEW/CREATE OR REPLACE VIEW/' \
      parts/02_program.sql parts/03_control_plane.sql parts/04_views_api.sql
} > adaptive_autovacuum--1.2.0--1.3.0.sql
echo "assembled: $(wc -l < adaptive_autovacuum--1.3.0.sql) lines install, $(wc -l < adaptive_autovacuum--1.2.0--1.3.0.sql) lines upgrade"
