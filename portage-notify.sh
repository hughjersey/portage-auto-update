#!/bin/bash
# Pops up the update summary on your X display
# Usage: portage-notify.sh [--config file] [--show-session] [summary-file]

CONFIG=/etc/portage-auto-update.conf
SHOW_SESSION=no
SUMMARY_FILE=""

NOTIFY_USER=""
NOTIFY_METHOD=auto
LOG_DIR=/var/log/portage-auto-update

while [ $# -gt 0 ]; do
    case "$1" in
        --config)
            CONFIG="$2"
            shift
            ;;
        --show-session) SHOW_SESSION=yes ;;
        *) SUMMARY_FILE="$1" ;;
    esac
    shift
done

if [ -r "$CONFIG" ]; then
    if [ "$(id -u)" -eq 0 ]; then
        read -r owner mode < <(stat -c '%u %a' "$CONFIG")
        if [ "$owner" -ne 0 ] || (( 8#$mode & 8#022 )); then
            echo "portage-notify: refusing $CONFIG" >&2
            exit 1
        fi
    fi
    # shellcheck disable=SC1090
    . "$CONFIG"
fi

SUMMARY_FILE="${SUMMARY_FILE:-$LOG_DIR/latest-summary.txt}"

if [ -z "$NOTIFY_USER" ]; then
    echo "portage-notify: NOTIFY_USER not set, nothing to do"
    exit 0
fi

env_of() {
    tr '\0' '\n' 2>/dev/null < "$1/environ" | sed -n "s/^$2=//p" | head -1
}

# Finds the X session with lowest number, presumed to be your /real/ one
find_session() {
    local uid proc disp num best=""
    uid=$(id -u "$NOTIFY_USER" 2>/dev/null) || return 1
    for proc in /proc/[0-9]*; do
        [ "$(stat -c %u "$proc" 2>/dev/null)" = "$uid" ] || continue
        disp=$(env_of "$proc" DISPLAY)
        # Skips ssh -X, those look like localhost:10
        case "$disp" in
            :[0-9]*) ;;
            *) continue ;;
        esac
        num=${disp#:}
        num=${num%%.*}
        # No socket means that X session is dead
        [ -S "/tmp/.X11-unix/X$num" ] || continue
        if [ -z "$best" ] || [ "$num" -lt "$best" ]; then
            best=$num
            SESSION_PROC=$proc
        fi
    done
    [ -n "$best" ]
}

run_as_user() {
    local var cmd=env
    for var in DISPLAY XAUTHORITY DBUS_SESSION_BUS_ADDRESS XDG_RUNTIME_DIR; do
        if [ -n "${!var}" ]; then
            cmd+=" $var=$(printf %q "${!var}")"
        fi
    done
    cmd+=" $(printf '%q ' "$@")"
    su -s /bin/bash -c "$cmd" "$NOTIFY_USER" >/dev/null 2>&1 </dev/null &
}

if ! find_session; then
    echo "portage-notify: no X session for $NOTIFY_USER, summary is in $SUMMARY_FILE"
    exit 0
fi

DISPLAY=$(env_of "$SESSION_PROC" DISPLAY)
XAUTHORITY=$(env_of "$SESSION_PROC" XAUTHORITY)
DBUS_SESSION_BUS_ADDRESS=$(env_of "$SESSION_PROC" DBUS_SESSION_BUS_ADDRESS)
XDG_RUNTIME_DIR=$(env_of "$SESSION_PROC" XDG_RUNTIME_DIR)

if [ "$SHOW_SESSION" = yes ]; then
    echo "DISPLAY=$DISPLAY"
    echo "XAUTHORITY=$XAUTHORITY"
    echo "DBUS_SESSION_BUS_ADDRESS=$DBUS_SESSION_BUS_ADDRESS"
    echo "XDG_RUNTIME_DIR=$XDG_RUNTIME_DIR"
    exit 0
fi

if [ ! -f "$SUMMARY_FILE" ]; then
    echo "portage-notify: summary file not found: $SUMMARY_FILE"
    exit 0
fi

FAILURE_COUNT=$(grep -c '^\[FAIL\]' "$SUMMARY_FILE")
if [ "$FAILURE_COUNT" -gt 0 ]; then
    TITLE="Portage Update - FAILURES"
else
    TITLE="Portage Update Complete"
fi

if [ "$NOTIFY_METHOD" = auto ]; then
    NOTIFY_METHOD=""
    for tool in yad zenity xmessage notify-send; do
        if command -v "$tool" >/dev/null; then
            NOTIFY_METHOD=$tool
            break
        fi
    done
fi

# Full path as su might not have /usr/local/bin in PATH
TOOL=$(command -v "$NOTIFY_METHOD")
if [ -z "$TOOL" ]; then
    echo "portage-notify: nothing to notify with (NOTIFY_METHOD=${NOTIFY_METHOD:-auto})"
    exit 0
fi

case "$NOTIFY_METHOD" in
    yad)
        run_as_user "$TOOL" --text-info --title="$TITLE" --filename="$SUMMARY_FILE" \
            --width=600 --height=500 --center --button=OK:0 \
            --fontname="Monospace 10" --no-markup
        ;;
    zenity)
        run_as_user "$TOOL" --text-info --title="$TITLE" --filename="$SUMMARY_FILE" \
            --width=600 --height=500 --font="Monospace 10"
        ;;
    xmessage)
        run_as_user "$TOOL" -title "$TITLE" -center -geometry 600x500 \
            -buttons OK:0 -file "$SUMMARY_FILE"
        ;;
    notify-send)
        run_as_user "$TOOL" "$TITLE" "$FAILURE_COUNT failed, see $SUMMARY_FILE"
        ;;
    *)
        echo "portage-notify: don't know NOTIFY_METHOD=$NOTIFY_METHOD"
        exit 0
        ;;
esac

echo "portage-notify: sent to $NOTIFY_USER on $DISPLAY via $NOTIFY_METHOD"
