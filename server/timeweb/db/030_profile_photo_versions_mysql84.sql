-- Exact sidecars in the existing paid database. Original raw, media and galleries stay intact.
CREATE TABLE clrs_staging.clrs_final_media_versions (
 generation_id BINARY(32) NOT NULL,
 source_path_sha256 BINARY(32) NOT NULL,
 source_path VARCHAR(1024) NOT NULL,
 encoded_payload JSON NOT NULL,
 payload_sha256 BINARY(32) NOT NULL,
 created_at DATETIME(6) NOT NULL DEFAULT CURRENT_TIMESTAMP(6),
 PRIMARY KEY (generation_id,source_path_sha256),
 CONSTRAINT clrs_final_media_generation_fk FOREIGN KEY (generation_id) REFERENCES clrs_staging.clrs_final_generations(generation_id),
 CHECK (JSON_TYPE(encoded_payload)='OBJECT' AND OCTET_LENGTH(CAST(encoded_payload AS CHAR CHARACTER SET utf8mb4)) <= 65536)
) ENGINE=InnoDB ROW_FORMAT=DYNAMIC DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_0900_bin;
CREATE TABLE clrs_staging.clrs_final_profile_photo_versions (
 generation_id BINARY(32) NOT NULL,
 uid VARCHAR(191) NOT NULL,
 encoded_payload JSON NOT NULL,
 payload_sha256 BINARY(32) NOT NULL,
 created_at DATETIME(6) NOT NULL DEFAULT CURRENT_TIMESTAMP(6),
 PRIMARY KEY (generation_id,uid),
 CONSTRAINT clrs_final_profile_photo_generation_fk FOREIGN KEY (generation_id) REFERENCES clrs_staging.clrs_final_generations(generation_id),
 CONSTRAINT clrs_final_profile_photo_account_fk FOREIGN KEY (uid) REFERENCES clrs_staging.accounts(uid),
 CHECK (JSON_TYPE(encoded_payload)='OBJECT' AND OCTET_LENGTH(CAST(encoded_payload AS CHAR CHARACTER SET utf8mb4)) <= 262144)
) ENGINE=InnoDB ROW_FORMAT=DYNAMIC DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_0900_bin;
