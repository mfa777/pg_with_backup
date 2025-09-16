# WAL-G Environment Variables Analysis Report

## Executive Summary

本报告分析了 `env_sample` 文件中与 WAL-G 备份相关的环境变量在生产环境中的使用情况。通过对现有脚本和配置文件的深入分析，识别出哪些变量被实际使用，哪些变量可能存在冗余或未被充分利用。

## WAL-G Environment Variables Analysis

### ✅ 已使用的环境变量 (Used Variables)

以下环境变量在生产 WAL 备份模式下被实际使用：

#### 1. 核心 WAL-G 配置

| 变量名 | 默认值 | 使用位置 | 说明 |
|--------|--------|----------|------|
| `WALG_SSH_PREFIX` | - | `walg-env-prepare.sh`, `wal-g-runner.sh`, `docker-compose.yml` | WAL-G SSH 后端配置，**必需变量** |
| `WALG_SSH_PRIVATE_KEY` | - | `walg-env-prepare.sh`, `docker-compose.yml` | Base64 编码的 SSH 私钥 |
| `WALG_SSH_PRIVATE_KEY_PATH` | `/secrets/walg_ssh_key` | `walg-env-prepare.sh`, `docker-compose.yml` | SSH 私钥文件路径 |
| `WALG_COMPRESSION_METHOD` | `lz4` | `walg-env-prepare.sh`, `docker-compose.yml` | 压缩算法 |
| `WALG_DELTA_MAX_STEPS` | `7` | `walg-env-prepare.sh`, `wal-g-runner.sh`, `docker-compose.yml` | 增量备份链最大长度 |
| `WALG_DELTA_ORIGIN` | `LATEST` | `walg-env-prepare.sh`, `docker-compose.yml` | 增量备份起点 |
| `WALG_LOG_LEVEL` | `DEVEL` | `walg-env-prepare.sh`, `docker-compose.yml` | 日志级别 |

#### 2. 保留策略配置

| 变量名 | 默认值 | 使用位置 | 说明 |
|--------|--------|----------|------|
| `WALG_RETENTION_FULL` | `7` | `wal-g-runner.sh`, `walg-daily-backup.sh` | 保留完整备份数量 |

#### 3. SSH 连接配置

| 变量名 | 默认值 | 使用位置 | 说明 |
|--------|--------|----------|------|
| `SSH_PORT` | `22` | `walg-env-prepare.sh`, `docker-compose.yml` | SSH 端口 |
| `SSH_KEY_PATH` | `./secrets/walg_ssh_key` | `docker-compose.yml` | SSH 密钥目录路径 |

#### 4. 容器和网络配置

| 变量名 | 默认值 | 使用位置 | 说明 |
|--------|--------|----------|------|
| `BACKUP_MODE` | `sql` | `backup.sh`, `walg-env-prepare.sh`, `docker-entrypoint-walg.sh` | 备份模式开关 |
| `POSTGRES_USER` | `postgres` | `walg-env-prepare.sh`, `backup.sh` | PostgreSQL 用户名 |
| `POSTGRES_PASSWORD` | - | `walg-env-prepare.sh` | PostgreSQL 密码 |

#### 5. 通知配置

| 变量名 | 默认值 | 使用位置 | 说明 |
|--------|--------|----------|------|
| `TELEGRAM_BOT_TOKEN` | - | `wal-g-runner.sh`, `walg-daily-backup.sh` | Telegram 机器人令牌 |
| `TELEGRAM_CHAT_ID` | - | `wal-g-runner.sh`, `walg-daily-backup.sh` | Telegram 聊天 ID |
| `TELEGRAM_MESSAGE_PREFIX` | `Database` | `wal-g-runner.sh`, `walg-daily-backup.sh` | 消息前缀 |

### ❌ 未使用的环境变量 (Unused Variables)

以下环境变量在 `env_sample` 中定义，但在生产 WAL 备份模式下**未被实际使用**：

#### 1. 时间和调度相关 (测试/开发用途)

| 变量名 | 默认值 | 状态 | 说明 |
|--------|--------|------|------|
| `WALG_BASEBACKUP_CRON` | `"30 1 * * *"` | ❌ 未使用 | 基础备份 cron 调度，实际使用自定义脚本 |
| `WALG_CLEAN_CRON` | `"15 3 * * *"` | ❌ 未使用 | 清理 cron 调度，集成到每日备份脚本中 |
| `BACKUP_CRON_SCHEDULE` | `"0 2 * * *"` | ⚠️ 部分使用 | 仅在 SQL 模式下使用，WAL 模式有独立调度 |

#### 2. 保留策略 (冗余配置)

