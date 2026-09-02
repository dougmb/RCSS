# RCSS — Rclone Cloud Simple Scripts

Automated backup management for multiple projects: uploads local backups to any cloud
service supported by **rclone**, handles local/remote retention, restores, and alerts
you by e-mail when something fails.

---

## Quick Start

```bash
# 1. Install the dependencies (curl is only needed for e-mail alerts)
sudo apt install rclone curl

# 2. Configure a remote
rclone config   # e.g. type: drive → set root_folder_id to your Drive folder ID

# 3. Edit backup.env (BACKUP_ROOT and RCLONE_REMOTE are required)

# 4. Make the scripts executable
chmod +x *.sh

# 5. Check the configuration WITHOUT uploading or deleting anything
./uploadBackup.sh -n -v

# 6. Run for real
./uploadBackup.sh -p
```

---

## Deploying to a server

```bash
# 1. Install
sudo git clone https://github.com/dougmb/RCSS.git /opt/RCSS
cd /opt/RCSS
chmod +x *.sh

# 2. Configure this server (real values live ONLY in this local copy)
nano backup.env

# 3. Dry-run first: no upload, no local deletion
./uploadBackup.sh -n -v

# 4. Schedule it (crontab -e)
# Upload backups daily at 03:00
0 3 * * * /opt/RCSS/uploadBackup.sh >> /opt/backups/sync.log 2>&1

# Upload the log itself at 04:00, into a separate Drive folder
0 4 * * * /opt/RCSS/uploadBackup.sh -a /opt/backups/sync.log -d Logs

# Clean old backups from the cloud every Sunday at 05:00
0 5 * * 0 /opt/RCSS/cleanRemoteBackups.sh >> /opt/backups/sync.log 2>&1
```

Cron runs with a minimal environment, so always use absolute paths. `rclone` reads its
credentials from the config of the user running the job (`~/.config/rclone/rclone.conf`) —
if the cron job runs as root, the remote must be configured for root.

### Updating an existing install

`backup.env` is tracked by git, so a `git pull` that changes the template conflicts with the
real values on the server. Keep your copy aside, update, then put it back:

```bash
cd /opt/RCSS
cp backup.env /root/backup.env.$(hostname)   # keep the real configuration
git stash                                    # park the local changes
git pull
cp /root/backup.env.$(hostname) backup.env   # restore it
diff <(git show HEAD:backup.env) backup.env  # check for NEW variables to fill in
./uploadBackup.sh -n -v                      # validate before the next cron run
```

---

## Scripts

| Script | Description |
|---|---|
| `uploadBackup.sh` | Uploads all project folders in `BACKUP_ROOT` to the cloud |
| `cleanRemoteBackups.sh` | Deletes old backups from the cloud |
| `restoreBackup.sh` | Interactive download of a backup from the cloud |
| `notify.sh` | Shared helper that sends error alerts by e-mail (sourced by the scripts above) |
| `backup.env` | Shared configuration file |

---

## What gets uploaded

```
BACKUP_ROOT/               →  DRIVE_DESTINATION/
├── PROJECT_A/                ├── PROJECT_A/       one folder per project
│   └── dump.tar.gz           │   └── dump.tar.gz
├── PROJECT_B/                ├── PROJECT_B/
├── loose-file.tar.gz         └── loose-file.tar.gz   loose files go to the root
└── sync.log                  (the active log file is never uploaded)
```

Each subfolder of `BACKUP_ROOT` becomes a folder in the cloud. Files sitting directly in
`BACKUP_ROOT` are uploaded to the destination root (disable with `UPLOAD_ROOT_FILES="false"`).
Local cleanup (`LOCAL_CLEANUP`) runs only after a successful upload, and never touches
the log file.

---

## Configuration (`backup.env`)

**Required**

| Variable | Description |
|---|---|
| `BACKUP_ROOT` | Local directory containing project folders (e.g. `/opt/backups`) |
| `RCLONE_REMOTE` | rclone remote name (e.g. `douglas:`) |

**Local cleanup** — what happens to the local files *after* a successful upload

| Variable | Default | Description |
|---|---|---|
| `LOCAL_CLEANUP` | `retention` | `retention` = delete only files older than `RETENTION_DAYS`; `always` = delete every uploaded file; `never` = keep everything locally |
| `RETENTION_DAYS` | `1` | Days to keep local backups. Only used when `LOCAL_CLEANUP="retention"` |

Nothing is ever deleted when the upload fails, and `-n` (dry-run) deletes nothing at all.
`DELETE_AFTER_UPLOAD="true"` is still accepted as a deprecated alias for `LOCAL_CLEANUP="always"`.

**Remote retention** — applied by `cleanRemoteBackups.sh`, fully independent from the local cleanup

| Variable | Default | Description |
|---|---|---|
| `REMOTE_RETENTION_DAYS` | `15` | Days to keep backups in the cloud |

**Cloud**

| Variable | Default | Description |
|---|---|---|
| `DRIVE_DESTINATION` | `Backups` | Destination folder in the cloud |
| `REMOTE_CLEANUP_SAFETY_DAYS` | `2` | Block remote cleanup if no recent backup is found within this many days |

