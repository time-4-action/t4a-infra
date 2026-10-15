# Auth0 — config-as-code

Time 4 Action runs **two Auth0 tenants**: `dev` and `prod`. Their configuration
is managed as code with [`auth0-deploy-cli`](https://github.com/auth0/auth0-deploy-cli)
and stored in this folder. Secrets live in **dotenvx-encrypted** `.env` files
that are safe to push to GitHub.

## How it flows

`prod` is the live tenant. `dev` is a **scratch copy**.

- **Pull (prod → dev):** refresh dev to mirror prod whenever you want. This is
  the day-to-day script. dev is disposable, so overwriting it is safe.
- **Promote (dev → prod):** when a change has been made and verified in dev,
  push it up to prod.

```
   pull (refresh dev)            promote (ship change)
prod ───────────────▶ dev      dev ───────────────▶ prod
```

Each direction is a **deliberate, manual run** — there is **no automated
two-way sync**, and you **never edit prod directly in the dashboard** (it gets
overwritten on the next import).

> Promoting to prod goes through a pull request: merging a change to
> `auth0/tenant/` into `main` imports it into prod via CI. See
> [CI/CD](../README.md#cicd).

## Secrets: dotenvx-encrypted env (committable)

Each tenant has a `.env` file with its deploy-cli settings. `auth0-deploy-cli`
reads `AUTH0_DOMAIN`, `AUTH0_CLIENT_ID`, `AUTH0_CLIENT_SECRET`,
`AUTH0_ALLOW_DELETE`, and `AUTH0_KEYWORD_REPLACE_MAPPINGS` straight from the
environment, so no plaintext config file ever has to sit on disk.

```bash
# 1. Copy the templates
cp auth0/.env.prod.example auth0/.env.prod
cp auth0/.env.dev.example  auth0/.env.dev

# 2. Fill in the real domain / client id / client secret in each file

# 3. Encrypt in place (run once per file, and after any edit)
npx dotenvx encrypt -f auth0/.env.prod
npx dotenvx encrypt -f auth0/.env.dev
```

After `encrypt`, the values inside `.env.prod` / `.env.dev` are **ciphertext** —
those files are committed to GitHub. The decryption keys are written to
`auth0/.env.keys`.

### The master secret

`auth0/.env.keys` (the `DOTENV_PRIVATE_KEY_*` values) is the **master secret
that unlocks everything**. It is **gitignored — never commit it.**

- Store it in a password manager / secure note.
- To work on another machine, paste the key back into `auth0/.env.keys`, or set
  `DOTENV_PRIVATE_KEY_PROD` / `DOTENV_PRIVATE_KEY_DEV` in the environment.
- **CI:** provide the private keys as CI secrets / env vars (e.g.
  `DOTENV_PRIVATE_KEY_PROD`). dotenvx decrypts from the environment, so nothing
  sensitive lives in the repo.

> dotenvx uses a private **key** to decrypt (not a typed passphrase). Treat that
> key as your master password: guard it, back it up, rotate it by re-encrypting
> if it leaks.

`AUTH0_ALLOW_DELETE` is `false` for prod (an import can never delete prod state)
and `true` for dev (imports may converge dev fully).

## Prerequisite: one M2M app per tenant

The deploy CLI authenticates as a Machine-to-Machine application. **Each tenant
needs its own M2M app.**

For each tenant (`dev` and `prod`):

1. Auth0 Dashboard → **Applications → Create Application → Machine to Machine**.
2. Authorize it for the **Auth0 Management API**.
3. Grant **read + CRUD** scopes on the resources you manage — e.g.
   `read:clients`, `create:clients`, `update:clients`, `delete:clients`, and the
   equivalents for `resource_servers`, `connections`, `rules`, `actions`,
   `tenant_settings`, `prompts`, etc.
4. Put that app's **Domain / Client ID / Client Secret** into the tenant's
   `.env` file, then encrypt (above).

## Pull flow (prod → dev) — the everyday script

One command:

```bash
npm run auth0:sync:prod-to-dev
```

That runs `auth0/scripts/sync-prod-to-dev.ps1`, which:

1. **Exports prod** → `auth0/tenant/tenant.yaml` (+ assets).
2. **Pauses** so you can template env-specific values — replace prod URLs /
   audiences with `##PORTAL_URL##` / `##API_IDENTIFIER##` so dev does not point
   at prod. See [`tenant/README.md`](./tenant/README.md).
3. **Imports** the templated `tenant.yaml` into **dev** (dev's
   `AUTH0_KEYWORD_REPLACE_MAPPINGS` expands the placeholders to dev values).

Skip the pause once the YAML is already templated:

```bash
pwsh auth0/scripts/sync-prod-to-dev.ps1 -Force
```

Or just double-click `auth0/scripts/sync-prod-to-dev.cmd` on Windows.

## Promote flow (dev → prod) — when shipping a change

```bash
# 1. Make + verify the change in the DEV tenant.
npm run auth0:export:dev    # refresh auth0/tenant/tenant.yaml from dev
                            # (keep ##KEYWORD## placeholders intact)
# 2. Commit tenant/ on a branch and open a pull request into main.
# 3. Merge it. The auth0-deploy workflow imports tenant.yaml into prod:
#    it prints the plan, applies it, then checks nothing is left to change.
```

Don't run `npm run auth0:import:prod` by hand. Going through a PR keeps the
repo and prod in step and leaves a record of every prod change.

## What is NOT exported

- **Client secrets** are not exported — each tenant keeps its own, managed per
  tenant (dashboard or the encrypted `.env`).
- **Users** are not exported — user data lives in each tenant and is not
  promoted with config.

## Hard rule: never edit prod directly

Prod is a deploy target, not an editing surface. Any manual prod change gets
**overwritten on the next import**. Make changes in dev, then promote.
