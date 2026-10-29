-- Additive post editing metadata; retained Firebase documents remain intact.
CREATE TABLE clrs_staging.social_post_content (
  post_id VARCHAR(191) NOT NULL,
  media_ids JSON NOT NULL,
  updated_at DATETIME(6) NOT NULL DEFAULT CURRENT_TIMESTAMP(6),
  PRIMARY KEY (post_id),
  CONSTRAINT social_post_content_post_fk FOREIGN KEY (post_id) REFERENCES clrs_staging.posts(post_id),
  CHECK (JSON_TYPE(media_ids) = 'ARRAY' AND JSON_LENGTH(media_ids) <= 10)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_0900_bin;
