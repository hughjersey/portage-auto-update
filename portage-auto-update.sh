#!/bin/bash
# Nightly @world update -- runs as root from a timer or cron
# Settings are in /etc/portage-auto-update.conf
# Based on gentoo-portage-update -- https://git.tghost.co.uk/bratch-git/gentoo-portage-update/

set -o pipefail

CONFIG=/etc/portage-auto-update.conf
CONFIG_GIVEN=no
CHECK_ONLY=no
ORIG_ARGS=("$@")
CLI_SKIPS=()
CLI_EXCLUDE=""

NICE_MAKEOPTS=""
SAFE_SERVICES="sshd"
EXCLUDE_LIST=""
EMERGE_BACKTRACK=100
SYNC_TIMEOUT=1800
LOG_DIR=/var/log/portage-auto-update
LOG_KEEP_DAYS=30
TMP_KEEP_DAYS=3
LOCK_FILE=/run/lock/portage-auto-update.lock
NOTIFY_USER=""
NOTIFY_METHOD=auto
SKIP_SYNC=no
SKIP_NEWS=no
SKIP_UPDATE=no
SKIP_DEPCLEAN=no
SKIP_PRESERVED_REBUILD=no
SKIP_REVDEP=no
SKIP_PERL_CLEANER=no
SKIP_ECLEAN=no
SKIP_ETC_UPDATE=no

# Handle arguments
while [ $# -gt 0 ]; do
    case "$1" in
        --check) CHECK_ONLY=yes ;;
        --config)
            CONFIG="$2"
            CONFIG_GIVEN=yes
            shift
            ;;
        # Followed by a list of packages as a single argument to pass to emerge --exclude
        # for @world and -9999 updates, e.g. --exclude "app-editors/nano media-gfx/blender"
        --exclude)
            CLI_EXCLUDE="$2"
            shift
            ;;
        --skip-sync) CLI_SKIPS+=(SKIP_SYNC) ;;
        --skip-news) CLI_SKIPS+=(SKIP_NEWS) ;;
        --skip-update) CLI_SKIPS+=(SKIP_UPDATE) ;;
        --skip-depclean) CLI_SKIPS+=(SKIP_DEPCLEAN) ;;
        --skip-preserved-rebuild) CLI_SKIPS+=(SKIP_PRESERVED_REBUILD) ;;
        --skip-revdep) CLI_SKIPS+=(SKIP_REVDEP) ;;
        --skip-perl-cleaner) CLI_SKIPS+=(SKIP_PERL_CLEANER) ;;
        --skip-eclean) CLI_SKIPS+=(SKIP_ECLEAN) ;;
        --skip-etc-update) CLI_SKIPS+=(SKIP_ETC_UPDATE) ;;
        *)
            echo "bad argument '$1'"
            exit 1
            ;;
    esac
    shift
done

load_config() {
    if [ ! -e "$CONFIG" ]; then
        if [ "$CONFIG_GIVEN" = yes ]; then
            echo "no such config: $CONFIG" >&2
            exit 1
        fi
        return 0
    fi

    if [ ! -r "$CONFIG" ]; then
        if [ "$CHECK_ONLY" = yes ]; then
            echo "can't read $CONFIG, checking against the defaults"
            return 0
        fi
        echo "can't read $CONFIG" >&2
        exit 1
    fi

    if [ "$(id -u)" -eq 0 ]; then
        local owner mode
        read -r owner mode < <(stat -c '%u %a' "$CONFIG")
        # Root runs this file, so only root should be able to write to it
        if [ "$owner" -ne 0 ] || (( 8#$mode & 8#022 )); then
            echo "refusing $CONFIG: must be root owned and not group/world writable" >&2
            exit 1
        fi
    fi

    # shellcheck disable=SC1090
    . "$CONFIG"
}

detect_init() {
    if [ -d /run/systemd/system ]; then
        echo systemd
    elif command -v rc-service >/dev/null; then
        echo openrc
    fi
}

svc_active() {
    case "$INIT" in
        systemd) systemctl is-active --quiet "$1" 2>/dev/null ;;
        openrc) rc-service "$1" status >/dev/null 2>&1 ;;
    esac
}

