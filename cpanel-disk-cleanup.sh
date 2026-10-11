#!/usr/bin/env bash
#
# cpanel-disk-cleanup.sh v2.0 - safe, interactive disk cleanup for cPanel/WHM servers
# Tested on AlmaLinux 8 with cPanel, JetBackup 5 and Imunify360. Should work on
# other EL8/EL9 cPanel servers (Rocky Linux, CloudLinux).
#
# Author  : Fariduzzaman
# License : MIT
#
# How it works
#   1. Scan      : measures every known junk location and prints a report.
#                  Nothing is changed in this phase.
#   2. Safe      : routine junk (old rotated logs, package cache, journal,
#                  oversized live system logs) is cleaned together after ONE "y".
#   3. Sensitive : anything that is a backup, a user's data, a database or a
#                  package removal is asked about ONE ITEM AT A TIME.
#
# Usage
#   bash cpanel-disk-cleanup.sh                  scan + interactive cleanup
#   bash cpanel-disk-cleanup.sh --report         scan only, change nothing
#   bash cpanel-disk-cleanup.sh --log-days 30    keep rotated logs 30 days (default 14)
#   bash cpanel-disk-cleanup.sh --help
#
# Never touched: /home/virtfs (jailshell bind mounts of real system files),
# raw files under /var/lib/mysql, /usr/tmpDSK (backing file of /tmp),
# live mail, and anything outside the locations listed in this script.
#
# Output
#   Report  : /root/disk-cleanup-reports/report-<date>.txt
#   Actions : /var/log/cpanel-disk-cleanup.log (every deleted/truncated path)

set -uo pipefail
export LC_ALL=C

VERSION="2.0"

# ---- tunables -------------------------------------------------------------
LOG_DAYS=14             # rotated logs in /var/log older than this are junk
APACHE_DAYS=30          # rotated modsec logs + apache log archive
MODSEC_DIR_DAYS=7       # per-request files in /var/log/apache2/modsec_audit
CPANEL_LOG_DAYS=30      # /var/cpanel/updatelogs, /usr/local/cpanel/logs/archive
JOURNAL_MAX="200M"      # systemd journal is trimmed to this
TRUNCATE_OVER_MB=100    # live system logs bigger than this are emptied
HOME_ERRLOG_OVER_MB=50  # users' PHP error_log bigger than this is offered
TRASH_OVER_MB=10        # users' .trash bigger than this is offered
BIG_FILE_MB=500         # report files on / bigger than this
KEEP_KERNELS=2          # newest kernels kept (running kernel is always kept)
BINLOG_KEEP_DAYS=3      # MySQL binary logs newer than this are kept

LIVE_LOGS=(
  /var/log/chkservd.log
  /usr/local/cpanel/logs/error_log
  /usr/local/cpanel/logs/tailwatchd_log
  /usr/local/cpanel/logs/queueprocd.log
  /var/log/apache2/error_log
  /var/log/apache2/modsec_audit.log
)

JB_DOWNLOADS="/usr/local/jetapps/usr/jetbackup5/downloads"
EXIMSTATS_DB="/var/cpanel/eximstats_db.sqlite3"

REPORT_ONLY=0
STAMP="$(date +%Y%m%d-%H%M%S)"
REPORT_DIR="/root/disk-cleanup-reports"
REPORT_FILE="$REPORT_DIR/report-$STAMP.txt"
ACTION_LOG="/var/log/cpanel-disk-cleanup.log"
LOCK_FILE="/run/cpanel-disk-cleanup.lock"

# ---- output helpers -------------------------------------------------------
if [[ -t 1 ]]; then
  B=$'\e[1m'; R=$'\e[31m'; G=$'\e[32m'; Y=$'\e[33m'; C=$'\e[36m'; D=$'\e[2m'; N=$'\e[0m'
else
  B=""; R=""; G=""; Y=""; C=""; D=""; N=""
fi

