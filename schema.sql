CREATE TABLE IF NOT EXISTS spgq_jobs
(
  id               bigserial   NOT NULL PRIMARY KEY,
  queue            varchar     NOT NULL,
  args             jsonb       NOT NULL,
  status           varchar     NOT NULL,
  last_reserved_by varchar,
  last_error       text,
  releases         integer     NOT NULL,
  created_at       timestamptz NOT NULL,
  updated_at       timestamptz NOT NULL,
  reserve_after    timestamptz
);

CREATE INDEX IF NOT EXISTS spgq_jobs_idx ON spgq_jobs (queue, updated_at) WHERE status = 'ready';

COMMENT ON TABLE spgq_jobs IS 'spgq jobs';

COMMENT ON COLUMN spgq_jobs.id               IS 'unique job identifier';
COMMENT ON COLUMN spgq_jobs.queue            IS 'job queue';
COMMENT ON COLUMN spgq_jobs.args             IS 'job arguments';
COMMENT ON COLUMN spgq_jobs.status           IS 'job status: ready, reserved, done, failed';
COMMENT ON COLUMN spgq_jobs.last_reserved_by IS 'identifier of the last client who reserved a job, may be NULL';
COMMENT ON COLUMN spgq_jobs.last_error       IS 'last job release error, may be NULL';
COMMENT ON COLUMN spgq_jobs.releases         IS 'how many times job was released';
COMMENT ON COLUMN spgq_jobs.created_at       IS 'job creation time';
COMMENT ON COLUMN spgq_jobs.updated_at       IS 'last job update time';
COMMENT ON COLUMN spgq_jobs.reserve_after    IS 'earliest job reservation time, NULL means anytime';


CREATE OR REPLACE FUNCTION spgq_put_job(p_queue varchar, p_args jsonb, p_reserve_after timestamptz) RETURNS spgq_jobs AS
$$
  INSERT INTO spgq_jobs
    (queue, args, status, releases, created_at, updated_at, reserve_after)
    VALUES (p_queue, p_args, 'ready', 0, NOW(), NOW(), p_reserve_after)
    RETURNING *;
$$ LANGUAGE sql;

COMMENT ON FUNCTION spgq_put_job(varchar, jsonb, timestamptz) IS
  'Puts new job to given queue with ready status, with given arguments and earliest reservation time.';


CREATE OR REPLACE FUNCTION spgq_reserve_job(p_queue varchar, p_client varchar) RETURNS SETOF spgq_jobs AS
$$
  UPDATE spgq_jobs
    SET status = 'reserved', last_reserved_by = p_client, updated_at = NOW()
    WHERE id IN (
      SELECT id FROM spgq_jobs
        WHERE queue = p_queue AND status = 'ready' AND (reserve_after IS NULL OR reserve_after < NOW())
        ORDER BY updated_at ASC
        LIMIT 1
        FOR UPDATE SKIP LOCKED
    )
    RETURNING *;
$$ LANGUAGE sql;

COMMENT ON FUNCTION spgq_reserve_job(varchar, varchar) IS
  'Reserves a ready job from given queue for given client. May return 0 or 1 row.';


CREATE OR REPLACE FUNCTION spgq_release_job(p_job_id bigint, p_error text, p_reserve_after timestamptz) RETURNS SETOF spgq_jobs AS
$$
  UPDATE spgq_jobs
    SET status = 'ready',
        releases = releases + 1,
        last_error = p_error,
        reserve_after = p_reserve_after,
        updated_at = NOW()
    WHERE id = p_job_id AND status = 'reserved'
    RETURNING *;
$$ LANGUAGE sql;

COMMENT ON FUNCTION spgq_release_job(bigint, text, timestamptz) IS
  'Releases a given reserved job with given error message and earliest reservation time back to ready status.';


CREATE OR REPLACE FUNCTION spgq_done_job(p_job_id bigint) RETURNS SETOF spgq_jobs AS
$$
  UPDATE spgq_jobs
    SET status = 'done',
        updated_at = NOW()
    WHERE id = p_job_id AND status = 'reserved'
    RETURNING *;
$$ LANGUAGE sql;

COMMENT ON FUNCTION spgq_done_job(bigint) IS
  'Marks given reserved job as done.';


CREATE OR REPLACE FUNCTION spgq_fail_job(p_job_id bigint, p_error text) RETURNS SETOF spgq_jobs AS
$$
  UPDATE spgq_jobs
    SET status = 'failed',
        last_error = p_error,
        updated_at = NOW()
    WHERE id = p_job_id AND status = 'reserved'
    RETURNING *;
$$ LANGUAGE sql;

COMMENT ON FUNCTION spgq_fail_job(bigint, text) IS
  'Marks given reserved job as failed with given error message.';
