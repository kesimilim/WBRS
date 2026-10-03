-- Reviewed source only. Apply separately after exact schema/permission review.
-- Native imported-member exits must not overwrite historical legacy_raw.
CREATE TABLE clrs_staging.meeting_archive_windows (
  meeting_id VARCHAR(191) NOT NULL,
  uid VARCHAR(191) NOT NULL,
  operation_id CHAR(36) CHARACTER SET ascii COLLATE ascii_bin NOT NULL,
  membership_revision BIGINT NOT NULL CHECK (membership_revision > 0),
  through_sequence BIGINT NOT NULL CHECK (through_sequence >= 0),
  captured_at DATETIME(6) NOT NULL,
  cohort_sha256 CHAR(64) CHARACTER SET ascii COLLATE ascii_bin NOT NULL,
  PRIMARY KEY (meeting_id, uid),
  UNIQUE KEY meeting_archive_windows_operation_uq (uid, operation_id),
  CONSTRAINT meeting_archive_windows_meeting_fk FOREIGN KEY (meeting_id)
    REFERENCES clrs_staging.meetings(meeting_id),
  CONSTRAINT meeting_archive_windows_owner_fk FOREIGN KEY (uid)
    REFERENCES clrs_staging.accounts(uid),
  CHECK (REGEXP_LIKE(operation_id, '^[0-9a-f]{8}-[0-9a-f]{4}-[1-8][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$', 'c')),
  CHECK (REGEXP_LIKE(cohort_sha256, '^[0-9a-f]{64}$', 'c'))
) ENGINE=InnoDB ROW_FORMAT=DYNAMIC DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_0900_bin;
