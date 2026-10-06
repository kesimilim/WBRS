#!/usr/bin/env bash
# Stream only clrs_staging through age; never write plaintext SQL to disk.
set -Eeuo pipefail
set +x
umask 077

die() { printf 'MySQL backup stopped: %s\n' "$1" >&2; exit 1; }
require() { command -v "$1" >/dev/null 2>&1 || die "missing program: $1"; }
file_mode() { stat -c '%a' "$1" 2>/dev/null || stat -f '%Lp' "$1"; }
file_owner() { stat -c '%u' "$1" 2>/dev/null || stat -f '%u' "$1"; }
sha256() { openssl dgst -sha256 -r "$1" | cut -d ' ' -f 1; }

[[ $# -eq 0 || ( $# -eq 1 && $1 == --execute ) ]] || die 'usage: backup-mysql84.sh [--execute]'
execute=false
[[ $# -eq 1 ]] && execute=true

env_file=${CLRS_MYSQL_BACKUP_ENV_FILE:-/etc/clrs-staging/mysql-backup.env}
[[ -f $env_file && -r $env_file && ! -L $env_file ]] || die 'private mysql-backup.env is unavailable'
mode=$(file_mode "$env_file")
owner=$(file_owner "$env_file")
[[ $owner == 0 || $owner == "$EUID" ]] || die 'mysql-backup.env has an unexpected owner'
(( (8#$mode & 077) == 0 )) || die 'mysql-backup.env must have mode 0600'
# This is an administrator-owned shell env file outside the repository.
# shellcheck disable=SC1090
source "$env_file"
export -n MYSQL_PASSWORD 2>/dev/null || true
unset MYSQL_PWD
export MYSQL_TEST_LOGIN_FILE=/dev/null

for name in MYSQL_HOST MYSQL_PORT MYSQL_USER MYSQL_PASSWORD MYSQL_DATABASE \
  MYSQL_CA_FILE BACKUP_AGE_RECIPIENT_FILE BACKUP_DIR; do
  [[ -n ${!name:-} ]] || die "missing setting: $name"
done
[[ $MYSQL_DATABASE == clrs_staging ]] || die 'database must be clrs_staging'
[[ $MYSQL_HOST =~ ^[A-Za-z0-9][A-Za-z0-9.-]*[A-Za-z0-9]$ && ! $MYSQL_HOST =~ ^[0-9.]+$ ]] \
  || die 'database host must be a DNS name'
[[ $MYSQL_PORT =~ ^[0-9]{1,5}$ ]] || die 'invalid database port'
(( 10#$MYSQL_PORT >= 1 && 10#$MYSQL_PORT <= 65535 )) || die 'invalid database port'
[[ $MYSQL_PASSWORD != *$'\n'* && $MYSQL_PASSWORD != *$'\r'* ]] || die 'invalid password format'
[[ $MYSQL_CA_FILE == /* && -f $MYSQL_CA_FILE && -r $MYSQL_CA_FILE && ! -L $MYSQL_CA_FILE ]] \
  || die 'MySQL CA is unavailable'
[[ $BACKUP_AGE_RECIPIENT_FILE == /* && -f $BACKUP_AGE_RECIPIENT_FILE && -r $BACKUP_AGE_RECIPIENT_FILE && ! -L $BACKUP_AGE_RECIPIENT_FILE ]] \
  || die 'age recipient is unavailable'
[[ $BACKUP_DIR == /* && $BACKUP_DIR != / ]] || die 'backup directory must be absolute'

if [[ $execute == false ]]; then
  printf 'Dry run: MySQL clrs_staging backup settings valid. No database read or archive write was made.\n'
  exit 0
fi

for executable in mysqldump age openssl mktemp stat; do require "$executable"; done
[[ -d $BACKUP_DIR && -w $BACKUP_DIR && ! -L $BACKUP_DIR ]] || die 'private backup directory is unavailable'
mode=$(file_mode "$BACKUP_DIR")
owner=$(file_owner "$BACKUP_DIR")
[[ $owner == "$EUID" ]] || die 'backup directory must be owned by the backup user'
(( (8#$mode & 077) == 0 )) || die 'backup directory must have mode 0700'

# A pipe-backed option file keeps the password out of argv, process env and disk.
client_defaults() {
  local escaped=${MYSQL_PASSWORD//\\/\\\\}
  escaped=${escaped//\"/\\\"}
  printf '[client]\npassword="%s"\n' "$escaped"
}
# mysqldump does not accept mysql's --connect-timeout; the caller bounds the operation.
client_flags=(--no-login-paths --protocol=TCP --host="$MYSQL_HOST" --port="$MYSQL_PORT"
  --user="$MYSQL_USER" --ssl-mode=VERIFY_IDENTITY --ssl-ca="$MYSQL_CA_FILE"
  --default-character-set=utf8mb4)

partial=$(mktemp "$BACKUP_DIR/.clrs-staging-XXXXXXXX")
nonce=${partial##*-}
archive="$BACKUP_DIR/clrs_staging-$(date -u +%Y%m%dT%H%M%SZ)-$nonce.sql.age"
checksum="$archive.sha256"
[[ ! -e $archive && ! -e $checksum ]] || die 'backup name collision'
trap 'rm -f -- "$partial"' EXIT

{
  printf '%s\n' '-- CLRS_MYSQL84_STAGING_BACKUP_V1 clrs_staging'
  mysqldump --defaults-file=/dev/fd/3 "${client_flags[@]}" \
    --single-transaction --quick --skip-lock-tables --no-tablespaces \
    --set-gtid-purged=OFF --skip-add-drop-table --skip-add-locks --skip-disable-keys \
    --hex-blob "$MYSQL_DATABASE" 3< <(client_defaults)
} | age -R "$BACKUP_AGE_RECIPIENT_FILE" > "$partial" \
  || die 'dump or encryption failed'
[[ -s $partial ]] || die 'empty encrypted archive'
mv -- "$partial" "$archive"
digest=$(sha256 "$archive")
[[ $digest =~ ^[a-f0-9]{64}$ ]] || die 'archive checksum failed'
printf '%s\n' "$digest" > "$checksum"
printf 'Encrypted MySQL clrs_staging backup saved: %s\n' "$archive"
