# t2 (T-2, `194.28.111.245`, AlmaLinux 9)

Reached as `almalinux` with sudo: `ssh t4a-t2`. Its other configs live in time-4-action/t4a-ops
(`/root/t4a-ops` on the server); alerts and the nightly cleanup are in `servers/alerts`.

## Docker daemon

`daemon.json` is installed as `/etc/docker/daemon.json`:

- `data-root` on the `/data` disk.
- Container logs capped at 3 files of 10 MB. This applies only to containers created
  after it was set (2026-10-28): app containers get it on their next deploy, others when
  they are recreated. Before it, `t4a-mk-automation` had a 308 MB log; that log is kept
  in `/data/log-archive/`.
- `live-restore`: containers keep running while Docker itself restarts, so a change
  here needs no downtime.

To change it:
```
scp daemon.json t4a-t2:/tmp/ && ssh t4a-t2 'sudo dockerd --validate --config-file /tmp/daemon.json \
  && sudo install -m 644 /tmp/daemon.json /etc/docker/daemon.json && sudo systemctl restart docker'
```

## Monitoring (`monitoring/` → `/data/stack/monitoring`)

Grafana Alloy sends t2's host metrics, every container's metrics and every container's logs to
Prometheus and Loki on t4a (`servers/t4a/README.md`, "Monitoring"), through
https://ingest.time-4-action.com with basic auth `t2`. Its config is the shared
`servers/t4a/monitoring/alloy/config.alloy`; `compose.yml` here sets `SERVER=t2` and the URLs.
`/data/stack/monitoring/.env` (mode 600, not in git) holds `INGEST_PASSWORD`, the same as
`/root/ingest-login` on t4a. About 3 % CPU and 230 MB RAM (limit 384 MB).

Deploy or update (from the repo root):
```
scp servers/t2/monitoring/compose.yml servers/t4a/monitoring/alloy/config.alloy t4a-t2:/tmp/
ssh t4a-t2 'sudo install -m 644 /tmp/compose.yml /tmp/config.alloy /data/stack/monitoring/ \
  && cd /data/stack/monitoring && sudo docker compose up -d && sudo docker compose restart alloy'
```
If it stops, Grafana alerts "Server stopped reporting" for t2 within about 7 minutes.

Beszel and Uptime Kuma still run here; Grafana covers what they show, so they can go when t2 is retired.