svc_restart() {
    case "$INIT" in
        systemd) systemctl restart "$1" ;;
        openrc) rc-service "$1" restart ;;
    esac
}

check_prereqs() {
    local verbose=$1 line tool pkg found=no
    local prereqs=(
        "emerge sys-apps/portage"
        "emaint sys-apps/portage"
        "portageq sys-apps/portage"
        "etc-update sys-apps/portage"
        "eselect app-admin/eselect"
        "qlist app-portage/portage-utils"
        "lsof sys-process/lsof"
        "pgrep sys-process/procps"
        "flock sys-apps/util-linux"
    )
    local missing=()

    [ "$SKIP_REVDEP" = yes ] || prereqs+=("revdep-rebuild app-portage/gentoolkit")
    [ "$SKIP_ECLEAN" = yes ] || prereqs+=("eclean-dist app-portage/gentoolkit")
    [ "$SKIP_PERL_CLEANER" = yes ] || prereqs+=("perl-cleaner app-admin/perl-cleaner")

    if [ ! -e /etc/gentoo-release ]; then
        echo "  MISSING  /etc/gentoo-release, this doesn't look like gentoo"
        return 1
    fi

    for line in "${prereqs[@]}"; do
        read -r tool pkg <<< "$line"
        if command -v "$tool" >/dev/null; then
            if [ "$verbose" = yes ]; then
                echo "  ok       $tool"
            fi
        else
            echo "  MISSING  $tool ($pkg)"
            missing+=("$pkg")
        fi
    done

    if [ -z "$(detect_init)" ]; then
        echo "  warning  no systemd or openrc, services won't get restarted"
    fi

    if [ -n "$NOTIFY_USER" ]; then
        id "$NOTIFY_USER" >/dev/null 2>&1 || echo "  warning  NOTIFY_USER $NOTIFY_USER doesn't exist"
        if [ "$NOTIFY_METHOD" = auto ]; then
            for tool in yad zenity xmessage notify-send; do
                command -v "$tool" >/dev/null && found=yes
            done
        elif command -v "$NOTIFY_METHOD" >/dev/null; then
            found=yes
        fi
        if [ "$found" = no ]; then
            echo "  warning  nothing to notify with, try: emerge --ask x11-apps/xmessage"
        fi
    fi

    if [ ${#missing[@]} -gt 0 ]; then
        echo "  install with: emerge --ask $(printf '%s\n' "${missing[@]}" | sort -u | tr '\n' ' ')"
        return 1
    fi
}

auto_sync_repos() {
    portageq repositories_configuration / 2>/dev/null | awk -F' *= *' '
        function flush() {
            if (name != "" && name != "DEFAULT" && tolower(auto) ~ /^(yes|true)$/ && type != "")
                print name
        }
        /^\[/ {
            flush()
            name = substr($0, 2, length($0) - 2)
            auto = ""
            type = ""
            next
        }
        $1 == "auto-sync" { auto = $2 }
        $1 == "sync-type" { type = $2 }
        END { flush() }
    '
}

run_step() {
    local name="$1"
    shift
    echo ""
    echo "--- Step: $name ---"
    echo "Running: $*"
    if "$@" 2>&1 | tee "$STAT_TMPFILE"; then
        COMPLETED+=("[OK] $name")
        echo "--- $name: SUCCESS ---"
        return 0
    fi
    FAILURES+=("[FAIL] $name")
    echo "--- $name: FAILED ---"
    return 1
}

emerge_total() {
    grep "^Total:" "$STAT_TMPFILE" | head -1 | sed -e 's/, Size of downloads:.*//' -e 's/^Total: //'
}

merged_list() {
    sed -n "s/.*>>> $1 ([0-9]* of [0-9]*) \([^ ]*\).*/\1/p" "$STAT_TMPFILE" | sed 's/::.*$//'
}

clean_portage_tmp() {
    local root
    root="$(portageq envvar PORTAGE_TMPDIR 2>/dev/null)/portage"

    echo ""
    echo "--- Step: Portage temp cleanup ---"
    case "$root" in
        /?*/portage) ;;
        *)
            FAILURES+=("[FAIL] Portage temp cleanup (odd path: $root)")
            return 1
            ;;
    esac
    if [ ! -d "$root" ]; then
        COMPLETED+=("[OK] Portage temp cleanup")
        return 0
    fi
    if pgrep -f 'bin/emerge( |$)' >/dev/null; then
        echo "emerge is running, leaving $root alone"
        COMPLETED+=("[OK] Portage temp cleanup (skipped, emerge running)")
        return 0
    fi

    # Checks the package dir not the files -- sources keep their old tarball dates
    find "$root" -mindepth 2 -maxdepth 2 -type d -not -path '*/.*' \
        -mtime +$((TMP_KEEP_DAYS - 1)) -print -exec rm -rf -- {} +
    find "$root" -mindepth 1 -maxdepth 1 -type d -not -path '*/.*' -empty -delete
    COMPLETED+=("[OK] Portage temp cleanup")
}

indent() {
    sed 's/^/  /'
}

print_items() {
    local empty=$1 item
    shift
    if [ $# -eq 0 ]; then
        echo "$empty"
        return
    fi
    for item in "$@"; do
        echo "$item"
    done
}

write_summary() {
    local hours=$((ELAPSED / 3600)) mins=$(( (ELAPSED % 3600) / 60 )) duration

    if [ "$hours" -gt 0 ]; then
        duration="${hours}h ${mins}m"
    else
        duration="${mins}m"
    fi

    echo "=== Portage Auto-Update Summary ==="
    echo "Date: $(date)"
    echo "Duration: $duration"
    echo ""
    echo "--- STATS ---"
    echo "Repos synced: ${STAT_REPOS_SYNCED}/${STAT_REPOS_TOTAL}"
    echo "Emerged: ${STAT_EMERGED:-0 packages}"
    if [ -n "$STAT_EMERGED_9999" ]; then
        echo "Live (-9999) rebuilt: $STAT_EMERGED_9999"
    fi
    echo "Depclean: ${STAT_DEPCLEAN:-0} packages removed"
    if [ -n "$STAT_DISTFILES" ]; then
        echo "Distfiles cleaned: $STAT_DISTFILES freed"
    else
        echo "Distfiles cleaned: 0"
    fi
    echo "Services restarted: $STAT_SERVICES_RESTARTED"
    echo ""
    echo "--- COMPLETED ---"
    print_items "(no steps completed)" "${COMPLETED[@]}"
    echo ""
    echo "--- FAILURES ---"
    print_items "(none)" "${FAILURES[@]}"
    echo ""
    echo "--- OUTSTANDING ---"
    print_items "(none)" "${OUTSTANDING[@]}"
    echo ""
    echo "--- PACKAGES ---"
    if [ -n "$STAT_EMERGED_LIST" ]; then
        echo "Emerged:"
        indent <<< "$STAT_EMERGED_LIST"
    fi
    if [ -n "$STAT_EMERGED_9999_LIST" ]; then
        echo "Live (-9999) rebuilt:"
        indent <<< "$STAT_EMERGED_9999_LIST"
    fi
    if [ -n "$STAT_DEPCLEAN_LIST" ]; then
        echo "Removed:"
        indent <<< "$STAT_DEPCLEAN_LIST"
    fi
    if [ -z "$STAT_EMERGED_LIST$STAT_EMERGED_9999_LIST$STAT_DEPCLEAN_LIST" ]; then
        echo "(no packages changed)"
    fi
    echo ""
    echo "Full log: $LOGFILE"
}

# Loads config file, overrides any default vars with custom user set values
load_config

for skip in "${CLI_SKIPS[@]}"; do
    printf -v "$skip" yes
done
if [ -n "$CLI_EXCLUDE" ]; then
    EXCLUDE_LIST="$CLI_EXCLUDE"
fi

if [ "$CHECK_ONLY" = yes ]; then
    check_prereqs yes
    exit $?
fi

if [ "$(id -u)" -ne 0 ]; then
    echo "needs root" >&2
    exit 1
fi

mkdir -p "$LOG_DIR"

# Let flock hold the lock -- otherwise gpg-agent etc inherit it and it never frees
if [ -z "$PORTAGE_AUTO_UPDATE_LOCKED" ]; then
    PORTAGE_AUTO_UPDATE_LOCKED=1 flock -n -o -E 75 "$LOCK_FILE" "$(readlink -f "$0")" "${ORIG_ARGS[@]}"
    rc=$?
    if [ "$rc" -eq 75 ]; then
        echo "$(date) already running, skipped" | tee -a "$LOG_DIR/skipped.log"
        exit 0
    fi
    exit "$rc"
fi

TIMESTAMP=$(date +%Y%m%d-%H%M%S)
LOGFILE="${LOG_DIR}/update-${TIMESTAMP}.log"
SUMMARY_FILE="${LOG_DIR}/latest-summary.txt"

exec > >(tee -a "$LOGFILE") 2>&1

START_TIME=$(date +%s)
echo "=== Portage Auto-Update started at $(date) ==="

if ! check_prereqs no; then
    echo "prereq check failed, not touching anything"
    exit 1
fi

if [ -n "$NICE_MAKEOPTS" ]; then
    export MAKEOPTS="$NICE_MAKEOPTS"
fi

# Don't hang all night on a git password
export GIT_TERMINAL_PROMPT=0

INIT=$(detect_init)

COMPLETED=()
FAILURES=()
OUTSTANDING=()
STAT_REPOS_SYNCED=0
STAT_REPOS_TOTAL=0
STAT_EMERGED=""
STAT_EMERGED_9999=""
STAT_DEPCLEAN=0
STAT_DISTFILES=""
STAT_SERVICES_RESTARTED=0
STAT_EMERGED_LIST=""
STAT_EMERGED_9999_LIST=""
STAT_DEPCLEAN_LIST=""
SYNC_FAILED=no
WORLD_FAILED=no

STAT_TMPFILE=$(mktemp)
trap 'rm -f "$STAT_TMPFILE"' EXIT

# Sync all repositories configured with auto-sync, unless skipped
if [ "$SKIP_SYNC" != yes ]; then
    echo ""
    echo "--- Step: Repository sync ---"
    mapfile -t REPOS < <(auto_sync_repos)
    SYNC_FAILURES=()

    if [ ${#REPOS[@]} -eq 0 ]; then
        STAT_REPOS_TOTAL=1
        if emaint sync --auto; then
            COMPLETED+=("[OK] Repository sync")
            STAT_REPOS_SYNCED=1
        else
            FAILURES+=("[FAIL] Repository sync")
            SYNC_FAILED=yes
        fi
    else
        STAT_REPOS_TOTAL=${#REPOS[@]}
        # One at a time so a dead overlay doesn't break the rest
        for repo in "${REPOS[@]}"; do
            echo ""
            echo "Syncing repository: $repo"
            if timeout "$SYNC_TIMEOUT" emaint sync --repo "$repo"; then
                echo "  $repo: OK"
            else
                echo "  $repo: FAILED (skipping)"
                SYNC_FAILURES+=("$repo")
            fi
        done

        STAT_REPOS_SYNCED=$((STAT_REPOS_TOTAL - ${#SYNC_FAILURES[@]}))

        if [ ${#SYNC_FAILURES[@]} -eq 0 ]; then
            COMPLETED+=("[OK] Repository sync (all repos)")
        elif [ "$STAT_REPOS_SYNCED" -eq 0 ]; then
            FAILURES+=("[FAIL] Repository sync (all repos failed: ${SYNC_FAILURES[*]})")
            SYNC_FAILED=yes
        else
            COMPLETED+=("[OK] Repository sync (partial)")
            OUTSTANDING+=("[!] Sync failed for repos: ${SYNC_FAILURES[*]}")
        fi
    fi
fi

# Check to see if there's any news, unless skipped
if [ "$SKIP_NEWS" != yes ]; then
    NEWS_COUNT=$(eselect news count new 2>/dev/null || echo 0)
    if [ "$NEWS_COUNT" -ne 0 ] 2>/dev/null; then
        echo "WARNING: $NEWS_COUNT unread news item(s)"
        OUTSTANDING+=("[!] $NEWS_COUNT unread news items - run: eselect news read")
    else
        echo "No unread news items."
    fi
fi

# Do a @world update, unless skipped or every repo failed to sync
if [ "$SKIP_UPDATE" != yes ] && [ "$SYNC_FAILED" = yes ]; then
    echo "All repos failed to sync, skipping @world."
    OUTSTANDING+=("[!] @world skipped, sync failed")
elif [ "$SKIP_UPDATE" != yes ]; then
    WORLD_CMD=(emerge --keep-going -v --update --newuse --deep --with-bdeps=y "--backtrack=$EMERGE_BACKTRACK")
    NINE_CMD=(emerge -1v --keep-going "--backtrack=$EMERGE_BACKTRACK")
    if [ -n "$EXCLUDE_LIST" ]; then
        WORLD_CMD+=(--exclude "$EXCLUDE_LIST")
        NINE_CMD+=(--exclude "$EXCLUDE_LIST")
    fi

    # emerge prints Total: even on failed runs, so only trust it if emerge worked
    if run_step "@world update" "${WORLD_CMD[@]}" @world; then
        STAT_EMERGED=$(emerge_total)
        STAT_EMERGED_LIST=$(merged_list Emerging)
    else
        WORLD_FAILED=yes
    fi

    # Update -9999 packages since they aren't included in a @world update
    mapfile -t PKGS_9999 < <(find /var/db/pkg/ -mindepth 2 -maxdepth 2 -name '*-9999' 2>/dev/null \
        | sed 's|^/var/db/pkg/|=|')
    if [ ${#PKGS_9999[@]} -gt 0 ]; then
        if run_step "Live (-9999) packages" "${NINE_CMD[@]}" "${PKGS_9999[@]}"; then
            STAT_EMERGED_9999=$(emerge_total)
            STAT_EMERGED_9999_LIST=$(merged_list Emerging)
        fi
    else
        echo "No -9999 packages found, skipping."
        COMPLETED+=("[OK] Live (-9999) packages (none installed)")
    fi
fi

# Remove unnecessary dependencies, unless skipped or @world failed
# Depclean after a half finished update can pull out things still needed
if [ "$SKIP_DEPCLEAN" != yes ] && [ "$WORLD_FAILED" = yes ]; then
    echo "@world failed, skipping depclean."
    OUTSTANDING+=("[!] depclean skipped, @world failed")
elif [ "$SKIP_DEPCLEAN" != yes ]; then
    run_step "depclean" emerge -v --keep-going --depclean
    STAT_DEPCLEAN=$(grep "^Number removed:" "$STAT_TMPFILE" | awk '{print $NF}')
    STAT_DEPCLEAN_LIST=$(merged_list Unmerging)
fi

# Rebuild any packages known to be built against old/missing packages, unless skipped
if [ "$SKIP_PRESERVED_REBUILD" != yes ]; then
    run_step "@preserved-rebuild" emerge -v --keep-going @preserved-rebuild
fi

# Search for any remaining packages built against old/missing packages, unless skipped
if [ "$SKIP_REVDEP" != yes ]; then
    run_step "revdep-rebuild" revdep-rebuild -- -v
fi

# Rebuild perl modules after a perl update, unless skipped
if [ "$SKIP_PERL_CLEANER" != yes ]; then
    run_step "perl-cleaner" perl-cleaner --all
fi

# Restart any defined safe-to-restart services that have open but deleted files
echo ""
echo "--- Step: Service restarts ---"
if [ -z "$INIT" ]; then
    echo "No systemd or openrc here, skipping."
    OUTSTANDING+=("[!] Services not checked, no known init system")
else
    DELETED=$(lsof -n 2>/dev/null | grep -E 'DEL|deleted')
    for service in $SAFE_SERVICES; do
        # lsof cuts names off at 9 chars
        if grep -Eq "^${service:0:9}\s+[0-9]" <<< "$DELETED" && svc_active "$service"; then
            echo "Restarting $service (has open deleted files)..."
            if svc_restart "$service"; then
                echo "  $service restarted successfully"
                STAT_SERVICES_RESTARTED=$((STAT_SERVICES_RESTARTED + 1))
            else
                FAILURES+=("[FAIL] Restart $service")
            fi
        fi
    done
    if [ "$STAT_SERVICES_RESTARTED" -eq 0 ]; then
        echo "No services needed restarting."
    fi
    COMPLETED+=("[OK] Service restart check")
fi

# Print any remaining processes that have open but deleted files
REMAINING_DELETED=$(lsof -n 2>/dev/null | grep DEL | awk '{print $1}' | sort -u)
if [ -n "$REMAINING_DELETED" ]; then
    echo ""
    echo "Processes with open deleted files (may need manual restart):"
    echo "$REMAINING_DELETED"
    OUTSTANDING+=("[!] Processes with deleted files open - check log for details")
fi

# Remove distfiles not owned by any installed package, unless skipped
if [ "$SKIP_ECLEAN" != yes ]; then
    run_step "eclean-dist" eclean-dist --destructive
    STAT_DISTFILES=$(grep "Total space from" "$STAT_TMPFILE" | sed -e 's/.*\[//' -e 's/\].*//' | xargs)
fi

# Clear old build dirs out of Portage's temporary directory
if [ "$TMP_KEEP_DAYS" -gt 0 ]; then
    clean_portage_tmp
fi

# Run etc-update --preen, unless skipped
if [ "$SKIP_ETC_UPDATE" != yes ]; then
    run_step "etc-update --preen" etc-update --preen

    ETC_COUNT=$(find /etc -name '._cfg*' 2>/dev/null | wc -l)
    if [ "$ETC_COUNT" -gt 0 ]; then
        OUTSTANDING+=("[!] $ETC_COUNT config files need manual dispatch-conf")
    fi
fi

NEWEST_KERNEL=$(find /lib/modules -mindepth 1 -maxdepth 1 -printf '%f\n' 2>/dev/null | sort -V | tail -1)
if [ -n "$NEWEST_KERNEL" ] && [ "$NEWEST_KERNEL" != "$(uname -r)" ]; then
    OUTSTANDING+=("[!] Kernel $NEWEST_KERNEL installed, running $(uname -r) - reboot recommended")
fi

if [ "$LOG_KEEP_DAYS" -gt 0 ]; then
    find "$LOG_DIR" -maxdepth 1 -name 'update-*.log' -mtime +$((LOG_KEEP_DAYS - 1)) -delete
fi

# Print disk space
echo ""
echo "--- Disk Space ---"
df -H

ELAPSED=$(( $(date +%s) - START_TIME ))
write_summary > "$SUMMARY_FILE"

echo ""
echo "============================================"
cat "$SUMMARY_FILE"
echo "============================================"

NOTIFIER="$(dirname "$(readlink -f "$0")")/portage-notify.sh"
if [ -n "$NOTIFY_USER" ] && [ -x "$NOTIFIER" ]; then
    "$NOTIFIER" --config "$CONFIG" "$SUMMARY_FILE" || echo "notifier failed, carrying on"
fi

echo ""
echo "=== Portage Auto-Update finished at $(date) ==="

[ ${#FAILURES[@]} -eq 0 ]
