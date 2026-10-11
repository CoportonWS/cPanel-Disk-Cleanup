# cPanel Disk Cleanup

A safe, interactive Bash script that finds what is filling up a cPanel/WHM server's disk, shows you a clear report, and cleans it up **only with your permission**.

Routine junk (old logs, package cache) is cleaned in one step. Anything that could matter (backups, databases, user files, kernels) is asked about **one item at a time**.

```
╔════════════════════════════════════════════════════════════════════╗
║                                                                    ║
║                     SERVER DISK CLEANUP   v2.0                     ║
║              cPanel Server Storage Analysis & Cleanup              ║
║                                                                    ║
╠════════════════════════════════════════════════════════════════════╣
║  Host  : server.example.com                                        ║
║  Date  : 11 Oct 2026, 12:02:56                                     ║
║  Mode  : Report only (nothing will be changed)                     ║
╠════════════════════════════════════════════════════════════════════╣
║                  Created by Coporton WorkStation                   ║
║                    Open source  -  MIT License                     ║
╚════════════════════════════════════════════════════════════════════╝

╔════════════════════════════════════════════════════════════════════╗
║        SAFE ITEMS (CLEANED TOGETHER AFTER ONE CONFIRMATION)        ║
╚════════════════════════════════════════════════════════════════════╝
     326.5MB  DNF package cache (/var/cache/dnf)
      47.2MB  Rotated logs in /var/log older than 14 days
     197.1MB  Empty oversized live log /usr/local/cpanel/logs/error_log
     570.8MB  total

╔════════════════════════════════════════════════════════════════════╗
║                 SENSITIVE ITEMS (ASKED ONE BY ONE)                 ║
╚════════════════════════════════════════════════════════════════════╝
  JetBackup download archives
        8.0GB  download_example_1722078975.tar.gz  (made 2024-07-27)
  Exim stats database
        8.9GB  VACUUM /var/cpanel/eximstats_db.sqlite3
```

## Why

On cPanel servers the root partition (`/`) is often small while `/home` is large. A handful of things quietly fill `/` until services fail: forgotten JetBackup download archives, a multi-gigabyte Exim stats database, rotated logs, old kernels. This script finds them in one pass and removes them without touching anything it should not.

## Features

- **Report first.** The scan never changes anything. Use `--report` to only look.
- **Two levels of confirmation.** Safe items need one `y`. Sensitive items are asked one by one.
- **Hard safety guard.** Protected paths are refused in code, not just skipped by convention.
- **Every action logged.** Each deleted or truncated path is written to a log file.
- **Extra findings.** Biggest folders, files over 500 MB, backups sitting on the root partition, deleted files still held open, and a mail health check that flags possible spam.
- **No dependencies.** Plain Bash and standard system tools.

## What it cleans

### Safe items (one confirmation for all)

| Item | Rule |
|---|---|
| DNF package cache | `dnf clean all` |
| systemd journal | trimmed to 200 MB |
| Rotated logs in `/var/log` | older than 14 days |
| Leftover `*.uninstall` log folders | logs of removed packages, e.g. nginx |
| Rotated ModSecurity logs, Apache log archive | older than 30 days |
| ModSecurity per-request audit files | older than 7 days |
| cPanel update logs and log archive | older than 30 days |
| Oversized live system logs | emptied (truncated, not deleted) when over 100 MB |

### Sensitive items (asked one by one)

| Item | What happens |
|---|---|
| JetBackup download archives | file deleted; real backups in the backup destination are untouched |
| `cpmove-*` account transfer files | deleted |
| Old kernels | removed with `dnf`; the running kernel and the newest 2 are always kept |
| Exim stats database | compacted with SQLite `VACUUM`; no data is removed |
| MySQL binary logs | purged through MySQL (`PURGE BINARY LOGS`), never by deleting files |
| Users' File Manager trash | emptied |
| Softaculous backups | emptied |
| PHP `error_log` files over 50 MB in user sites | emptied so the site keeps logging |

### Never touched

- `/home/virtfs`: jailshell bind mounts of real system files. Deleting here can delete real system files.
- Raw files under `/var/lib/mysql`
- `/usr/tmpDSK`: the backing file of cPanel's `/tmp`
- `/etc` and `/boot`
- Live mail, and anything outside the locations listed above

## Requirements

