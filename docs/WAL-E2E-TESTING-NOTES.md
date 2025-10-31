# WAL-G E2E testing notes: restricted SSH and success criteria

Updated: 2025-10-31

This note captures the practical adjustments made to the end-to-end WAL-G test (`test/test-walg-e2e.sh`) to work reliably with a restricted SSH storage and to avoid false negatives when the remote is pre-populated with WAL files.

## Context
- PostgreSQL 17.6 with WAL archiving enabled
- WAL-G v3.0.7 using the SSH storage backend
- Remote: Hetzner Storage Box with a restricted shell (no `find`, `id`, etc.)
- Docker-based test harness; WAL-G env prepared at `/var/lib/postgresql/.walg_env`
- Archive command: `wal-g wal-push %p` with env sourced in a shell wrapper

## Why the old test failed ("No new WAL files found" and "Finish LSN greater than current LSN")
1) WAL Progress Detection:
- The remote already contained many WAL segments. During the short test window, a naive "remote count delta must increase" heuristic may not visibly change even when archiving is working.

2) LSN Conflicts with Stale Backups:
- When FORCE_EMPTY_PGDATA=1 cleared local data but left remote backups, the new database instance restarted with lower LSN values.
- WAL-G tried to create a delta backup from the previous backup (e.g., finish LSN 0/7000120), but the new instance's LSN had reset (e.g., 0/5000028).
- Error: "Finish LSN of backup ... greater than current LSN"

3) Restricted SSH Environment:
- The restricted SSH environment disallows tools like `find` and `id`, so earlier remote enumeration pipelines were unreliable or broken.
- `set -u` (nounset) plus fragile loops caused unbound variables and zero counts in some paths.

## What changed in the test
File: `test/test-walg-e2e.sh`

1) Remote backup cleanup when FORCE_EMPTY_PGDATA=1
- When the test forcibly empties the postgres-data volume, it now also cleans remote backups.
- This prevents "Finish LSN of backup ... greater than current LSN" errors that occur when:
  - Old backups exist on remote with higher LSN values
  - New database instance starts with fresh/lower LSNs
  - WAL-G attempts delta backup from outdated parent
- Uses SFTP batch commands (compatible with Hetzner Storage Box restricted shell).

2) Restricted-SSH compatible remote enumeration
- Only uses portable commands supported by the Storage Box: `ls`, `grep`, `wc`, `head`, `tail`.
- Enumerates `wal_*` subdirectories under the path derived from `WALG_SSH_PREFIX` and sums counts with `ls -1 | wc -l`.
- Sanitizes directory names (strip CRs, trailing slashes) to avoid loop/pipeline glitches.

3) Robust success criteria for WAL progress
The test now passes if any of the following are observed:
- The count of "pure" WAL files on the remote increases, OR
- `pg_stat_archiver.archived_count` increases, OR
- `pg_stat_archiver.last_archived_wal` is found on the remote.

This avoids false failures in environments with pre-populated storage or when absolute file counts are stable while archiver state advances.

4) Stability improvements
- Increased attempts and sleeps between WAL generation/checks.
- Forces multiple `pg_switch_wal()` calls to trigger archival.
- Simplified debug listings to avoid `set -u` unbound variable errors.

## Environment variables and paths of interest
- `WALG_SSH_PREFIX` (example): `ssh://<user>@<host>/home/pg_with_backup_testing`
- SSH key inside the Postgres container: `/var/lib/postgresql/.ssh/walg_key`
- WAL-G env file: `/var/lib/postgresql/.walg_env`
- Archive command template (inside `postgresql.conf`): `bash -c "source /var/lib/postgresql/.walg_env 2>/dev/null || true; wal-g wal-push %p"`

## Manual verification snippets (restricted SSH)
Count WAL files across `wal_*` directories (example intent):

```bash
# List wal_* on remote (Storage Box supports ls/grep/wc; avoid find)
ssh -p "$SSH_PORT" -i /var/lib/postgresql/.ssh/walg_key "$SSH_USER@$SSH_HOST" \
  "ls -1 \"$REMOTE_BASE\" | grep -E '^wal_[0-9]+' || true"

# Count files per wal_* dir and sum (portable ls+wc approach)
ssh -p "$SSH_PORT" -i /var/lib/postgresql/.ssh/walg_key "$SSH_USER@$SSH_HOST" \
  "for d in $(ls -1 \"$REMOTE_BASE\" | grep -E '^wal_[0-9]+' || true); do \
     n=$(ls -1 \"$REMOTE_BASE/$d\" 2>/dev/null | wc -l); echo $d:$n; \
   done"
```

Check archiver progress inside Postgres:

```bash
# Archived count and last archived WAL
psql -tAc "select archived_count, last_archived_wal, last_archived_time from pg_stat_archiver;"
```

## Troubleshooting tips
- If counts appear stuck but `pg_stat_archiver` increments, that is considered success by the test.
- If the remote is very full and the newest files rotate across `wal_*`, rely on archiver stats or check explicitly for `last_archived_wal` on the remote.
- Avoid pipelines that depend on unavailable commands (`find`, `id`). Prefer `ls -1`, `grep`, and `wc -l`.

## References
- Test script: `test/test-walg-e2e.sh`
- Related docs: `docs/WAL-G-TESTING.md`, `docs/WALG_ENV_ANALYSIS.md`
