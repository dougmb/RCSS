# RcloneCloudSimpleScripts(RCSS) - Backup Synchronization

Automated system for multi-project backup management integrating local storage and Google Drive via **rclone**.

## 📂 Structure Overview

- **`uploadBackup.sh`**: Backs up all folders within `BACKUP_ROOT` to the cloud. Supports CLI overrides (`-o`, `-r`, `-d`, `-i`).
- **`restoreBackup.sh`**: Interactive download of a selected backup from the cloud to the local server. Supports custom output path (`-o`).
- **`cleanRemoteBackups.sh`**: Remote cleanup of backups older than `REMOTE_RETENTION_DAYS`.
- **`backup.env`**: Configuration file with environment settings.
- **`sync.log`**: Contains historical logs of script executions.

---

## 🛠️ Getting to Know the Scripts

### 1. `uploadBackup.sh` (Main Synchronization)

**What it does:** Iterates through the local backup directory and uploads new/changed files to the cloud.

- **Automatic Detection:** Identifies subfolders in `/opt/backups/` as independent projects.
- **Efficient Upload:** Uses `rclone copy --update` to save bandwidth.
- **Local Cleanup:** Removes files from the local server that have exceeded `RETENTION_DAYS` (only after successful upload).
- **Security:** Ignores hidden folders and administrative directories (configurable via `IGNORED_FOLDERS`).
- **Single File Mode:** Use `-a <file>` to upload an individual file instead of scanning project directories.

### 2. `cleanRemoteBackups.sh` (Cloud Maintenance)

**What it does:** Manages Google Drive space by removing old backups.

- **Independent:** Runs separately from the upload for greater control.
- **Safety Lock:** **NEVER** deletes files if it detects that backups have stopped being made (based on `REMOTE_CLEANUP_SAFETY_DAYS`).
- **Simulation:** Allows running with the `-d` (dry-run) flag to see what would be deleted without actually deleting anything.

### 3. `restoreBackup.sh` (Backup Download)

**What it does:** Interactive interface to download backups from the cloud to the local server.

- **Navigation:** Lists projects and files directly from Google Drive.
- **Selective Download:** Allows choosing exactly which project and file to restore.
- **Custom Output:** Use `-o <path>` to restore to a specific directory instead of the default `BACKUP_ROOT/<project>`.

---

## 🚀 Step-by-Step Configuration

### 1. Install rclone

Ensure rclone is installed on the server:

```bash
sudo apt install rclone  # Debian/Ubuntu
```

### 2. Configure Remote with a Specific Folder

To ensure files go exactly to the desired folder, follow these steps:

1. In the terminal, run: `rclone config`
2. Type `n` for a new remote and name it `douglas`.
3. Choose the `drive` type (Google Drive).
4. Leave `client_id` and `client_secret` blank.
5. In scope (`scope`), choose `1` (Full access).
6. **Important:** When asked for `root_folder_id`, paste your folder ID.
7. Leave `service_account_file` blank.
8. In `Edit advanced config`, type `n`.
9. In `Use auto config`, type `y` if on your local PC or `n` if on a remote server (via SSH).
10. Confirm everything is correct with `y`.

### 3. Configure the `backup.env` file

Edit the `backup.env` file in the same folder as the script to define:

- `BACKUP_ROOT`: Where your local backups are located.
- `RCLONE_REMOTE`: The name you configured (e.g., `douglas:`).
- `DRIVE_DESTINATION`: Subfolder name on Drive.
- `RETENTION_DAYS`: Retention on the local server.
- `REMOTE_RETENTION_DAYS`: Retention in the cloud.
- `REMOTE_CLEANUP_SAFETY_DAYS`: Safety window for remote cleanup.
- `IGNORED_FOLDERS`: List of folders (space-separated) to be ignored in the backup root.

---

## 📅 Scheduling (Cron)

To automate the system, we recommend scheduling Upload and Cleanup at different times.

Edit your crontab:

```bash
crontab -e
```

Add the lines below (adjust paths according to your installation):

```bash
# 1. Sync backups to the cloud (Every day at 03:00)
0 3 * * * /opt/backup/uploadBackup.sh >> /opt/backup/sync.log 2>&1

# 2. Clean old backups in the cloud (Every Sunday at 05:00)
0 5 * * 0 /opt/backup/cleanRemoteBackups.sh >> /opt/backup/sync.log 2>&1
```

---

## 📋 Useful Commands

- **Run upload with a progress bar:**

  ```bash
  ./uploadBackup.sh -p -v
  ```

- **Run upload overriding backup root, remote, or destination:**

  ```bash
  # Override backup source directory (origin)
  ./uploadBackup.sh -o /mnt/other/backups

  # Override rclone remote and drive destination
  ./uploadBackup.sh -r otherremote: -d OtherFolder

  # Combine all overrides
  ./uploadBackup.sh -v -p -o /mnt/other/backups -r otherremote: -d OtherFolder

  # Ignore specific folders at runtime
  ./uploadBackup.sh -o /opt -i backups
  ./uploadBackup.sh -o /opt -i "backups RCSS containerd"

  # Upload a single file to a specific folder on Drive
  ./uploadBackup.sh -a /opt/RCSS/sync.log -d Logs
  ```

- **Restore a backup interactively:**

  ```bash
  ./restoreBackup.sh -p -v
  ```

- **Restore a backup to a custom directory:**

  ```bash
  ./restoreBackup.sh -p -v -o /tmp/my-restore
  ```

- **Simulate cloud cleanup (see what would be deleted):**

  ```bash
  ./cleanRemoteBackups.sh -d -v
  ```

- **Check logs:**
  ```bash
  tail -f sync.log
  ```

---

## 🔒 Security

The script has a custom exclusion list via `IGNORED_FOLDERS` to avoid touching administrative folders like `scripts`, `logs`, `config`, etc. You can safely store your scripts as long as the folder name is in the ignored list.
