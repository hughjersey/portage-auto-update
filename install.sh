#!/bin/bash
# Installs everything but doesn't turn it on

set -euo pipefail

SRC="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DESTDIR="${DESTDIR:-}"
SBIN="$DESTDIR/usr/local/sbin"
UNITS="$DESTDIR/etc/systemd/system"
CONF="$DESTDIR/etc/portage-auto-update.conf"
TIMESTAMP=$(date +%Y%m%d-%H%M%S)

if [ "$(id -u)" -ne 0 ]; then
    echo "needs root" >&2
    exit 1
fi

put() {
    local src=$1 dest=$2 mode=$3
    if [ -f "$dest" ] && ! cmp -s "$src" "$dest"; then
        cp -p "$dest" "$dest.bak-$TIMESTAMP"
        echo "backed up $dest"
    fi
    install -o root -g root -m "$mode" "$src" "$dest"
    echo "installed $dest"
}

for f in portage-auto-update.sh portage-notify.sh; do
    bash -n "$SRC/$f"
done

echo "checking prereqs"
if [ -e "$CONF" ]; then
    "$SRC/portage-auto-update.sh" --check --config "$CONF"
else
    "$SRC/portage-auto-update.sh" --check
fi

mkdir -p "$SBIN" "$(dirname "$CONF")"
put "$SRC/portage-auto-update.sh" "$SBIN/portage-auto-update.sh" 0750
put "$SRC/portage-notify.sh" "$SBIN/portage-notify.sh" 0750

if [ -e "$CONF" ]; then
    echo "keeping $CONF"
else
    install -o root -g root -m 0640 "$SRC/portage-auto-update.conf" "$CONF"
    echo "installed $CONF, have a look through it"
fi

if [ -d /run/systemd/system ]; then
    mkdir -p "$UNITS"
    put "$SRC/portage-auto-update.service" "$UNITS/portage-auto-update.service" 0644
    put "$SRC/portage-auto-update.timer" "$UNITS/portage-auto-update.timer" 0644
    if [ -z "$DESTDIR" ]; then
        systemctl daemon-reload
    fi
    echo ""
    echo "to turn it on: systemctl enable --now portage-auto-update.timer"
else
    echo ""
    echo "to turn it on: cp $SRC/portage-auto-update.cron /etc/cron.d/portage-auto-update"
    echo "(no dot in that name, cron skips files that have one)"
fi