- cPanel/WHM server, run as **root**
- Tested on AlmaLinux 8. Should work on other EL8/EL9 cPanel servers (Rocky Linux, CloudLinux).
- Bash 4.4+, coreutils, `find`, `du`, `dnf`
- Optional: `sqlite3` (Exim stats check), `mysql` client (binlog check), `lsof` (open deleted files)

## Installation

```bash
curl -O https://raw.githubusercontent.com/CoportonWS/cpanel-disk-cleanup/main/cpanel-disk-cleanup.sh
chmod 700 cpanel-disk-cleanup.sh
```

Or clone the repository:

```bash
git clone https://github.com/CoportonWS/cpanel-disk-cleanup.git
cd cpanel-disk-cleanup
chmod 700 cpanel-disk-cleanup.sh
```

## Usage

```bash
bash cpanel-disk-cleanup.sh --report        # scan only, change nothing (start here)
bash cpanel-disk-cleanup.sh                 # scan + interactive cleanup
bash cpanel-disk-cleanup.sh --log-days 30   # keep rotated logs 30 days (default 14)
bash cpanel-disk-cleanup.sh --help          # show help
```

### How a run works

1. **Scan.** Measures every location and prints the report. Nothing changes.
2. **Safe cleanup.** One prompt: `Clean all 4 safe items (690.3MB)? [y/N]`
3. **Sensitive cleanup.** One prompt per item, grouped by type.
4. **Result.** Shows disk usage after cleanup and how much space was freed.

### Answer keys for sensitive items

| Key | Meaning |
|---|---|
| `y` | remove this item |
| `N` / Enter | keep it (default) |
| `a` | remove all remaining items in this group |
| `q` | skip the rest of this group |

Pressing Enter always means **no**. If no terminal is attached (for example, from cron), the script refuses to clean and nothing is deleted.

## Scheduled reports

The report mode is safe to run from cron. For a monthly report on the 1st at 09:00:

```cron
0 9 1 * * /root/cpanel-disk-cleanup.sh --report >/dev/null 2>&1
```

Cleanup itself always needs a person at the keyboard.

## Output files

| File | Contents |
|---|---|
| `/root/disk-cleanup-reports/report-<date>.txt` | full report of each run (plain text, no colours) |
| `/var/log/cpanel-disk-cleanup.log` | every deleted, truncated or refused path, with timestamp |

## Configuration

The thresholds are variables near the top of the script:

| Variable | Default | Meaning |
|---|---|---|
| `LOG_DAYS` | 14 | rotated logs older than this are cleaned |
| `APACHE_DAYS` | 30 | rotated ModSecurity logs and Apache archive |
| `MODSEC_DIR_DAYS` | 7 | ModSecurity per-request audit files |
| `CPANEL_LOG_DAYS` | 30 | cPanel update logs and log archive |
| `JOURNAL_MAX` | 200M | systemd journal size limit |
| `TRUNCATE_OVER_MB` | 100 | live system logs bigger than this are emptied |
| `HOME_ERRLOG_OVER_MB` | 50 | user `error_log` files bigger than this are offered |
| `TRASH_OVER_MB` | 10 | user trash folders bigger than this are offered |
| `BIG_FILE_MB` | 500 | files on `/` bigger than this are listed |
| `KEEP_KERNELS` | 2 | newest kernels kept |
| `BINLOG_KEEP_DAYS` | 3 | MySQL binary logs newer than this are kept |

## Tips

- **Exim stats database is huge?** Lower *WHM > Tweak Settings > Stats and Logs > Exim stats retention*, wait one night for the purge, then run the script and approve the `VACUUM`. Mail delivery keeps working during it; only the WHM mail statistics pages pause.
- **Exim logs or the stats database grow fast?** That usually means a compromised account or script is sending spam. Check the *Mail health* section of the report.
- **Backups on the root partition?** Point *WHM > Backup Configuration* and JetBackup destinations to a folder on `/home`.
- **Restrict who can run it:** keep it at `chmod 700`, owned by root. To let another admin run only this script, use a `sudoers` rule instead of sharing root.

## Disclaimer

This script deletes files. It is written to be careful, but every server is different. Run `--report` first, read what it plans to do, and keep current backups. Use it at your own risk.

## License

[MIT](LICENSE) © CoportonWS
