-- Retain imported profile JSON while saving current owner preferences.
CREATE TABLE clrs_staging.account_preferences (
 uid VARCHAR(191) CHARACTER SET utf8mb4 COLLATE utf8mb4_0900_bin NOT NULL,
 messages TINYINT NOT NULL, meetings TINYINT NOT NULL, sound TINYINT NOT NULL,
 revision BIGINT NOT NULL, updated_at DATETIME(6) NOT NULL,
 PRIMARY KEY (uid),
 CONSTRAINT account_preferences_owner_fk FOREIGN KEY (uid) REFERENCES clrs_staging.accounts(uid),
 CHECK (messages IN (0,1) AND meetings IN (0,1) AND sound IN (0,1)),
 CHECK (revision > 0)
) ENGINE=InnoDB;
