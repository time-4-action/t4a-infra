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
| `servers/t4a/` | **Implemented** | Hetzner server `t4a`: Traefik edge, shared Postgres with point-in-time backups, MariaDB + WordPress sites, restic ([README](./servers/t4a/README.md)) |
| `servers/alerts/` | **Implemented** | Slack alerts for both servers (t4a, T-2): backup failures at once, a daily summary ([README](./servers/alerts/README.md)) |
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

## CI/CD

Two GitHub Actions workflows. Nothing is built or shipped as an image; what
"deploys" from this repo is the Auth0 tenant config.

### `ci` (`.github/workflows/ci.yml`): every pull request and push to `main`

- `npm run env:check`: every committed dotenvx `.env` is ciphertext (the same
  check as the pre-commit hook, which a clone without `npm install` skips)
- no `.env.keys` file is tracked
- every YAML file under `auth0/tenant/` parses
- every `.ps1` script parses and has no PSScriptAnalyzer errors

### `auth0-deploy` (`.github/workflows/auth0-deploy.yml`): check, then deploy, then verify

| Trigger | Target |
| --- | --- |
| push to `main` touching `auth0/tenant/**` or `auth0/.env.prod` | **prod** |
| Actions → auth0-deploy → Run workflow | `dev` (default) or `prod` |

`deploy` runs `npm run auth0:import:<target> -- --dry-run --apply`, which prints
the plan and then applies it. `verify` runs the dry-run again and warns if the
tenant still differs from `tenant.yaml`. Imports into one tenant run one at a
time and are never cancelled.

So the promote path (dev → prod) is a pull request: export dev into
`auth0/tenant/`, open a PR, and merging it imports into prod. The direction stays
one-way and deliberate; the PR review is the deliberate step.

The MongoDB pull is **not** in CI. It moves prod data, and a GitHub runner
would need network access to both databases. Run it by hand
(`npm run mongo:sync:prod-to-dev`).

### GitHub settings (once)

| Where | Name | Value |
| --- | --- | --- |
| Environment `production` | secret `DOTENV_PRIVATE_KEY_PROD` | from `auth0/.env.keys` |
| Environment `development` | secret `DOTENV_PRIVATE_KEY_DEV` | from `auth0/.env.keys` |

Restrict the `production` environment to the `main` branch, and add a required
reviewer if every prod import should wait for an approval. The Auth0 domain,
client ID and secret stay in the encrypted `auth0/.env.prod` / `auth0/.env.dev`,
which have to be committed before the first deploy. The deploy fails loudly if
they, `tenant.yaml` or the key are missing.

`.github/dependabot.yml` opens at most one grouped PR a month per ecosystem (npm
minor and patch, GitHub Actions); each one goes through `ci`.