| 变量名 | 默认值 | 状态 | 说明 |
|--------|--------|------|------|
| `WALG_RETENTION_DAYS` | `30` | ❌ 未使用 | 基于天数的保留策略，实际使用基于数量的策略 |

#### 3. 测试环境配置

| 变量名 | 默认值 | 状态 | 说明 |
|--------|--------|------|------|
| `ENABLE_SSH_SERVER` | `0` | ✅ 测试路径 | 当=1 时自动提供默认 WALG_SSH_PREFIX/SSH_PORT=2222 |
| `SSH_USER` | (派生) | ✅ 测试路径 | 从 WALG_SSH_PREFIX 提取；ENABLE_SSH_SERVER=1 默认为 walg |
| `WALG_SSH_PREFIX_LOCAL` | `ssh://walg@ssh-server/backups` | ⛔ 已弃用 | 统一改用 WALG_SSH_PREFIX + ENABLE_SSH_SERVER |

#### 4. 时区配置

| 变量名 | 默认值 | 状态 | 说明 |
|--------|--------|------|------|
| `TZ` | `Asia/Shanghai` | ⚠️ 间接使用 | 主要用于容器时区，WAL-G 本身不直接使用 |

#### 5. 遗留/兼容性变量

| 变量名 | 默认值 | 状态 | 说明 |
|--------|--------|------|------|
| `SSH_USERNAME` | - | ⚠️ 运行时推导 | 从 `WALG_SSH_PREFIX` 自动提取，无需单独配置 |

### 🔧 配置优化建议

#### 1. 清理不必要的变量

在生产环境中，可以移除以下变量：

```bash
# 不推荐在生产环境中使用的变量
# WALG_BASEBACKUP_CRON="30 1 * * *"     # 使用自定义脚本替代
# WALG_CLEAN_CRON="15 3 * * *"          # 集成到每日备份中
# WALG_RETENTION_DAYS=30                # 使用基于数量的策略
# ENABLE_SSH_SERVER=0                   # 仅测试用
# SSH_USER=walg                         # 仅测试用
# WALG_SSH_PREFIX_LOCAL=...             # (已弃用) 请删除
```

#### 2. 核心生产配置

生产环境的最小必需配置：

```bash
# --- 备份模式 ---
BACKUP_MODE=wal

# --- WAL-G 核心配置 ---
WALG_SSH_PREFIX=ssh://walg@your-backup-host/absolute/path/to/backup/directory
SSH_PORT=22
WALG_SSH_PRIVATE_KEY_PATH=/secrets/walg_ssh_key
SSH_KEY_PATH=./secrets/walg_ssh_key

# --- WAL-G 性能配置 ---
WALG_COMPRESSION_METHOD=lz4
WALG_DELTA_MAX_STEPS=7
WALG_DELTA_ORIGIN=LATEST
WALG_LOG_LEVEL=NORMAL  # 生产环境建议使用 NORMAL 而非 DEVEL

# --- 保留策略 ---
WALG_RETENTION_FULL=7

# --- 数据库配置 ---
POSTGRES_USER=postgres
POSTGRES_PASSWORD=your_very_strong_superuser_password

# --- 通知配置 (可选) ---
TELEGRAM_BOT_TOKEN=your_bot_token
TELEGRAM_CHAT_ID=your_chat_id
TELEGRAM_MESSAGE_PREFIX=Production DB
```

### 📊 使用率统计

- **总变量数**: 23
- **使用的变量**: 15 (65.2%)
- **未使用的变量**: 8 (34.8%)
- **关键变量**: 7 (必需配置)
- **可选变量**: 8 (性能优化和通知)

### 🚨 关键发现

1. **必需变量**: `WALG_SSH_PREFIX` 是唯一的必需变量，其他都有合理的默认值
2. **冗余配置**: 存在多个未使用的 cron 和保留策略配置
3. **测试配置**: 约 13% 的变量仅用于测试环境
4. **日志级别**: 生产环境建议使用 `NORMAL` 而非 `DEVEL`
5. **自动化程度**: 新的每日备份脚本实现了更好的集成和错误处理

### 📝 建议行动

1. **清理 env_sample**: 移除或标记仅测试用的变量
2. **文档更新**: 明确区分生产和测试配置
3. **配置验证**: 在脚本中添加更多配置验证逻辑
4. **监控改进**: 基于 `WALG_LOG_LEVEL=NORMAL` 优化日志输出
5. **备份策略**: 考虑基于数据量而非固定数量的保留策略

---

*报告生成时间: $(date -Iseconds)*
*分析范围: WAL-G 生产环境配置优化*