"""Local safety checks with fake clients and fake age; no network or database."""

import os
from pathlib import Path
import subprocess
import tempfile
import unittest


HERE = Path(__file__).resolve().parent


def write(path: Path, content: str, mode: int = 0o600) -> None:
    path.write_text(content)
    path.chmod(mode)


class MySQLBackupRestoreTest(unittest.TestCase):
    def setUp(self) -> None:
        self.temp = tempfile.TemporaryDirectory(prefix="clrs-mysql-deploy-test-")
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        self.bin = self.root / "bin"
        self.bin.mkdir()
        self.backups = self.root / "backups"
        self.backups.mkdir(mode=0o700)
        self.ca = self.root / "ca.pem"
        self.recipient = self.root / "recipient.txt"
        self.identity = self.root / "identity.txt"
        write(self.ca, "synthetic CA")
        write(self.recipient, "synthetic recipient")
        write(self.identity, "synthetic identity")
        self.backup_env = self.root / "mysql-backup.env"
        self.restore_env = self.root / "mysql-restore.env"
        common = (
            "MYSQL_HOST=db.example.test\n"
            "MYSQL_PORT=3306\n"
            "MYSQL_USER=synthetic_user\n"
            "MYSQL_PASSWORD='synthetic-only'\n"
            "MYSQL_DATABASE=clrs_staging\n"
            f"MYSQL_CA_FILE={self.ca}\n"
        )
        write(self.backup_env, common +
              f"BACKUP_AGE_RECIPIENT_FILE={self.recipient}\nBACKUP_DIR={self.backups}\n")
        write(self.restore_env, common + f"RESTORE_AGE_IDENTITY_FILE={self.identity}\n")
        write(self.bin / "age", """#!/usr/bin/env bash
set -euo pipefail
if [[ ${1:-} == -d ]]; then cat "${@: -1}"; else cat; fi
""", 0o755)
        write(self.bin / "mysqldump", """#!/usr/bin/env bash
set -euo pipefail
[[ $1 == --defaults-file=/dev/fd/3 ]]
[[ -z ${MYSQL_PASSWORD+x} && -z ${MYSQL_PWD+x} ]]
[[ $(cat /dev/fd/3) == *'password="synthetic-only"'* ]]
[[ " $* " == *' clrs_staging '* ]]
[[ " $* " == *'--ssl-mode=VERIFY_IDENTITY'* ]]
[[ " $* " == *'--no-login-paths'* ]]
[[ " $* " == *'--set-gtid-purged=OFF'* ]]
[[ " $* " == *'--skip-add-drop-table'* ]]
[[ " $* " != *' --disable-keys '* ]]
if [[ " $* " == *'--connect-timeout'* ]]; then
  printf '%s\n' "mysqldump: [ERROR] unknown variable 'connect-timeout=5'." >&2
  exit 7
fi
printf '%s\\n' '-- MySQL dump 10.13' 'CREATE TABLE `sample` (`id` int PRIMARY KEY);'
# Model mysqldump's default --opt: a limited restore user must not receive
# DISABLE/ENABLE KEYS ALTER statements. No real database is contacted.
if [[ " $* " != *' --skip-disable-keys '* ]]; then
  printf '%s\\n' '/*!40000 ALTER TABLE `sample` DISABLE KEYS */;'
fi
printf '%s\\n' 'INSERT INTO `sample` VALUES (1);'
if [[ " $* " != *' --skip-disable-keys '* ]]; then
  printf '%s\\n' '/*!40000 ALTER TABLE `sample` ENABLE KEYS */;'
fi
""", 0o755)
        write(self.bin / "mysql", """#!/usr/bin/env bash
set -euo pipefail
[[ $1 == --defaults-file=/dev/fd/3 ]]
[[ -z ${MYSQL_PASSWORD+x} && -z ${MYSQL_PWD+x} ]]
[[ $(cat /dev/fd/3) == *'password="synthetic-only"'* ]]
[[ " $* " == *'--database=clrs_staging'* ]]
[[ " $* " == *'--ssl-mode=VERIFY_IDENTITY'* ]]
[[ " $* " == *'--no-login-paths'* ]]
if [[ " $* " == *'--execute=SELECT COUNT(*)'* ]]; then
  printf '%s\\n' "${FAKE_COUNT:-0}"
else
  cat > "$FAKE_RESTORE_OUTPUT"
  # Same compatibility boundary as the five-grant staging role: no ALTER.
  while IFS= read -r line; do
    [[ $line != *'ALTER TABLE'* ]] || exit 19
  done < "$FAKE_RESTORE_OUTPUT"
fi
""", 0o755)
        self.env = os.environ.copy()
        self.env.update({
            "PATH": str(self.bin) + os.pathsep + os.environ["PATH"],
            "CLRS_MYSQL_BACKUP_ENV_FILE": str(self.backup_env),
            "CLRS_MYSQL_RESTORE_ENV_FILE": str(self.restore_env),
            "FAKE_RESTORE_OUTPUT": str(self.root / "restored.sql"),
        })

    def run_script(self, name: str, *args: str, env=None) -> subprocess.CompletedProcess:
        return subprocess.run(
            ["bash", str(HERE / name), *args],
            env=env or self.env,
            capture_output=True,
            text=True,
            timeout=10,
            check=False,
        )

    def make_archive(self) -> Path:
        result = self.run_script("backup-mysql84.sh", "--execute")
        self.assertEqual(result.returncode, 0, result.stderr)
        archives = list(self.backups.glob("*.sql.age"))
        self.assertEqual(len(archives), 1)
        self.assertTrue(Path(str(archives[0]) + ".sha256").exists())
        return archives[0]

    def test_backup_dry_run_and_target_guard(self) -> None:
        result = self.run_script("backup-mysql84.sh")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(list(self.backups.iterdir()), [])
        write(self.backup_env, self.backup_env.read_text().replace(
            "MYSQL_DATABASE=clrs_staging", "MYSQL_DATABASE=default_db"))
        result = self.run_script("backup-mysql84.sh", "--execute")
        self.assertNotEqual(result.returncode, 0)
        self.assertEqual(list(self.backups.iterdir()), [])

    def test_mysql_client_connect_timeout_breaks_mysqldump_and_does_not_publish(self) -> None:
        # The real MySQL 8.4.4 mysqldump rejects this mysql-client-only option.
        invalid_script = self.root / "backup-with-invalid-connect-timeout.sh"
        write(invalid_script, (HERE / "backup-mysql84.sh").read_text().replace(
            "--default-character-set=utf8mb4)",
            "--default-character-set=utf8mb4 --connect-timeout=5)"))
        result = subprocess.run(["bash", str(invalid_script), "--execute"],
                                env=self.env, capture_output=True, text=True,
                                timeout=10, check=False)
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("unknown variable 'connect-timeout=5'", result.stderr)
        self.assertEqual(list(self.backups.iterdir()), [])
        self.make_archive()  # The corrected script succeeds with the same client.

    def test_archive_validation_and_confirmed_restore(self) -> None:
        archive = self.make_archive()
        args = ("--archive", str(archive), "--target-db", "clrs_staging")
        invalid = self.run_script("restore-mysql84.sh", "--archive", str(archive),
                                  "--target-db", "default_db", "--execute",
                                  "--confirm-target", "default_db")
        self.assertNotEqual(invalid.returncode, 0)
        missing_confirm = self.run_script("restore-mysql84.sh", *args, "--execute")
        self.assertNotEqual(missing_confirm.returncode, 0)
        self.assertFalse((self.root / "restored.sql").exists())

        dry_run = self.run_script("restore-mysql84.sh", *args)
        self.assertEqual(dry_run.returncode, 0, dry_run.stderr)
        nonempty_env = dict(self.env, FAKE_COUNT="1")
        nonempty = self.run_script("restore-mysql84.sh", *args, "--execute",
                                   "--confirm-target", "clrs_staging", env=nonempty_env)
        self.assertNotEqual(nonempty.returncode, 0)
        self.assertFalse((self.root / "restored.sql").exists())

        confirmed = self.run_script("restore-mysql84.sh", *args, "--execute",
                                    "--confirm-target", "clrs_staging")
        self.assertEqual(confirmed.returncode, 0, confirmed.stderr)
        restored = (self.root / "restored.sql").read_text()
        self.assertTrue(restored.startswith("-- CLRS_MYSQL84_STAGING_BACKUP_V1 clrs_staging\n"))
        self.assertIn("CREATE TABLE `sample`", restored)
        self.assertIn("INSERT INTO `sample` VALUES (1);", restored)
        self.assertNotIn("ALTER TABLE", restored)
        self.assertNotIn("synthetic-only", confirmed.stdout + confirmed.stderr)

    def test_rejects_corrupted_and_wrong_archive(self) -> None:
        archive = self.make_archive()
        args = ("--archive", str(archive), "--target-db", "clrs_staging")
        archive.write_text("corrupted")
        corrupted = self.run_script("restore-mysql84.sh", *args)
        self.assertNotEqual(corrupted.returncode, 0)
        self.assertIn("checksum mismatch", corrupted.stderr)
        self.assertFalse((self.root / "restored.sql").exists())

        archive.write_text("-- wrong database\n" + "SELECT 1;\n" * 20)
        digest = subprocess.check_output(
            ["openssl", "dgst", "-sha256", "-r", str(archive)], text=True).split()[0]
        Path(str(archive) + ".sha256").write_text(digest + "\n")
        wrong = self.run_script("restore-mysql84.sh", *args)
        self.assertNotEqual(wrong.returncode, 0)
        self.assertIn("not a complete clrs_staging dump", wrong.stderr)
        self.assertFalse((self.root / "restored.sql").exists())

    def test_original_default_index_alter_cannot_restore_with_limited_grants(self) -> None:
        # Regression proof of the original trigger: without --skip-disable-keys,
        # the modeled dump contains ALTER and the five-grant restore rejects it.
        original_behavior = self.root / "backup-with-default-index-alter.sh"
        write(original_behavior, (HERE / "backup-mysql84.sh").read_text().replace(
            " --skip-disable-keys", ""))
        backup = subprocess.run(["bash", str(original_behavior), "--execute"],
                                env=self.env, capture_output=True, text=True,
                                timeout=10, check=False)
        self.assertEqual(backup.returncode, 0, backup.stderr)
        archive = next(self.backups.glob("*.sql.age"))
        self.assertIn("ALTER TABLE", archive.read_text())  # synthetic age only
        restore = self.run_script("restore-mysql84.sh", "--archive", str(archive),
                                  "--target-db", "clrs_staging", "--execute",
                                  "--confirm-target", "clrs_staging")
        self.assertNotEqual(restore.returncode, 0)
        self.assertIn("restore failed", restore.stderr)


if __name__ == "__main__":
    unittest.main()
