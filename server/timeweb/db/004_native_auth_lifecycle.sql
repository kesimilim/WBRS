-- PROPOSED FOR TIMEWEB / NOT APPLIED LIVE. Exactly two CREATE-only tables.
-- Checked only on a separate Unix-socket MySQL8.4 with generated fixtures.
-- Requires separately reviewed MySQL8.4 migration/backup/schema-version gate.
-- Original auth_credentials and legacy_* remain unchanged. DDL auto-commits.
-- Never run this through the runtime SELECT/INSERT/UPDATE service role.

CREATE TABLE clrs_staging.native_password_credentials (
  uid VARCHAR(191) NOT NULL CHECK (uid <> ''),
  scheme VARCHAR(30) NOT NULL CHECK (scheme = 'clrs_scrypt_v1'),
  password_version BIGINT NOT NULL CHECK (password_version >= 0),
  material_ciphertext VARBINARY(80) NOT NULL CHECK (OCTET_LENGTH(material_ciphertext) = 80),
  parameters JSON NOT NULL CHECK (JSON_TYPE(parameters) = 'OBJECT'),
  created_at DATETIME(6) NOT NULL DEFAULT CURRENT_TIMESTAMP(6),
  updated_at DATETIME(6) NOT NULL DEFAULT CURRENT_TIMESTAMP(6),
  PRIMARY KEY (uid),
  CONSTRAINT native_password_account_fk FOREIGN KEY (uid) REFERENCES clrs_staging.accounts(uid),
  CHECK (COALESCE(JSON_LENGTH(parameters) = 7
    AND JSON_TYPE(JSON_EXTRACT(parameters, '$.material_format')) = 'STRING'
    AND JSON_UNQUOTE(JSON_EXTRACT(parameters, '$.material_format')) = 'aes256gcm-native-v1'
    AND JSON_TYPE(JSON_EXTRACT(parameters, '$.n')) = 'INTEGER' AND JSON_EXTRACT(parameters, '$.n') = 32768
    AND JSON_TYPE(JSON_EXTRACT(parameters, '$.r')) = 'INTEGER' AND JSON_EXTRACT(parameters, '$.r') = 8
    AND JSON_TYPE(JSON_EXTRACT(parameters, '$.p')) = 'INTEGER' AND JSON_EXTRACT(parameters, '$.p') = 3
    AND JSON_TYPE(JSON_EXTRACT(parameters, '$.dklen')) = 'INTEGER' AND JSON_EXTRACT(parameters, '$.dklen') = 32
    AND JSON_TYPE(JSON_EXTRACT(parameters, '$.maxmem')) = 'INTEGER' AND JSON_EXTRACT(parameters, '$.maxmem') = 67108864
    AND JSON_TYPE(JSON_EXTRACT(parameters, '$.salt_bytes')) = 'INTEGER' AND JSON_EXTRACT(parameters, '$.salt_bytes') = 16, FALSE) = TRUE)
) ENGINE=InnoDB ROW_FORMAT=DYNAMIC DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_0900_bin;

-- ONE persistent row per (uid,purpose), not one throttle row per challengeID.
-- Replace current challenge fields, preserve issue_history and pending marker.
-- Consume leaves a tombstone. No DELETE/reset-on-resend/reused old challenge.
CREATE TABLE clrs_staging.native_auth_challenges (
  uid VARCHAR(191) NOT NULL,
  purpose VARCHAR(30) NOT NULL CHECK (purpose IN ('register-email.v1', 'password-reset.v1')),
  challenge_id CHAR(36) NOT NULL CHECK (challenge_id REGEXP '^[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$'),
  email_identity_hmac VARBINARY(32) NOT NULL CHECK (OCTET_LENGTH(email_identity_hmac) = 32),
  code_hmac VARBINARY(32) NOT NULL CHECK (OCTET_LENGTH(code_hmac) = 32),
  account_token_version BIGINT NOT NULL CHECK (account_token_version >= 0),
  issue_history JSON NOT NULL CHECK (JSON_TYPE(issue_history) = 'ARRAY' AND JSON_LENGTH(issue_history) BETWEEN 1 AND 5),
  issued_at DATETIME(6) NOT NULL,
  expires_at DATETIME(6) NOT NULL,
  attempts TINYINT NOT NULL DEFAULT 0 CHECK (attempts BETWEEN 0 AND 5),
  consumed_at DATETIME(6) NULL,
  -- Signup pending authority exists only if this marker was inserted IN THE
  -- SAME transaction as a brand-new accounts row. It is never inferred from
  -- disabled=1 alone and is preserved on signup resend.
  pending_signup_marker VARBINARY(32) NULL,
  pending_account_created_at DATETIME(6) NULL,
  created_at DATETIME(6) NOT NULL DEFAULT CURRENT_TIMESTAMP(6),
  updated_at DATETIME(6) NOT NULL DEFAULT CURRENT_TIMESTAMP(6),
  PRIMARY KEY (uid, purpose),
  UNIQUE KEY native_auth_challenge_id_uq (challenge_id),
  KEY native_auth_challenge_expiry_idx (expires_at, uid),
  CONSTRAINT native_auth_challenge_account_fk FOREIGN KEY (uid) REFERENCES clrs_staging.accounts(uid),
  CHECK (expires_at = issued_at + INTERVAL 10 MINUTE),
  CHECK (consumed_at IS NULL OR consumed_at >= issued_at),
  CHECK ((purpose = 'register-email.v1' AND pending_signup_marker IS NOT NULL
          AND OCTET_LENGTH(pending_signup_marker) = 32 AND pending_account_created_at IS NOT NULL)
      OR (purpose = 'password-reset.v1' AND pending_signup_marker IS NULL AND pending_account_created_at IS NULL))
) ENGINE=InnoDB ROW_FORMAT=DYNAMIC DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_0900_bin;
