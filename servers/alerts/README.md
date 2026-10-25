# Slack alerts (both servers)

Both servers post to one Slack channel, `#t4a-server`, as the Slack app "t4a server"
(`A0CBTNA1RGD` in the `t4a-talk` workspace, manifest in `slack-app-manifest.json`):
right away when a backup fails, and with a summary every morning at 05:00 UTC
(06:00 CET, 07:00 CEST).

| Server | Hostname in Slack | What alerts |
|---|---|---|
| t4a (Hetzner, `77.42.42.60`) | `time-4-action-production` | `pg-backup` and `t4a-backup` crons, via `t4a-run` |
| t2 (T-2, `194.28.111.245`) | `t4a-instance` | `t4a-backup.service` and `t4a-backup-maintenance.service`, via `OnFailure=` |

The daily summary (`t4a-daily`) lists each backup with its time and size, and flags
(red) any nightly backup older than 26 h, so a backup that silently never ran also shows.
On t4a it covers pgBackRest (latest base backup, restore window, WAL archiving),
restic and rokomet's `app.db` copy; on t2 the restic snapshot per tag (`mariadb`,
`wordpress`, `mongodb`, `configs`) and the last result of `t4a-backup.service`.
On both: disk over 80 %, RAM under 10 % available, unhealthy or restarting containers.
If a whole server is down, nothing posts at all: that needs an outside check
(Uptime Kuma push monitors, `/etc/t4a-heartbeat.env` in `servers/t4a/README.md`).

## Files

| File | Installed as | On |
|---|---|---|
| `t4a-slack` | `/usr/local/bin/t4a-slack "text"`: posts one message | both |
| `t4a-run` | `/usr/local/bin/t4a-run <name> <cmd...>`: runs a cron job into `/var/log/<name>.log`, posts its last 15 lines if it fails | both |
| `t4a-daily`, `t4a-daily.cron` | `/usr/local/bin/t4a-daily`, `/etc/cron.d/t4a-daily` | both |
| `t4a-unit-failed`, `t4a-alert@.service` | `/usr/local/bin/`, `/etc/systemd/system/` | t2 |
| `on-failure.conf` | `/etc/systemd/system/t4a-backup.service.d/t4a-alert.conf` and the same for `t4a-backup-maintenance.service` | t2 |

t4a's backup crons (`servers/t4a/postgres/pg-backup.cron`, `servers/t4a/backup/t4a-backup.cron`)
call their scripts through `t4a-run`.

Not in git, only on each server: `/etc/t4a-slack.env`, mode 600:
```
SLACK_BOT_TOKEN=xoxb-...      # api.slack.com/apps/A0CBTNA1RGD → OAuth & Permissions → Bot User OAuth Token
SLACK_CHANNEL=t4a-server      # optional; any public channel works without inviting the bot (chat:write.public)
```
Without it every script still runs and prints the message to stderr instead.
The app was created with `slack app install` from a folder holding the manifest; to change
its scopes, edit the manifest in the app's settings page and reinstall.
The same app has the `/maintenance` slash command (scope `commands`), served by
`/srv/maintenance` on t4a (`servers/t4a/README.md`).

## Install or update

```
cd servers/alerts
scp t4a-slack t4a-run t4a-daily t4a:/usr/local/bin/ && scp t4a-daily.cron t4a:/etc/cron.d/t4a-daily
ssh t4a 'chmod 755 /usr/local/bin/t4a-slack /usr/local/bin/t4a-run /usr/local/bin/t4a-daily'

scp t4a-slack t4a-run t4a-daily t4a-unit-failed t4a-alert@.service on-failure.conf t4a-daily.cron t4a-t2:/tmp/
ssh t4a-t2 'cd /tmp && sudo install -m 755 t4a-slack t4a-run t4a-daily t4a-unit-failed /usr/local/bin/ \
  && sudo install -m 644 t4a-alert@.service /etc/systemd/system/ && sudo install -m 644 t4a-daily.cron /etc/cron.d/t4a-daily \
  && for u in t4a-backup t4a-backup-maintenance; do sudo install -D -m 644 on-failure.conf /etc/systemd/system/$u.service.d/t4a-alert.conf; done \
  && sudo systemctl daemon-reload'
```
t2 is reached as `almalinux` with sudo (`ssh t4a-t2`); t4a as `root`.

## Test

- Summary now: `ssh t4a t4a-daily`, `ssh t4a-t2 sudo t4a-daily`
- Failure alert: `ssh t4a 't4a-run alert-test false; rm /var/log/alert-test.log'`,
  `ssh t4a-t2 sudo systemctl start t4a-alert@t4a-backup.service`
