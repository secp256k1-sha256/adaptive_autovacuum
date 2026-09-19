EXTENSION = adaptive_autovacuum
MODULE_big = adaptive_autovacuum
OBJS = src/adaptive_autovacuum.o
DATA = sql/adaptive_autovacuum--1.0.0.sql sql/adaptive_autovacuum--1.1.0.sql sql/adaptive_autovacuum--1.0.0--1.1.0.sql
REGRESS = adaptive_autovacuum upgrade
REGRESS_OPTS = --inputdir=test
PGFILEDESC = "adaptive_autovacuum - adaptive autovacuum controller"

PG_CONFIG ?= pg_config
PGXS := $(shell $(PG_CONFIG) --pgxs)
include $(PGXS)
