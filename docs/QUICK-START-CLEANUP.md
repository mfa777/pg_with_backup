# Quick Start Guide - WAL-G Time-Based Cleanup

## Problem You Were Facing

WAL-G cleanup command was showing "No backup found for deletion" even though you had old backups and WAL files from September 20 (over 30 days ago) in your remote storage.

## Why It Wasn't Working

Your `.env` had:
```bash
WALG_RETENTION_FULL=7    # Keep 7 full backups
WALG_RETENTION_DAYS=30   # Keep 30 days (NOT IMPLEMENTED)
```

The script was only using `WALG_RETENTION_FULL` and ignoring `WALG_RETENTION_DAYS`. Since you likely had fewer than 7 **full** backups (most were delta/incremental), nothing was getting deleted.

## How It Works Now

The enhanced cleanup now uses **both** retention policies:

1. **Time-based cleanup** (NEW): Deletes backups older than `WALG_RETENTION_DAYS`
2. **Count-based cleanup** (existing): Keeps at least `WALG_RETENTION_FULL` backups

**Important**: Backups are **kept** if they meet **EITHER** condition (OR logic). This is a safety-first approach.

### Example Scenario

With your settings:
```bash
WALG_RETENTION_FULL=7
WALG_RETENTION_DAYS=30
```

- If you have 10 backups total:
  - 3 from September (older than 30 days)
  - 7 from October-November (within 30 days)
  - Result: The 3 old backups will be **deleted** ✓
  - You'll keep 7 recent backups

- If you only have 5 backups total:
  - All from September (older than 30 days)
  - Result: **Nothing deleted** (safety: keep at least 7... wait, only 5 exist, so keep all 5)
  - You'll keep all 5 backups (even though they're old)

- If you have 15 backups:
  - 8 from September (older than 30 days)
  - 7 from October-November (within 30 days)
  - Result: The 8 old backups will be **deleted** ✓
  - You'll keep 7 recent backups

## What You Need to Do

### 1. Update Your Repository

Pull the latest changes from the PR branch or merge it to your main branch.

### 2. Verify Your Configuration

Check your `.env` file has both settings:
```bash
# Keep at least 7 full backups
WALG_RETENTION_FULL=7

# Delete backups older than 30 days (if more than 7 exist)
WALG_RETENTION_DAYS=30
```

### 3. Test the Cleanup

Run cleanup manually to see it work:
```bash
sudo docker compose exec backup bash -c "/opt/walg/scripts/wal-g-runner.sh clean"
```

### 4. Expected Output

You should now see:
```
[2025-11-01T07:58:57+08:00] wal-g-runner starting (mode: clean)
[2025-11-01T07:58:57+08:00] Validating wal-g environment...
[2025-11-01T07:58:57+08:00] Environment validation passed
[2025-11-01T07:58:57+08:00] Starting wal-g cleanup...
[2025-11-01T07:58:57+08:00] Applying time-based retention: deleting backups older than 30 days
[2025-11-01T07:58:57+08:00] Cutoff date: 2025-10-02T00:00:00Z (epoch: 1727827200)
[2025-11-01T07:58:58+08:00] Found old backup: base_20240920T073000Z (age: 406 days)
[2025-11-01T07:59:00+08:00] Deleting all backups before: base_20241020T073000Z
INFO: 2025/11/01 07:59:00.123456 Deleting backup base_20240920T073000Z
INFO: 2025/11/01 07:59:05.123456 Deleting backup base_20241001T073000Z
[2025-11-01T07:59:35+08:00] Successfully deleted old backups and associated WAL files
[2025-11-01T07:59:35+08:00] Retaining 7 full backups (count-based)
INFO: 2025/11/01 07:59:35.123456 No backup found for deletion
[2025-11-01T07:59:40+08:00] Cleanup completed successfully
```

Key changes:
- ✅ "Applying time-based retention" message appears
- ✅ Old backups are identified with their age
- ✅ Backups and WAL files are deleted
- ✅ "Successfully deleted" message instead of just "No backup found"

## Automatic Cleanup

Your cron schedule will automatically run cleanup:
```bash
WALG_CLEAN_CRON="15 3 * * *"  # Daily at 3:15 AM
```

No changes needed - it will now use both retention policies automatically.

## Troubleshooting

### Still seeing "No backup found for deletion"?

This is now **normal** if:
1. All backups are within the retention period (< 30 days old), OR
2. You have fewer than 7 backups and they're all old (safety keeps them)

### Want to force cleanup of old backups?

Temporarily reduce the retention:
```bash
# In .env, change to:
WALG_RETENTION_DAYS=7   # More aggressive
```

Then run cleanup manually.

### Check what backups exist:

```bash
sudo docker compose exec backup bash -c "wal-g backup-list"
```

This shows all backups with their timestamps.

## Additional Notes

### WAL File Cleanup

When a backup is deleted, **all its associated WAL files are also deleted automatically**. This is why the September 20 WAL files will now be cleaned up.

### Delta vs Full Backups

The count-based retention (`WALG_RETENTION_FULL=7`) only counts **full** backups, not delta/incremental backups. This is a WAL-G design choice. The time-based retention handles **all** backups (full and delta).

### Safety Features

1. **Never deletes all backups**: Always keeps at least one
2. **OR logic**: Keeps backups that meet either retention condition
3. **Validation**: Timestamps are validated before parsing
4. **Error handling**: If date calculations fail, cleanup is skipped
5. **Logging**: Detailed logs for troubleshooting

## Questions?

Check the comprehensive documentation:
- `docs/WAL-G-CLEANUP-FIX.md` - Detailed technical documentation
- `env_sample` - Configuration examples and explanations

## Success Criteria

After the next cleanup run, you should see:
- ✅ Old backups from September 20 are deleted
- ✅ WAL files from September 20 are deleted
- ✅ Recent backups (within 30 days) are kept
- ✅ At least 7 backups are always maintained (if available)
