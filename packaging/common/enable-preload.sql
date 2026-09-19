-- Append adaptive_autovacuum to shared_preload_libraries, keeping every existing entry.
-- Requires superuser. A server restart is needed afterwards (shared_preload_libraries
-- is a start-up parameter; pg_reload_conf() is not enough).
-- Run with:  psql -X -v ON_ERROR_STOP=1 -d postgres -f enable-preload.sql
DO $$
DECLARE
    cur text := current_setting('shared_preload_libraries');
    new_value text;
BEGIN
    IF EXISTS (
        SELECT 1
        FROM unnest(string_to_array(coalesce(cur, ''), ',')) AS entry
        WHERE regexp_replace(regexp_replace(btrim(btrim(entry), '"'''), '^\$libdir[/\\]', ''), '\.(so|dll|dylib)$', '')
              = 'adaptive_autovacuum')
    THEN
        RAISE NOTICE 'shared_preload_libraries already lists adaptive_autovacuum: %', cur;
        RETURN;
    END IF;
    new_value := CASE WHEN btrim(coalesce(cur, '')) = '' THEN 'adaptive_autovacuum'
                      ELSE btrim(cur) || ',adaptive_autovacuum' END;
    EXECUTE format('ALTER SYSTEM SET shared_preload_libraries = %L', new_value);
    RAISE NOTICE 'shared_preload_libraries: % -> % (restart PostgreSQL to apply)', cur, new_value;
END
$$;

SELECT name, setting, applied, error
FROM pg_file_settings
WHERE name = 'shared_preload_libraries';
