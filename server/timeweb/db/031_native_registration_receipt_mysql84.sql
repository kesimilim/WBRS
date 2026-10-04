-- PROPOSAL ONLY / NOT APPLIED LIVE. Review original SHOW CREATE TABLE first.
-- The two names below are MySQL 8.4 names assigned by original migration 005.
-- Abort if that reviewed source does not match; do not alter an unknown schema.
-- No new table, column, data write or runtime GRANT. Apply as schema operator.
-- Atomic ALTER preserves the existing request/refusal proof shape and adds only
-- the password-only signup operation. Runtime still requires the FINAL Auth
-- source-authority/write-barrier gate; this DDL does not assert that readiness.

ALTER TABLE clrs_staging.native_auth_receipts
  DROP CHECK native_auth_receipts_chk_2,
  DROP CHECK native_auth_receipts_chk_7,
  ADD CONSTRAINT native_auth_receipts_operation_v2 CHECK (operation IN (
    'password-reset.request.v1', 'password-reset.complete.v1',
    'register-email.request.v1', 'register-email.complete.v1', 'register.complete.v1')),
  ADD CONSTRAINT native_auth_receipts_outcome_v2 CHECK ((state = 'started' AND response_status IS NULL AND response IS NULL AND completed_at IS NULL)
    OR (state = 'completed' AND completed_at IS NOT NULL AND completed_at >= created_at
      AND COALESCE(JSON_TYPE(response) = 'OBJECT' AND (
        (operation IN ('password-reset.request.v1', 'register-email.request.v1')
          AND response_status = 202 AND JSON_LENGTH(response) = 2
          AND JSON_TYPE(JSON_EXTRACT(response, '$.status')) = 'STRING'
          AND JSON_UNQUOTE(JSON_EXTRACT(response, '$.status')) = 'accepted'
          AND JSON_TYPE(JSON_EXTRACT(response, '$.challengeId')) = 'STRING'
          AND JSON_UNQUOTE(JSON_EXTRACT(response, '$.challengeId')) REGEXP '^[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$')
        OR (operation IN ('password-reset.complete.v1', 'register-email.complete.v1', 'register.complete.v1')
          AND JSON_LENGTH(response) = 1
          AND JSON_TYPE(JSON_EXTRACT(response, '$.status')) = 'STRING'
          AND ((response_status = 200 AND JSON_UNQUOTE(JSON_EXTRACT(response, '$.status')) = 'completed')
            OR (response_status = 400 AND JSON_UNQUOTE(JSON_EXTRACT(response, '$.status')) = 'refused')))
      ), FALSE) = TRUE));
