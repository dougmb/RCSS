# RCSS — Rclone Cloud Simple Scripts

Automated backup management for multiple projects: uploads to CLOUD services suported by the **rclone**, and other funcions:
---

## Quick Start

```bash
# 1. Install rclone
sudo apt install rclone

# 2. Configure a Google Drive remote
rclone config   # type: drive → set root_folder_id to your Drive folder ID

# 3. Edit backup.env with your settings (BACKUP_ROOT and RCLONE_REMOTE are required)

# 4. Make scripts executable
chmod +x *.sh

# 5. Run
./uploadBackup.sh -p
```

---

## Complete Setup with Cron

```bash
# Edit backup.env
BACKUP_ROOT="/opt/backups"
RCLONE_REMOTE="account:"
DRIVE_DESTINATION="Backups"
RETENTION_DAYS=1
REMOTE_RETENTION_DAYS=15

# Make executable
chmod +x /opt/backup/*.sh

# Schedule (crontab -e)
# Upload daily at 03:00
0 3 * * * /opt/backup/uploadBackup.sh >> /opt/backup/sync.log 2>&1

# Clean Drive every Sunday at 05:00
0 5 * * 0 /opt/backup/cleanRemoteBackups.sh >> /opt/backup/sync.log 2>&1
```

---

## Scripts

| Script | Description |
|---|---|
| `uploadBackup.sh` | Uploads all project folders in `BACKUP_ROOT` to the cloud |
| `cleanRemoteBackups.sh` | Deletes old backups from Google Drive |
| `restoreBackup.sh` | Interactive download of a backup from the cloud |
| `notify.sh` | Shared helper that sends error alerts by e-mail (sourced by the scripts above) |
| `backup.env` | Shared configuration file |

---

## Configuration (`backup.env`)

**Required**

| Variable | Description |
|---|---|
| `BACKUP_ROOT` | Local directory containing project folders (e.g. `/opt/backups`) |
| `RCLONE_REMOTE` | rclone remote name (e.g. `douglas:`) |

**Retention**

| Variable | Default | Description |
|---|---|---|
| `RETENTION_DAYS` | `1` | Days to keep local backups before deletion |
| `REMOTE_RETENTION_DAYS` | `15` | Days to keep backups on Drive |
| `DELETE_AFTER_UPLOAD` | `false` | Delete local files immediately after upload (overrides `RETENTION_DAYS`) |

**Cloud**

| Variable | Default | Description |
|---|---|---|
| `DRIVE_DESTINATION` | `Backups` | Destination folder on Google Drive |
| `REMOTE_CLEANUP_SAFETY_DAYS` | `2` | Block remote cleanup if no recent backup is found within this many days |

**Upload Behavior**

| Variable | Default | Description |
|---|---|---|
| `IGNORED_FOLDERS` | `scripts config bin logs lost+found` | Folders inside `BACKUP_ROOT` to skip |
| `SKIP_DOTFILES` | `false` | Exclude hidden files/folders (`.env`, `.git/`, etc.) from upload |

**Notifications** (optional — requires `curl`)

| Variable | Default | Description |
|---|---|---|
| `NOTIFY_EMAIL_TO` | *(empty)* | Address that receives error alerts. **Empty disables notifications entirely** |
| `NOTIFY_EMAIL_FROM` | `NOTIFY_EMAIL_TO` | Sender address |
| `NOTIFY_SUBJECT_PREFIX` | `[RCSS]` | Prefix prepended to the e-mail subject |
| `SMTP_HOST` | *(empty)* | SMTP server (e.g. `smtp.gmail.com`) |
| `SMTP_PORT` | `587` | SMTP port (`587` = STARTTLS) |
| `SMTP_USER` | *(empty)* | SMTP user; leave empty for relays without authentication |
| `SMTP_PASSWORD` | *(empty)* | SMTP password (for Gmail, use an **app password**) |

> ⚠️ **Security:** `backup.env` is tracked by git. Never commit real credentials —
> fill these values only in the local copy on each server, after a `git pull`.

---

## Error Notifications

When `NOTIFY_EMAIL_TO` and `SMTP_HOST` are set, an e-mail alert is sent on failure.
Sending an alert never interrupts the backup: any SMTP problem is only logged as a warning.

```bash
# backup.env (on the server only — never commit these values)
NOTIFY_EMAIL_TO="you@example.com"
SMTP_HOST="smtp.gmail.com"
SMTP_PORT="587"
SMTP_USER="you@gmail.com"
SMTP_PASSWORD="your-app-password"
```

Alerts are sent when:

| Situation | Script |
|---|---|
| One or more projects failed to sync (single summary e-mail per run, listing the failed projects) | `uploadBackup.sh` |
| Single file upload (`-a`) failed | `uploadBackup.sh` |
| Unexpected termination (rclone missing, `BACKUP_ROOT` not found, etc.) | both |
| Safety abort — no recent backup found on the cloud | `cleanRemoteBackups.sh` |
| `rclone delete` failed during cloud cleanup | `cleanRemoteBackups.sh` |

Every alert includes the hostname, the script name, the timestamp and the last lines of the log,
so it is clear which server raised it.

---

## `uploadBackup.sh` Flags

| Flag | Description |
|---|---|
| `-p` | Show progress bar |
| `-v` | Verbose output |
| `-D` | Enable `DELETE_AFTER_UPLOAD` (default: off) |
| `-s` | Enable `SKIP_DOTFILES` (default: off) |
| `-o <path>` | Override `BACKUP_ROOT` |
| `-r <remote>` | Override `RCLONE_REMOTE` |
| `-d <folder>` | Override `DRIVE_DESTINATION` |
| `-i <folders>` | Extra folders to ignore (appended to `IGNORED_FOLDERS`) |
| `-a <file>` | Upload a single file instead of scanning project folders |

---

## Usage Examples

```bash
# Upload with progress bar
./uploadBackup.sh -p

# Delete local files immediately after upload
./uploadBackup.sh -D

# Upload a single file to a specific Drive folder
./uploadBackup.sh -a /opt/RCSS/sync.log -d Logs

# Override source, remote, and destination
./uploadBackup.sh -o /mnt/other/backups -r otherremote: -d OtherFolder

# Exclude dotfiles from upload
./uploadBackup.sh -s

# Restore a backup interactively
./restoreBackup.sh -p -v

# Restore to a custom directory
./restoreBackup.sh -o /tmp/my-restore

# Simulate cloud cleanup (dry-run)
./cleanRemoteBackups.sh -d -v

# Check logs
tail -f sync.log
```


Built on top of [rclone](https://rclone.org) — the open source cloud storage manager.

[![ko-fi](https://ko-fi.com/img/githubbutton_sm.svg)](https://ko-fi.com/Q5Q61UQM6J)
