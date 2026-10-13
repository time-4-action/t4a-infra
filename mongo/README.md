# mongo

MongoDB data sync — **pull prod → dev**. Follows the repo's one-way principle:
`prod` is the source of truth, `dev` is a disposable scratch copy. There is **no**
automated two-way sync; you run the pull by hand when you want to refresh dev.

```
prod ──(mongodump | mongorestore --drop)──▶ dev
```

## Prerequisites

- **MongoDB Database Tools** (`mongodump` / `mongorestore`) on PATH. These are
  **separate** from `mongosh` — install from
  <https://www.mongodb.com/docs/database-tools/>.
- Node deps installed (`npm install`) for `dotenvx`.

## One-time setup

1. Copy the template and fill in both connection strings:

   ```bash
   cp mongo/.env.example mongo/.env
   ```

   - `PROD_MONGOSH` — full connection URI for the prod database (read from).
   - `DEV_MONGOSH` — full connection URI for the dev database (written to).

   Scope the copy to one database by including the db name in the URI path
   (e.g. `mongodb+srv://user:pass@host/t4a`).

2. Encrypt it (after this, `mongo/.env` is ciphertext and **is** committed):

   ```bash
   npx dotenvx encrypt -f mongo/.env
   ```

   The decryption keys land in `mongo/.env.keys` — **gitignored, never commit.**
   Keep them in your password manager. See the [root README](../README.md#secrets).

## Pull prod → dev

```bash
npm run mongo:sync:prod-to-dev
```

This dumps prod and restores it into dev. **dev is overwritten** — every
collection present in the prod dump is dropped in dev (`--drop`) before restore.
You'll be prompted to type `dev` to confirm. Double-clicking
`mongo/scripts/sync-prod-to-dev.cmd` does the same.

### Notes

- `--drop` only drops collections that exist **in the prod dump**. A collection
  that exists in dev but not in prod is left untouched. To make dev an exact
  mirror, drop the dev database first or scope both URIs to the same db name.
- The script refuses to run if `PROD_MONGOSH` and `DEV_MONGOSH` are identical,
  and never writes to prod.
- Data is streamed through a temporary gzip archive in the OS temp dir, which is
  deleted when the run finishes.
