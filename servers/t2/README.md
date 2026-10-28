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
