DO $$
BEGIN
  FOR i IN 1..100 LOOP
    EXECUTE format(
      'CREATE TABLE worker_test_%s (
         id bigint PRIMARY KEY,
         payload text,
         counter bigint DEFAULT 0
       )', i);

    EXECUTE format(
      'INSERT INTO worker_test_%s
       SELECT g, repeat(md5(g::text),4),0
       FROM generate_series(1,100000) g', i);

    -- trigger AV much sooner than usual so the test finishes quickly
    EXECUTE format(
      'ALTER TABLE worker_test_%s SET (
         autovacuum_vacuum_threshold=1000,
         autovacuum_vacuum_scale_factor=0
       )', i);

    EXECUTE format('ANALYZE worker_test_%s',i);
  END LOOP;
END
$$;
