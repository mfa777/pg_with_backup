# Scripts Directory Structure

This directory contains organized scripts for the PostgreSQL backup system.

## Directory Structure

```
scripts/
├── setup/          # Setup and initialization scripts
│   └── setup-local-ssh.sh  # Local SSH server setup for testing
├── utils/          # General utility scripts
│   ├── switch-mode.sh      # Unified backup mode switching
│   └── validate-config.sh  # Configuration validation
└── walg/           # WAL-G specific scripts
    ├── docker-entrypoint-walg.sh  # WAL-G Docker entrypoint
    ├── mock-wal-g.sh              # Mock WAL-G for testing
    ├── wal-g-runner.sh            # WAL-G backup operations
    └── walg-env-prepare.sh        # WAL-G environment setup
```

## Usage

### Mode Switching
```bash
# Switch to SQL backup mode
./scripts/utils/switch-mode.sh sql

# Switch to WAL-G backup mode  
./scripts/utils/switch-mode.sh wal
```

### Configuration Validation
```bash
# Validate current configuration
./scripts/utils/validate-config.sh
```

### WAL-G Setup
```bash
# Setup local SSH server for testing
./scripts/setup/setup-local-ssh.sh
```

## Migration Notes

Previous script locations have been reorganized:
- `scripts/switch-to-sql.sh` → `scripts/utils/switch-mode.sh sql`
- `scripts/switch-to-wal.sh` → `scripts/utils/switch-mode.sh wal`
- `scripts/setup-local-ssh.sh` → `scripts/setup/setup-local-ssh.sh`
- WAL-G scripts moved to `scripts/walg/` subdirectory