**Upload Behavior**

| Variable | Default | Description |
|---|---|---|
| `IGNORED_FOLDERS` | `scripts config bin logs lost+found` | Folders inside `BACKUP_ROOT` to skip |
| `SKIP_DOTFILES` | `false` | Exclude hidden files/folders (`.env`, `.git/`, etc.) from upload |
| `UPLOAD_ROOT_FILES` | `true` | Also upload files sitting loose in `BACKUP_ROOT`, outside any project folder |

**Notifications** (optional — requires `curl`)

| Variable | Default | Description |
|---|---|---|
| `NOTIFY_EMAIL_TO` | *(empty)* | Address(es) that receive error alerts — one or more, separated by comma and/or space. **Empty disables notifications entirely** |
| `NOTIFY_EMAIL_FROM` | first `NOTIFY_EMAIL_TO` | Sender address |
| `NOTIFY_SUBJECT_PREFIX` | `[RCSS]` | Prefix prepended to the e-mail subject |
| `SMTP_HOST` | *(empty)* | SMTP server (e.g. `smtp.gmail.com`) |
| `SMTP_PORT` | `587` | SMTP port (`587` = STARTTLS) |
| `SMTP_USER` | *(empty)* | SMTP user; leave empty for relays without authentication |
| `SMTP_PASSWORD` | *(empty)* | SMTP password (for Gmail, use an **app password**, without spaces) |

> ⚠️ **Security:** `backup.env` is tracked by git. Never commit real credentials —
> fill these values only in the local copy on each server, and keep the placeholders
> empty in any commit. Cloud credentials are never stored here: they stay in
> `~/.config/rclone/rclone.conf`.

---

## Error Notifications

When `NOTIFY_EMAIL_TO` and `SMTP_HOST` are set, an e-mail alert is sent on failure.
Sending an alert never interrupts the backup: any SMTP problem is only logged as a warning.

```bash
# backup.env (on the server only — never commit these values)
NOTIFY_EMAIL_TO="you@example.com, ops@example.com"   # one or more
SMTP_HOST="smtp.gmail.com"
SMTP_PORT="587"
SMTP_USER="you@gmail.com"
SMTP_PASSWORD="your-app-password"
```

Alerts are sent when:

| Situation | Script |
|---|---|
| One or more projects failed to sync (single summary e-mail per run, listing the failed projects) | `uploadBackup.sh` |
| **Nothing was found to upload** — no project folder and no loose file (unmounted disk, wrong `BACKUP_ROOT`, backups that stopped being generated) | `uploadBackup.sh` |
| Single file upload (`-a`) failed | `uploadBackup.sh` |
| Unexpected termination (rclone missing, `BACKUP_ROOT` not found, etc.) | both |
| Safety abort — no recent backup found in the cloud | `cleanRemoteBackups.sh` |
| `rclone delete` failed during cloud cleanup | `cleanRemoteBackups.sh` |

Every alert includes the hostname, the script name, the timestamp and the last lines of the log,
so it is clear which server raised it. Alerts raised during a dry-run (`-n`) are marked with
`[DRY-RUN]` in the subject, so a test is never mistaken for a real incident.

To validate the setup on a new server, force a failure against a remote that does not exist —
nothing is uploaded and nothing is deleted:

```bash
./uploadBackup.sh -n -v -r nonexistent-remote:
```

`uploadBackup.sh` reports the run status in the log summary and in its exit code:

| Status | Exit | Meaning |
|---|---|---|
| `SUCCESS` | `0` | Everything was uploaded |
| `PARTIAL` | `1` | At least one project failed; local cleanup was skipped for it |
| `EMPTY` | `1` | Nothing was found to upload — never reported as success |

---

## `uploadBackup.sh` Flags

| Flag | Description |
|---|---|
| `-p` | Show progress bar |
| `-v` | Verbose output |
| `-n` | Dry-run: nothing is uploaded and **nothing is deleted locally** — safe way to test a new configuration |
| `-D` | Force `LOCAL_CLEANUP="always"`: delete every uploaded file locally |
| `-k` | Force `LOCAL_CLEANUP="never"`: keep every local file |
| `-s` | Enable `SKIP_DOTFILES` (default: off) |
| `-o <path>` | Override `BACKUP_ROOT` |
| `-r <remote>` | Override `RCLONE_REMOTE` |
| `-d <folder>` | Override `DRIVE_DESTINATION` |
| `-i <folders>` | Extra folders to ignore (appended to `IGNORED_FOLDERS`) |
| `-a <file>` | Upload a single file instead of scanning project folders |

---

## Usage Examples

```bash
# Test a configuration without uploading or deleting anything
./uploadBackup.sh -n -v

# Upload with progress bar
./uploadBackup.sh -p

# Delete local files immediately after upload
./uploadBackup.sh -D

# Upload without deleting anything locally
./uploadBackup.sh -k

# Upload a single file to a specific cloud folder
./uploadBackup.sh -a /opt/backups/sync.log -d Logs

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