out()      { printf '%s\n' "$*"; printf '%s\n' "$*" | sed 's/\x1b\[[0-9;]*m//g' >> "$REPORT_FILE"; }
warn()     { out "${Y}! $*${N}"; }
progress() { printf '%s\n' "${D}  ... $*${N}" >&2; }
logact()   { printf '%s %s\n' "$(date '+%F %T')" "$*" >> "$ACTION_LOG"; }
human()    { numfmt --to=iec --suffix=B --format='%.1f' "${1:-0}" 2>/dev/null || printf '%sB' "${1:-0}"; }
die()      { printf '%s\n' "${R}ERROR: $*${N}" >&2; exit 1; }

# ---- layout: centered, bordered headers -----------------------------------
W=78
if [[ -t 1 ]] && command -v tput >/dev/null 2>&1; then
  W=$(( $(tput cols 2>/dev/null || echo 80) - 2 ))
fi
(( W > 96 )) && W=96
(( W < 60 )) && W=60
IW=$(( W - 2 ))   # width inside the borders

rep() { local i s=""; for (( i=0; i<$2; i++ )); do s+="$1"; done; printf '%s' "$s"; }

# box_center TEXT LEFT_BORDER RIGHT_BORDER [STYLE]
box_center() {
  local t="${1:0:$IW}" l r
  l=$(( (IW - ${#t}) / 2 )); r=$(( IW - ${#t} - l ))
  out "${C}$2${N}$(printf '%*s' "$l" '')${4:-}${t}${N}$(printf '%*s' "$r" '')${C}$3${N}"
}
# box_left TEXT LEFT_BORDER RIGHT_BORDER
box_left() {
  local t="${1:0:$((IW - 3))}" r
  r=$(( IW - 2 - ${#t} ))
  out "${C}$2${N}  ${t}$(printf '%*s' "$r" '')${C}$3${N}"
}
box_rule() { out "${C}$1$(rep "$2" "$IW")$3${N}"; }

hdr() {
  local t="$*"
  out ""
  box_rule "╔" "═" "╗"
  box_center "${t^^}" "║" "║" "$B"
  box_rule "╚" "═" "╝"
}

banner_title() {
  box_rule "╔" "═" "╗"
  box_center "" "║" "║"
  box_center "SERVER DISK CLEANUP   v$VERSION" "║" "║" "$B"
  box_center "cPanel Server Storage Analysis & Cleanup" "║" "║"
  box_center "" "║" "║"
}
banner_credit() {
  box_rule "╠" "═" "╣"
  box_center "Created by Fariduzzaman" "║" "║" "$B"
  box_center "Open source  -  MIT License" "║" "║"
  box_rule "╚" "═" "╝"
}
banner() {
  local mode="Interactive cleanup"
  (( REPORT_ONLY )) && mode="Report only (nothing will be changed)"
  out ""
  banner_title
  box_rule "╠" "═" "╣"
  box_left "Host  : $(hostname)" "║" "║"
  box_left "Date  : $(date '+%d %b %Y, %H:%M:%S')" "║" "║"
  box_left "Mode  : $mode" "║" "║"
  banner_credit
}

# final_box TITLE STYLE "label|value" ...
final_box() {
  local title="$1" style="$2" kv; shift 2
  out ""
  box_rule "╔" "═" "╗"
  box_center "$title" "║" "║" "$style"
  box_rule "╠" "═" "╣"
  for kv in "$@"; do box_left "$(printf '%-12s: %s' "${kv%%|*}" "${kv#*|}")" "║" "║"; done
  box_rule "╚" "═" "╝"
  out ""
}

sum_of()  { "$@" -printf '%s\n' 2>/dev/null | awk '{s+=$1} END{printf "%.0f\n", s}'; }
fsize()   { stat -c %s -- "$1" 2>/dev/null || echo 0; }
dirsize() { du -sb -- "$1" 2>/dev/null | awk '{print $1+0}'; }
root_avail() { df -B1 --output=avail / | tail -1 | tr -d ' '; }

# ---- safety guard ---------------------------------------------------------
is_protected() {
  local p
  p="$(readlink -f -- "$1" 2>/dev/null)" || return 0
  case "$p" in
    ""|/|/home|/root|/var|/var/log|/usr|/usr/local|/etc|/boot) return 0 ;;
    /home/virtfs|/home/virtfs/*)       return 0 ;;
    /var/lib/mysql|/var/lib/mysql/*)   return 0 ;;
    /usr/tmpDSK)                       return 0 ;;
    /etc/*|/boot/*)                    return 0 ;;
  esac
  return 1
}

safe_rm() {
  local f
  for f in "$@"; do
    if is_protected "$f"; then warn "refused protected path: $f"; logact "REFUSED $f"; continue; fi
    rm -rf -- "$f" && logact "DELETED $f"
  done
}

# ---- prompt ---------------------------------------------------------------
# returns 0=yes 1=no 2=yes to all remaining in group 3=skip rest of group
ask() {
  local prompt="$1" mode="${2:-yn}" reply hint="[y/N]"
  [[ $mode == group ]] && hint="[y/N/a=all in group/q=skip group]"
  while true; do
    read -r -p "    $prompt $hint: " reply </dev/tty || return 1
    case "${reply,,}" in
      y|yes)   return 0 ;;
      ""|n|no) return 1 ;;
      a|all)   [[ $mode == group ]] && return 2 ;;
      q|quit)  [[ $mode == group ]] && return 3 ;;
    esac
  done
}

# ---- item registries ------------------------------------------------------
S_NAME=(); S_BYTES=(); S_FUNC=(); S_ARG=()
add_safe() {
  (( ${2:-0} > 0 )) || return 0
  S_NAME+=("$1"); S_BYTES+=("$2"); S_FUNC+=("$3"); S_ARG+=("${4:-}")
}

X_GROUP=(); X_NAME=(); X_BYTES=(); X_FUNC=(); X_ARG=(); X_NOTE=()
add_sens() {
  X_GROUP+=("$1"); X_NAME+=("$2"); X_BYTES+=("${3:-0}"); X_FUNC+=("$4"); X_ARG+=("${5:-}"); X_NOTE+=("${6:-}")
}

# ---- find definitions (shared by size scan and delete) --------------------
find_rotated() {
  find /var/log -xdev \( -path /var/log/apache2 -o -path /var/log/journal \) -prune -o \
    -type f -mtime +"$LOG_DAYS" \
    \( -name '*-20[0-9][0-9][0-1][0-9][0-3][0-9]' -o -name '*-20[0-9][0-9][0-1][0-9][0-3][0-9].gz' \
       -o -name '*.[0-9]' -o -name '*.[0-9].gz' -o -name '*.[0-9][0-9].gz' -o -name '*.gz' \) "$@"
}
find_modsec_rot()   { find /var/log/apache2 -maxdepth 1 -type f -name 'modsec_audit.log-*' -mtime +"$APACHE_DAYS" "$@"; }
find_apache_arch()  { find /var/log/apache2/archive -type f -mtime +"$APACHE_DAYS" "$@"; }
find_modsec_dir()   { find /var/log/apache2/modsec_audit -type f -mtime +"$MODSEC_DIR_DAYS" "$@"; }
find_updatelogs()   { find /var/cpanel/updatelogs -type f -mtime +"$CPANEL_LOG_DAYS" "$@"; }
find_cp_archive()   { find /usr/local/cpanel/logs/archive -type f -mtime +"$CPANEL_LOG_DAYS" "$@"; }

# ---- clean actions --------------------------------------------------------
clean_dnf()      { dnf -q clean all >/dev/null 2>&1 && logact "dnf clean all"; }
clean_journal()  { journalctl --vacuum-size="$JOURNAL_MAX" >/dev/null 2>&1 && logact "journalctl vacuum $JOURNAL_MAX"; }
clean_find()     { "$1" -print -delete 2>/dev/null | while IFS= read -r f; do logact "DELETED $f"; done; }
clean_modsec_dir() {
  clean_find find_modsec_dir
  find /var/log/apache2/modsec_audit -mindepth 1 -type d -empty -delete 2>/dev/null
}
clean_path()     { safe_rm "$1"; }
clean_truncate() {
  if is_protected "$1"; then warn "refused protected path: $1"; return; fi
  truncate -s 0 -- "$1" && logact "TRUNCATED $1"
}
clean_dircontents() {
  if is_protected "$1"; then warn "refused protected path: $1"; return; fi
  find "$1" -mindepth 1 -delete 2>/dev/null; logact "EMPTIED $1"
}
clean_kernels() {
  dnf -y -q --disablerepo='*' remove "${OLDK[@]}" && logact "REMOVED kernels: ${OLDK[*]}"
}
clean_eximstats() {
  local dbsz tmpd
  dbsz=$(fsize "$EXIMSTATS_DB")
  if (( $(root_avail) < dbsz + 1073741824 )); then
    warn "Not enough free space on / for VACUUM (needs about $(human $((dbsz + 1073741824)))). Skipped."
    return
  fi
  tmpd="/home/.cpanel-disk-cleanup-sqlite-tmp"; mkdir -p "$tmpd"; chmod 700 "$tmpd"
  out "    stopping eximstats, running VACUUM (can take several minutes) ..."
  /usr/local/cpanel/scripts/restartsrv_eximstats --stop >/dev/null 2>&1
  if SQLITE_TMPDIR="$tmpd" sqlite3 "$EXIMSTATS_DB" 'VACUUM;'; then
    logact "VACUUM $EXIMSTATS_DB"
  else
    warn "VACUUM failed; database left as it was."
  fi
  /usr/local/cpanel/scripts/restartsrv_eximstats --start >/dev/null 2>&1
  rm -rf -- "$tmpd"
  out "    eximstats DB is now $(human "$(fsize "$EXIMSTATS_DB")")"
}
clean_binlog() {
  mysql -e "PURGE BINARY LOGS BEFORE NOW() - INTERVAL $BINLOG_KEEP_DAYS DAY;" && logact "PURGE BINARY LOGS older than $BINLOG_KEEP_DAYS days"
}

# ---- scans ----------------------------------------------------------------
scan_safe() {
  local b j max d u f
  progress "package cache, journal, logs"

  b=$(dirsize /var/cache/dnf)
  add_safe "DNF package cache (/var/cache/dnf)" "$b" clean_dnf

  j=0
  for d in /var/log/journal /run/log/journal; do [[ -d $d ]] && j=$(( j + $(dirsize "$d") )); done
  max=$(numfmt --from=iec "$JOURNAL_MAX")
  (( j > max )) && add_safe "systemd journal, trimmed to $JOURNAL_MAX" $(( j - max )) clean_journal

  add_safe "Rotated logs in /var/log older than $LOG_DAYS days" "$(sum_of find_rotated)" clean_find find_rotated

  for u in /var/log/*.uninstall; do
    [[ -d $u ]] && add_safe "Leftover logs of an uninstalled package ($u)" "$(dirsize "$u")" clean_path "$u"
  done

  add_safe "Rotated ModSecurity logs older than $APACHE_DAYS days" "$(sum_of find_modsec_rot)" clean_find find_modsec_rot
  add_safe "Apache log archive older than $APACHE_DAYS days"       "$(sum_of find_apache_arch)" clean_find find_apache_arch
  add_safe "ModSecurity per-request files older than $MODSEC_DIR_DAYS days" "$(sum_of find_modsec_dir)" clean_modsec_dir
  add_safe "cPanel update logs older than $CPANEL_LOG_DAYS days"    "$(sum_of find_updatelogs)" clean_find find_updatelogs
  add_safe "cPanel log archive older than $CPANEL_LOG_DAYS days"    "$(sum_of find_cp_archive)" clean_find find_cp_archive

  for f in "${LIVE_LOGS[@]}"; do
    [[ -f $f ]] || continue
    b=$(fsize "$f")
    (( b > TRUNCATE_OVER_MB * 1048576 )) && add_safe "Empty oversized live log $f" "$b" clean_truncate "$f"
  done
}

OLDK=()
scan_sensitive() {
  local f b t s running kb dbsz fl ps replicas
  # JetBackup download archives
  if [[ -d $JB_DOWNLOADS ]]; then
    progress "JetBackup downloads"
    while IFS= read -r -d '' f; do
      add_sens "JetBackup download archives" "$(basename "$f")  (made $(date -r "$f" +%F))" "$(fsize "$f")" clean_path "$f" \
        "Copies created by the 'Download' button in JetBackup. The real backups stay in the backup destination."
    done < <(find "$JB_DOWNLOADS" -type f -print0 2>/dev/null)
  fi

  # account transfer leftovers
  for f in /root/cpmove-* /home/cpmove-*; do
    [[ -e $f ]] || continue
    add_sens "Account transfer files (cpmove)" "$f  (made $(date -r "$f" +%F))" "$(dirsize "$f")" clean_path "$f" \
      "Left over from account transfers. Delete only if the transfer finished and the account works."
  done

  # old kernels
  progress "kernels"
  running="$(uname -r)"
  mapfile -t OLDK < <(dnf -q --disablerepo='*' repoquery --installonly --latest-limit=-"$KEEP_KERNELS" 2>/dev/null \
                       | grep -vF -- "$running" | sed 's/-[0-9]*:/-/')
  if (( ${#OLDK[@]} > 0 )); then
    kb=$(rpm -q --qf '%{SIZE}\n' "${OLDK[@]}" 2>/dev/null | awk '{s+=$1} END{printf "%.0f", s}')
    add_sens "Old kernels" "$(printf '%s\n' "${OLDK[@]}" | grep -o '[0-9]\+\.[0-9]\+\.[0-9]\+-[0-9.]*el[0-9_]*' | sort -u | paste -sd' ')" \
      "$kb" clean_kernels "" "Running kernel $running and the newest $KEEP_KERNELS are kept."
  fi

  # Exim stats database
  if [[ -f $EXIMSTATS_DB ]] && command -v sqlite3 >/dev/null 2>&1; then
    dbsz=$(fsize "$EXIMSTATS_DB")
    if (( dbsz > 1073741824 )); then
      fl=$(sqlite3 "$EXIMSTATS_DB" 'PRAGMA freelist_count;' 2>/dev/null || echo 0)
      ps=$(sqlite3 "$EXIMSTATS_DB" 'PRAGMA page_size;' 2>/dev/null || echo 0)
      add_sens "Exim stats database" "VACUUM $EXIMSTATS_DB (file is $(human "$dbsz"); size shown is what VACUUM can free right now)" \
        "$(( ${fl:-0} * ${ps:-0} ))" clean_eximstats "" \
        "First lower WHM > Tweak Settings > Stats and Logs > Exim stats retention and wait one night for the purge; otherwise VACUUM frees little. Mail stats pages pause while it runs."
    fi
  fi

  # MySQL binary logs
  if command -v mysql >/dev/null 2>&1 && [[ "$(mysql -NBe 'SELECT @@log_bin' 2>/dev/null)" == "1" ]]; then
    b=$(mysql -NBe 'SHOW BINARY LOGS' 2>/dev/null | awk '{s+=$2} END{printf "%.0f", s}')
    replicas=$(mysql -NBe 'SHOW SLAVE HOSTS' 2>/dev/null | wc -l)
    if (( ${b:-0} > 0 )); then
      local note="Purged through MySQL, never by deleting files."
      (( replicas > 0 )) && note="$note A replica is connected: make sure it is caught up first."
      add_sens "MySQL binary logs" "PURGE BINARY LOGS older than $BINLOG_KEEP_DAYS days (all binlogs together: $(human "$b"))" \
        "$b" clean_binlog "" "$note"
    fi
  fi

  # users' trash and softaculous backups (on /home)
  progress "users' trash and Softaculous backups"
  for t in /home/*/.trash; do
    [[ -d $t && $t != /home/virtfs/* ]] || continue
    b=$(dirsize "$t")
    (( b > TRASH_OVER_MB * 1048576 )) || continue
    add_sens "Users' File Manager trash (on /home)" "${t#/home/}" "$b" clean_dircontents "$t" \
      "Files users already deleted in cPanel File Manager. This frees /home, not the root partition."
  done
  for s in /home/*/softaculous_backups; do
    [[ -d $s && $s != /home/virtfs/* ]] || continue
    b=$(dirsize "$s"); (( b > 0 )) || continue
    add_sens "Softaculous backups (on /home)" "${s#/home/}" "$b" clean_dircontents "$s" \
      "Site backups made by Softaculous. Ask the client if they still need them."
  done

  # big PHP error_log files in user sites
  progress "large error_log files under /home (can take a few minutes)"
  while IFS= read -r -d '' f; do
    add_sens "Large PHP error_log in user sites (on /home)" "${f#/home/}" "$(fsize "$f")" clean_truncate "$f" \
      "Emptied, not deleted, so the site keeps logging. A huge error_log usually means a broken plugin worth fixing."
  done < <(find /home -xdev \( -path /home/virtfs -o -path '/home/*/mail' -o -path '/home/*/.trash' \) -prune -o \
             -type f -name error_log -size +"${HOME_ERRLOG_OVER_MB}"M -print0 2>/dev/null)
}

# ---- report-only findings -------------------------------------------------
report_findings() {
  local line size date path tag bsz qc ml

  hdr "Biggest folders on / (root partition)"
  du -xh --max-depth=1 / 2>/dev/null | sort -h | tail -12 | while IFS= read -r line; do out "  $line"; done

  hdr "Files over ${BIG_FILE_MB}M on /"
  find / -xdev -type f -size +"${BIG_FILE_MB}"M -printf '%s\t%TY-%Tm-%Td\t%p\n' 2>/dev/null | sort -rn | head -15 |
  while IFS=$'\t' read -r size date path; do
    tag=""
    case "$path" in
      /usr/tmpDSK)          tag="${G}(backing file of /tmp, keep)${N}" ;;
      /var/lib/mysql/*)     tag="${G}(database, keep)${N}" ;;
      "$JB_DOWNLOADS"/*)    tag="(offered below)" ;;
      "$EXIMSTATS_DB")      tag="(offered below)" ;;
    esac
    out "  $(human "$size")  $date  $path $tag"
  done

  if [[ -d /backup && "$(stat -c %d /backup)" == "$(stat -c %d /)" ]]; then
    bsz=$(dirsize /backup)
    if (( bsz > 1073741824 )); then
      hdr "Backups on the root partition"
      warn "/backup holds $(human "$bsz") on the root partition. Point WHM > Backup Configuration (and JetBackup destinations) to a folder on /home."
    fi
  fi

  if command -v lsof >/dev/null 2>&1; then
    hdr "Deleted files still held open (space not yet freed)"
    lsof -nP +L1 2>/dev/null | awk 'NR>1 && $7 ~ /^[0-9]+$/ && $7 > 104857600 {print $7"\t"$1"\t"$2"\t"$NF}' | sort -rn | head -10 > /tmp/.cpanel_disk_cleanup_lsof.$$
    if [[ -s /tmp/.cpanel_disk_cleanup_lsof.$$ ]]; then
      while IFS=$'\t' read -r size cmd pid path; do out "  $(human "$size")  $cmd (pid $pid)  $path"; done < /tmp/.cpanel_disk_cleanup_lsof.$$
      out "  Restart the listed service to release this space."
    else
      out "  none over 100M"
    fi
    rm -f /tmp/.cpanel_disk_cleanup_lsof.$$
  fi

  if command -v exim >/dev/null 2>&1; then
    hdr "Mail health"
    qc=$(exim -bpc 2>/dev/null || echo "?")
    ml=$(fsize /var/log/exim_mainlog)
    out "  Mail queue: $qc messages    Current exim_mainlog: $(human "$ml")"
    [[ $qc =~ ^[0-9]+$ ]] && (( qc > 1000 )) && warn "Large mail queue. Possible spam from a hacked account or script."
    (( ml > 209715200 )) && warn "exim_mainlog is very large for one week. Check for spam."
    out "  Top script folders sending mail (current log):"
    grep -o 'cwd=/home[^ ]*' /var/log/exim_mainlog 2>/dev/null | sort | uniq -c | sort -rn | head -5 |
      while IFS= read -r line; do out "    $line"; done
    out "  Top authenticated senders (current log):"
    grep -o 'A=dovecot_[a-z]*:[^ ]*' /var/log/exim_mainlog 2>/dev/null | sort | uniq -c | sort -rn | head -5 |
      while IFS= read -r line; do out "    $line"; done
  fi
}

# ---- report tables --------------------------------------------------------
print_plan() {
  local i total=0 g prev=""
  hdr "SAFE items (cleaned together after one confirmation)"
  if (( ${#S_NAME[@]} == 0 )); then out "  nothing to clean"; fi
  for i in "${!S_NAME[@]}"; do
    out "$(printf '  %10s  %s' "$(human "${S_BYTES[i]}")" "${S_NAME[i]}")"
    total=$(( total + S_BYTES[i] ))
  done
  (( ${#S_NAME[@]} > 0 )) && out "$(printf '  %10s  %s' "$(human "$total")" "${B}total${N}")"

  total=0
  hdr "SENSITIVE items (asked one by one)"
  if (( ${#X_NAME[@]} == 0 )); then out "  nothing found"; fi
  for i in "${!X_NAME[@]}"; do
    g="${X_GROUP[i]}"
    if [[ $g != "$prev" ]]; then out "  ${B}$g${N}"; prev="$g"; fi
    out "$(printf '    %10s  %s' "$(human "${X_BYTES[i]}")" "${X_NAME[i]}")"
    total=$(( total + X_BYTES[i] ))
  done
  (( ${#X_NAME[@]} > 0 )) && out "$(printf '    %10s  %s' "$(human "$total")" "${B}total if all approved${N}")"
}

# ---- cleanup phases -------------------------------------------------------
run_safe() {
  local i total=0
  (( ${#S_NAME[@]} > 0 )) || return 0
  for i in "${!S_BYTES[@]}"; do total=$(( total + S_BYTES[i] )); done
  hdr "Phase 2: safe cleanup"
  if ask "Clean all ${#S_NAME[@]} safe items ($(human "$total"))?"; then
    for i in "${!S_NAME[@]}"; do
      out "  ${G}cleaning${N} ${S_NAME[i]}"
      "${S_FUNC[i]}" "${S_ARG[i]}"
    done
  else
    out "  safe items skipped"
  fi
}

run_sensitive() {
  local i g prev="" mode="ask" rc
  (( ${#X_NAME[@]} > 0 )) || return 0
  hdr "Phase 3: sensitive items, one by one"
  for i in "${!X_NAME[@]}"; do
    g="${X_GROUP[i]}"
    if [[ $g != "$prev" ]]; then
      prev="$g"; mode="ask"
      out ""; out "  ${B}$g${N}"
      [[ -n ${X_NOTE[i]} ]] && out "  ${D}${X_NOTE[i]}${N}"
    fi
    [[ $mode == skip ]] && continue
    out "  - $(human "${X_BYTES[i]}")  ${X_NAME[i]}"
    if [[ $mode == all ]]; then rc=0; else ask "Remove this?" group; rc=$?; fi
    case $rc in
      0) "${X_FUNC[i]}" "${X_ARG[i]}"; out "    ${G}done${N}" ;;
      2) mode="all"; "${X_FUNC[i]}" "${X_ARG[i]}"; out "    ${G}done${N}" ;;
      3) mode="skip"; out "    rest of this group skipped" ;;
      *) out "    skipped" ;;
    esac
  done
}

# ---- main -----------------------------------------------------------------
usage() {
  local me; me="$(basename "$0")"
  REPORT_FILE=/dev/null          # help is screen-only, no report file
  out ""
  banner_title
  banner_credit

  hdr "How it works"
  out "  ${B}1  SCAN${N}        Measures every known junk location and prints a report."
  out "                 Nothing is changed in this phase."
  out "  ${B}2  SAFE${N}        Old rotated logs, package cache, journal and oversized"
  out "                 system logs are cleaned together after ONE \"y\"."
  out "  ${B}3  SENSITIVE${N}   Backups, user data, databases and package removals are"
  out "                 asked about ONE ITEM AT A TIME."

  hdr "Usage"
  out "$(printf '  %b%-42s%b %s' "$G" "bash $me" "$N" "Scan + interactive cleanup")"
  out "$(printf '  %b%-42s%b %s' "$G" "bash $me --report" "$N" "Scan only, change nothing")"
  out "$(printf '  %b%-42s%b %s' "$G" "bash $me --log-days 30" "$N" "Keep rotated logs 30 days (default $LOG_DAYS)")"
  out "$(printf '  %b%-42s%b %s' "$G" "bash $me --help" "$N" "Show this help")"

  hdr "Answer keys (sensitive items)"
  out "  ${B}y${N}  remove this item          ${B}N${N}  keep it (default, just press Enter)"
  out "  ${B}a${N}  remove all in this group  ${B}q${N}  skip the rest of this group"

  hdr "Never touched"
  out "  - /home/virtfs        jailshell bind mounts of real system files"
  out "  - /var/lib/mysql      raw database files (binlogs only via MySQL PURGE)"
  out "  - /usr/tmpDSK         backing file of /tmp"
  out "  - /etc, /boot         system configuration and boot files"
  out "  - Live mail, and anything outside the locations listed in this script"

  hdr "Output"
  out "  Report      : $REPORT_DIR/report-<date>.txt"
  out "  Action log  : $ACTION_LOG  (every deleted / truncated path)"
  out ""
  exit 0
}

main() {
  while (( $# )); do
    case "$1" in
      --report|-r)  REPORT_ONLY=1 ;;
      --log-days)   shift; [[ ${1:-} =~ ^[0-9]+$ ]] || die "--log-days needs a number"; LOG_DAYS="$1" ;;
      --help|-h)    usage ;;
      *)            die "unknown option: $1 (see --help)" ;;
    esac
    shift
  done

  [[ $EUID -eq 0 ]] || die "run as root"
  exec 9>"$LOCK_FILE"; flock -n 9 || die "another cleanup is already running"
  mkdir -p "$REPORT_DIR" && chmod 700 "$REPORT_DIR"
  : > "$REPORT_FILE"; touch "$ACTION_LOG"

  local before after
  before=$(root_avail)

  banner
  [[ -d /usr/local/cpanel ]] || warn "cPanel not found; cPanel-specific locations will simply be empty."
  hdr "Disk usage"
  df -h / /home /boot /tmp 2>/dev/null | while IFS= read -r line; do out "  $line"; done

  out ""; out "Scanning (nothing is changed yet)..."
  scan_safe
  scan_sensitive
  report_findings
  print_plan

  if (( REPORT_ONLY )); then
    final_box "REPORT COMPLETE  -  NOTHING WAS CHANGED" "$B$G" \
      "Root free|$(human "$before")" \
      "Report|$REPORT_FILE" \
      "Next step|bash $0  (interactive cleanup)"
    exit 0
  fi
  [[ -r /dev/tty ]] || die "no terminal for confirmations; run interactively or use --report"

  logact "=== run started by $(logname 2>/dev/null || echo root) ==="
  run_safe
  run_sensitive

  after=$(root_avail)
  hdr "Disk usage after cleanup"
  df -h / /home 2>/dev/null | while IFS= read -r line; do out "  $line"; done
  final_box "CLEANUP COMPLETE" "$B$G" \
    "Freed on /|$(human $(( after > before ? after - before : 0 )))" \
    "Root free|$(human "$after")" \
    "Report|$REPORT_FILE" \
    "Action log|$ACTION_LOG"
  logact "=== run finished, root freed $(( after > before ? after - before : 0 )) bytes ==="
}

main "$@"
