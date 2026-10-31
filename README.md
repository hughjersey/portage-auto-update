# portage-auto-update

Nightly `@world` update for Gentoo that runs on its own. Works on systemd or OpenRC.

It syncs, updates `@world` and any -9999 packages, then does depclean,
preserved-rebuild, revdep-rebuild, perl-cleaner, eclean-dist and
`etc-update --preen`. You get a log, a short summary, and a popup if you want one.

## Install

```bash
./portage-auto-update.sh --check    # tells you what's missing
sudo ./install.sh
sudo $EDITOR /etc/portage-auto-update.conf
```

Nothing runs until you turn it on:

```bash
systemctl enable --now portage-auto-update.timer              # systemd
cp portage-auto-update.cron /etc/cron.d/portage-auto-update   # openrc
```

It runs at 2am. The cron way needs a cron that reads `/etc/cron.d`.

## Config

Everything's in `/etc/portage-auto-update.conf`. Set `NOTIFY_USER` if you want
the popup. It uses yad, zenity, xmessage or notify-send, whichever it finds.
yad isn't in the main tree.

## Running by hand

```bash
sudo portage-auto-update.sh --skip-sync --skip-depclean
sudo portage-auto-update.sh --exclude "www-client/chromium"
```

Every step has a `--skip-` flag. Logs are in `/var/log/portage-auto-update/`.

## Credit

Based on [gentoo-portage-update](https://git.tghost.co.uk/bratch-git/gentoo-portage-update/).

## License

GPL-3.0 only, see [LICENSE](LICENSE).
