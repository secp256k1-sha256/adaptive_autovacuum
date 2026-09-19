-- Remove adaptive_autovacuum from shared_preload_libraries, preserving the other entries
-- and their order. Requires superuser and a server restart afterwards.
-- This does NOT drop the extension objects; DROP EXTENSION is a separate, destructive step.
-- Run with:  psql -X -v ON_ERROR_STOP=1 -d postgres -f disable-preload.sql
DO $$
DECLARE
    cur text := current_setting('shared_preload_libraries');
    new_value text;
BEGIN
    SELECT coalesce(string_agg(btrim(entry), ',' ORDER BY ord), '')
    INTO new_value
    FROM unnest(string_to_array(coalesce(cur, ''), ',')) WITH ORDINALITY AS t(entry, ord)
    WHERE btrim(entry) <> ''
      AND regexp_replace(regexp_replace(btrim(btrim(entry), '"'''), '^\$libdir[/\\]', ''), '\.(so|dll|dylib)$', '')
          <> 'adaptive_autovacuum';
    IF new_value = btrim(coalesce(cur, '')) THEN
        RAISE NOTICE 'shared_preload_libraries does not list adaptive_autovacuum: %', cur;
        RETURN;
    END IF;
    EXECUTE format('ALTER SYSTEM SET shared_preload_libraries = %L', new_value);
    RAISE NOTICE 'shared_preload_libraries: % -> % (restart PostgreSQL to apply)', cur, new_value;
END
$$;
