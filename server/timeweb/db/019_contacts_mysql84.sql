-- Additive migration: retained Firebase documents and existing tables stay intact.
CREATE TABLE IF NOT EXISTS clrs_staging.contact_relationships (
  uid_low VARCHAR(191) NOT NULL,
  uid_high VARCHAR(191) NOT NULL,
  state VARCHAR(16) NOT NULL,
  requester_uid VARCHAR(191) NULL,
  revision BIGINT NOT NULL,
  updated_at DATETIME(6) NOT NULL,
  PRIMARY KEY (uid_low, uid_high),
  KEY contacts_high_idx (uid_high, state, uid_low),
  KEY contacts_low_idx (uid_low, state, uid_high),
  FOREIGN KEY (uid_low) REFERENCES clrs_staging.accounts(uid),
  FOREIGN KEY (uid_high) REFERENCES clrs_staging.accounts(uid),
  CHECK (uid_low < uid_high),
  CHECK (state IN ('none', 'pending', 'friends')),
  CHECK (revision > 0),
  CHECK ((state = 'pending' AND requester_uid IS NOT NULL AND requester_uid IN (uid_low, uid_high))
         OR (state <> 'pending' AND requester_uid IS NULL))
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_0900_bin;

CREATE TABLE IF NOT EXISTS clrs_staging.profile_visits (
  owner_uid VARCHAR(191) NOT NULL,
  visitor_uid VARCHAR(191) NOT NULL,
  last_visit_at DATETIME(6) NULL,
  PRIMARY KEY (owner_uid, visitor_uid),
  KEY profile_visits_recent_idx (owner_uid, last_visit_at DESC, visitor_uid),
  FOREIGN KEY (owner_uid) REFERENCES clrs_staging.accounts(uid),
  FOREIGN KEY (visitor_uid) REFERENCES clrs_staging.accounts(uid),
  CHECK (owner_uid <> visitor_uid)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_0900_bin;
