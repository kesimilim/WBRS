-- PROPOSAL ONLY / NOT APPLIED LIVE. One additional CREATE-only table.
-- Sensitive auth receipts never store original request, email, UID, password,
-- code, session tokens or credential ciphertext. HMAC key is server-only.
-- Caller owns bounded SERIALIZABLE transaction, eligibility, effects and COMMIT.
-- No FK to accounts: generic pre-account/email-denial receipts must be possible.
-- Do not execute via runtime role; requires separate reviewed schema migration.

CREATE TABLE clrs_staging.native_auth_receipts (
  actor_identity_hmac VARBINARY(32) NOT NULL CHECK (OCTET_LENGTH(actor_identity_hmac) = 32),
  operation VARCHAR(40) NOT NULL CHECK (operation IN ('password-reset.request.v1',
    'password-reset.complete.v1', 'register-email.request.v1', 'register-email.complete.v1')),
  operation_id CHAR(36) NOT NULL CHECK (operation_id REGEXP '^[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$'),
  context_hmac VARBINARY(32) NOT NULL CHECK (OCTET_LENGTH(context_hmac) = 32),
  request_hmac VARBINARY(32) NOT NULL CHECK (OCTET_LENGTH(request_hmac) = 32),
  state VARCHAR(10) NOT NULL CHECK (state IN ('started', 'completed')),
  response_status SMALLINT NULL,
  response JSON NULL,
  created_at DATETIME(6) NOT NULL DEFAULT CURRENT_TIMESTAMP(6),
  completed_at DATETIME(6) NULL,
  PRIMARY KEY (actor_identity_hmac, operation, operation_id),
  CHECK ((state = 'started' AND response_status IS NULL AND response IS NULL AND completed_at IS NULL)
    OR (state = 'completed' AND completed_at IS NOT NULL AND completed_at >= created_at
      AND COALESCE(JSON_TYPE(response) = 'OBJECT' AND (
        (operation IN ('password-reset.request.v1', 'register-email.request.v1')
          AND response_status = 202 AND JSON_LENGTH(response) = 2
          AND JSON_TYPE(JSON_EXTRACT(response, '$.status')) = 'STRING'
          AND JSON_UNQUOTE(JSON_EXTRACT(response, '$.status')) = 'accepted'
          AND JSON_TYPE(JSON_EXTRACT(response, '$.challengeId')) = 'STRING'
          AND JSON_UNQUOTE(JSON_EXTRACT(response, '$.challengeId')) REGEXP '^[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$')
        OR (operation IN ('password-reset.complete.v1', 'register-email.complete.v1')
          AND JSON_LENGTH(response) = 1
          AND JSON_TYPE(JSON_EXTRACT(response, '$.status')) = 'STRING'
          AND ((response_status = 200 AND JSON_UNQUOTE(JSON_EXTRACT(response, '$.status')) = 'completed')
            OR (response_status = 400 AND JSON_UNQUOTE(JSON_EXTRACT(response, '$.status')) = 'refused')))
      ), FALSE) = TRUE))
) ENGINE=InnoDB ROW_FORMAT=DYNAMIC DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_0900_bin;
