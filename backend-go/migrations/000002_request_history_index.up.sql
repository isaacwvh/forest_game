-- Match the worker's backfill queue. Expiry scans use the baseline expiry index.
CREATE INDEX ix_api_requests_missing_completion
ON public.api_requests(user_id, created_at, request_id)
WHERE response IS NOT NULL AND (
    completion IS NULL
    OR (operation='pack_open' AND NOT (completion ? 'version'))
);
