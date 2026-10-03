-- Retain imported likes. Native unlike is a tombstone, never a DELETE.
CREATE TABLE IF NOT EXISTS clrs_staging.social_reaction_state (
  post_id VARCHAR(191) NOT NULL,
  comment_id VARCHAR(191) NOT NULL DEFAULT '',
  uid VARCHAR(191) NOT NULL,
  active TINYINT(1) NOT NULL CHECK (active IN (0, 1)),
  updated_at DATETIME(6) NOT NULL DEFAULT CURRENT_TIMESTAMP(6),
  PRIMARY KEY (post_id, comment_id, uid),
  CONSTRAINT social_reaction_post_fk FOREIGN KEY (post_id) REFERENCES clrs_staging.posts(post_id),
  CONSTRAINT social_reaction_actor_fk FOREIGN KEY (uid) REFERENCES clrs_staging.accounts(uid)
) ENGINE=InnoDB ROW_FORMAT=DYNAMIC DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_0900_bin;
