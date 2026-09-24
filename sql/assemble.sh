#!/bin/bash
# Assemble the shipped SQL script from sql/parts (edit the parts, then run this).
set -e
cd "$(dirname "$0")"
cat parts/01_schema.sql parts/02_program.sql parts/03_control_plane.sql parts/04_views_api.sql > adaptive_autovacuum--1.2.0.sql
echo "assembled: $(wc -l < adaptive_autovacuum--1.2.0.sql) lines"
