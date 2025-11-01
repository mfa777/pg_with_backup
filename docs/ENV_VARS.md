# Environment Variables Reference

This document summarizes all supported environment variables. It is generated/curated alongside the machine-readable catalog located at `docs/env_vars.json`.

| Name | Category | Default | Required | Mode Scope | Description |
|------|----------|---------|----------|------------|-------------|
| BACKUP_MODE | core | sql | yes | all | Select backup strategy: `sql` full dumps or `wal` incremental wal-g |
| POSTGRES_VERSION | core | 18.0 | no | all | PostgreSQL Docker image version (e.g., 17.4, 16.3). Used for base image and as subdirectory in WAL backup storage |
| POSTGRES_USER | postgres | postgres | yes | all | PostgreSQL superuser name used for backups |
| POSTGRES_PASSWORD | postgres | (none) | yes | all | PostgreSQL superuser password (must set) |
| ENABLE_PGBOUNCER | pgbouncer | 0 | no | all | Enable PgBouncer connection pooler (0=disabled, 1=enabled) |
| PGBOUNCER_PORT | pgbouncer | 6432 | no | all | PgBouncer listen port inside container |
| PGBOUNCER_HOST_PORT | pgbouncer | 6432 | no | all | Host port to expose PgBouncer |
| PGBOUNCER_POOL_MODE | pgbouncer | session | no | all | Pool mode: session, transaction, or statement |
| PGBOUNCER_MAX_CLIENT_CONN | pgbouncer | 100 | no | all | Maximum number of client connections |
| PGBOUNCER_DEFAULT_POOL_SIZE | pgbouncer | 20 | no | all | Default pool size per user/database pair |
| POSTGRES_DOCKERFILE | build | (unset) | no | wal (optional) | Custom Dockerfile for postgres (use `Dockerfile.postgres-walg` for WAL mode) |
| POSTGRES_IMAGE | build | pgvector/pgvector:pg17 | no | all | Base image when not building a custom Dockerfile |
| BACKUP_DOCKERFILE | build | Dockerfile.backup | no | all | Override backup service Dockerfile |
| RCLONE_CONFIG_BASE64 | sql_mode | (none) | when sql | sql | Base64 rclone.conf content for SQL uploads |
| AGE_PUBLIC_KEY | sql_mode | (none) | when sql | sql | Age public key for dump encryption |
| REMOTE_PATH | sql_mode | (none) | when sql | sql | Rclone remote target (e.g. `remote:folder`) |
| SQL_BACKUP_RETAIN_DAYS | sql_mode | 30 | no | sql | Days to retain SQL dumps remotely |
| BACKUP_CRON_SCHEDULE | sql_mode | 0 2 * * * | no | sql | Cron schedule for daily SQL dump |
| WALG_SSH_PREFIX | wal_mode | (none) | when wal | wal | SSH storage URI `ssh://user@host[:port]/abs/path` |
| SSH_PORT | wal_mode | 22 | no | wal | SSH port (auto-detected from prefix if present) |
| WALG_SSH_PRIVATE_KEY | wal_mode | (none) | no | wal | Base64 encoded private key (alternative to path) |
| WALG_SSH_PRIVATE_KEY_PATH | wal_mode | /secrets/walg_ssh_key | no | wal | Mounted path to SSH private key |
| SSH_KEY_PATH | wal_mode | ./secrets/walg_ssh_key | no | wal | Host path mounted for key directory |
| WALG_COMPRESSION_METHOD | wal_mode | lz4 | no | wal | wal-g compression method |
| WALG_DELTA_MAX_STEPS | wal_mode | 7 | no | wal | Max delta chain length before full backup |
| WALG_DELTA_ORIGIN | wal_mode | LATEST | no | wal | Delta origin reference |
| WALG_LOG_LEVEL | wal_mode | DEVEL | no | wal | wal-g log verbosity |
| WALG_RETENTION_FULL | wal_mode | 7 | no | wal | Number of full backups to retain |
| WALG_BASEBACKUP_CRON | wal_mode | 30 1 * * * | no | wal | Cron for base backups |
| WALG_CLEAN_CRON | wal_mode | 15 3 * * * | no | wal | Cron for retention/cleanup |
| ENABLE_SSH_SERVER | testing | 0 | no | wal/testing | When 1 auto-starts internal ssh-server (profile) and supplies default WALG_SSH_PREFIX/SSH_PORT=2222 |
| SSH_USER | testing | (derived) | no | wal/testing | Username (derived from WALG_SSH_PREFIX unless set; default walg when ENABLE_SSH_SERVER=1) |
| SKIP_SSH_KEYSCAN | testing | 0 | no | wal/testing | Skip ssh-keyscan host key fetch |
| TELEGRAM_BOT_TOKEN | notifications | (none) | no | all | Telegram bot token for alerts |
| TELEGRAM_CHAT_ID | notifications | (none) | no | all | Telegram target chat ID |
| TELEGRAM_MESSAGE_PREFIX | notifications | Database | no | all | Prefix for Telegram messages |
| TZ | general | UTC | no | all | Container timezone (cron + logs) |
| PGADMIN_DEFAULT_EMAIL | pgadmin | admin@admin.com | no | all | pgAdmin initial email |
| PGADMIN_DEFAULT_PASSWORD | pgadmin | admin | no | all | pgAdmin initial password |
| BACKUP_VOLUME_MODE | advanced | (unset) | no | wal | Advisory flag for external orchestration only |
| SSH_USERNAME | wal_mode | (derived) | no | wal | Auto-derived from WALG_SSH_PREFIX (override allowed) |
| WALE_SSH_PREFIX | compatibility | (derived) | no | wal | Legacy alias exported for tooling expecting WALE_* |

## Notes
- "when sql" / "when wal" means required only if that mode is active.
 - "when sql" / "when wal" means required only if that mode is active.
 
- `WALE_SSH_PREFIX` is emitted automatically; do not set manually unless for legacy tooling.

## Machine-Readable Format
See `docs/env_vars.json` for structured metadata (suitable for code generation, validation tooling, or schema export).

## Update Process
1. Edit `docs/env_vars.json` (source of truth)
2. Synchronize this Markdown table if variables change
3. Run tests to ensure no breakage: `./test/run-tests.sh`

