#!/usr/bin/env bash
set -euo pipefail

source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

test_backup_upload_failure_exits_nonzero() {
  echof "Regression: backup.sh returns non-zero on rclone copy failure"

  local tmp_dir
  tmp_dir="$(mktemp -d)"
  mkdir -p "$tmp_dir/bin" "$tmp_dir/state" "$tmp_dir/backups"

  cat > "$tmp_dir/bin/pg_dumpall" <<'EOF'
#!/usr/bin/env bash
echo "SELECT 1;"
EOF
  make_executable "$tmp_dir/bin/pg_dumpall"

  cat > "$tmp_dir/bin/age" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
out=""
input=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    -o)
      out="$2"
      shift 2
      ;;
    -r)
      shift 2
      ;;
    *)
      input="$1"
      shift
      ;;
  esac
done
cp "$input" "$out"
EOF
  make_executable "$tmp_dir/bin/age"

  cat > "$tmp_dir/bin/rclone" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
case "${1:-}" in
  copy)
    exit 42
    ;;
  delete)
    echo "delete should not run after copy failure" >&2
    exit 99
    ;;
  *)
    exit 0
    ;;
esac
EOF
  make_executable "$tmp_dir/bin/rclone"

  local rclone_config_b64
  rclone_config_b64="$(printf '[local]\ntype = local\n' | base64 -w0)"

  local status=0
  set +e
  PATH="$tmp_dir/bin:$PATH" \
  BACKUP_DIR="$tmp_dir/backups" \
  BACKUP_STATE_DIR="$tmp_dir/state" \
  POSTGRES_USER=postgres \
  POSTGRES_PASSWORD=test_password \
  AGE_PUBLIC_KEY=test_public_key \
  REMOTE_PATH=local:/backups \
  RCLONE_CONFIG_BASE64="$rclone_config_b64" \
  bash "$REPO_DIR/backup.sh" >/dev/null 2>&1
  status=$?
  set -e

  if [[ "$status" -eq 0 ]]; then
    rm -rf "$tmp_dir"
    die "backup.sh exited 0 even though rclone copy failed"
  fi

  if [[ -f "$tmp_dir/state/last_backup.hash" ]]; then
    rm -rf "$tmp_dir"
    die "last_backup.hash should not be written when upload fails"
  fi

  rm -rf "$tmp_dir"
  pass "backup.sh correctly fails and does not update hash on upload failure"
}

test_entrypoint_wal_default_cron_is_unquoted() {
  echof "Regression: entrypoint-backup.sh writes valid default WAL cron lines"

  local tmp_dir
  tmp_dir="$(mktemp -d)"
  mkdir -p "$tmp_dir/bin"
  : > "$tmp_dir/crontab.txt"

  cat > "$tmp_dir/mock-walg-env.sh" <<'EOF'
#!/usr/bin/env bash
:
EOF
  make_executable "$tmp_dir/mock-walg-env.sh"

  cat > "$tmp_dir/bin/crontab" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
file="${TEST_CRONTAB_FILE:?}"
case "${1:-}" in
  -)
    cat > "$file"
    ;;
  -l)
    cat "$file"
    ;;
  *)
    echo "unsupported crontab args: $*" >&2
    exit 2
    ;;
esac
EOF
  make_executable "$tmp_dir/bin/crontab"

  cat > "$tmp_dir/bin/crond" <<'EOF'
#!/usr/bin/env bash
exit 0
EOF
  make_executable "$tmp_dir/bin/crond"

  PATH="$tmp_dir/bin:$PATH" \
  TEST_CRONTAB_FILE="$tmp_dir/crontab.txt" \
  BACKUP_MODE=wal \
  WALG_ENV_PREPARE_SCRIPT="$tmp_dir/mock-walg-env.sh" \
  bash "$REPO_DIR/entrypoint-backup.sh" crond >/dev/null 2>&1

  if ! grep -Fq "30 1 * * * /opt/walg/scripts/wal-g-runner.sh backup" "$tmp_dir/crontab.txt"; then
    rm -rf "$tmp_dir"
    die "default basebackup cron line was not written as expected"
  fi

  if ! grep -Fq "15 3 * * * /opt/walg/scripts/wal-g-runner.sh clean" "$tmp_dir/crontab.txt"; then
    rm -rf "$tmp_dir"
    die "default cleanup cron line was not written as expected"
  fi

  if grep -Fq "'30 1 * * *'" "$tmp_dir/crontab.txt" || grep -Fq "'15 3 * * *'" "$tmp_dir/crontab.txt"; then
    rm -rf "$tmp_dir"
    die "cron defaults are incorrectly single-quoted"
  fi

  rm -rf "$tmp_dir"
  pass "entrypoint-backup.sh writes unquoted default WAL cron expressions"
}

main() {
  test_backup_upload_failure_exits_nonzero
  test_entrypoint_wal_default_cron_is_unquoted
  echof "Regression tests completed"
}

main "$@"
