\set t random(1,100)
\set id random(1,100000)

UPDATE worker_test_:t
SET counter = counter + 1,
    payload = md5(random()::text) || md5(random()::text) ||
              md5(random()::text) || md5(random()::text)
WHERE id = :id;
