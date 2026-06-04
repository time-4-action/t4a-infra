# t4a-infra

Infrastructure-as-code for **Time 4 Action**. This repo is the **single source
of truth** for Time 4 Action's infrastructure configuration — what runs, how
it's wired, and how it's promoted between environments.

## Guiding principle: deliberate one-way runs, no automated two-way sync

`prod` is the live source of truth. `dev` is a **scratch copy**. Config moves
between them only via **deliberate, manual runs** — never an automated loop.

```
   pull (refresh dev)            promote (ship change)
prod ───────────────▶ dev      dev ───────────────▶ prod
```

- **Pull (prod → dev):** refresh dev to mirror prod. Safe and repeatable — dev
  is disposable.
- **Promote (dev → prod):** push a verified change up to prod.
- **Never** set up automated bidirectional sync — each direction is run by hand,
  on purpose.
- **Never** edit prod directly — manual prod changes get overwritten on the next
  import.

This principle applies wherever there's a dev/prod split (today: Auth0, MongoDB).

## Subdirectories

| Directory  | Status            | Holds                                                          |
| ---------- | ----------------- | -------------------------------------------------------------- |
| `auth0/`   | **Implemented**   | Auth0 dev/prod tenant config-as-code (`auth0-deploy-cli`)      |
| `mongo/`   | **Implemented**   | MongoDB data pull prod → dev (`mongodump` / `mongorestore`)    |
| `nginx/`   | Stub              | Reverse-proxy / web-server config (server blocks, TLS, routing)|
| `docker/`  | Stub              | Container definitions & orchestration (Dockerfiles, Compose)   |
| `n8n/`     | Stub              | n8n workflow-automation config                                 |
| `backups/` | Stub              | Backup config (restic — repos, retention, schedules)           |
| `dns/`     | Stub              | DNS records as code (Cloudflare)                               |

## Secrets

**Never commit plaintext secrets.**

- Secrets live in **dotenvx-encrypted** `.env` files (e.g. `auth0/.env.prod`).
  Once encrypted their values are ciphertext, so those files **are** committed
  to GitHub.
- The decryption keys (`*/.env.keys`, the `DOTENV_PRIVATE_KEY_*` values) are the
  **master secret** — **gitignored, never committed.** Keep them in a password
  manager. To unlock on a new machine, restore the key.
- Plaintext `.env`, `*.local.json`, and any real `config-*.json` are gitignored.
- In **CI**, supply the dotenvx private keys as CI secrets / env vars — nothing
  sensitive lives in the repo.

See [`auth0/README.md`](./auth0/README.md) for the exact encrypt/decrypt steps.

## Getting started

The only currently-implemented component is **Auth0**. Start there:

➡️ **[`auth0/README.md`](./auth0/README.md)**

```bash
npm install        # installs auth0-deploy-cli + dotenvx locally (no global install)
```

Then follow `auth0/README.md` for the M2M prerequisites, encrypting the `.env`
files, and the pull (prod → dev) flow:

```bash
npm run auth0:sync:prod-to-dev    # export prod, template URLs, import into dev
```
