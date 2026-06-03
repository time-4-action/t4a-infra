# `tenant/` — exported Auth0 configuration

Exported tenant YAML lands here. The deploy CLI writes `tenant.yaml` plus
supporting files (clients, resource servers, actions, etc.) into this folder.

```
pnpm/npm run auth0:export:dev   # writes ./tenant/tenant.yaml (+ assets)
pnpm/npm run auth0:import:prod  # reads ./tenant/tenant.yaml
```

## Template env-specific values with `##KEYWORD##`

After an export, **do not leave environment-specific values hard-coded** in
`tenant.yaml`. Anything that differs between dev and prod must be replaced with
`##KEYWORD##` placeholders that map to `AUTH0_KEYWORD_REPLACE_MAPPINGS` in the
target tenant's config file. Otherwise dev would point at prod URLs (and vice
versa) on import.

Values that almost always need templating:

| Value                    | Example placeholder      | Maps to              |
| ------------------------ | ------------------------ | -------------------- |
| Application callback URLs | `##PORTAL_URL##/callback` | `PORTAL_URL`         |
| Logout URLs              | `##PORTAL_URL##`         | `PORTAL_URL`         |
| Allowed web origins      | `##PORTAL_URL##`         | `PORTAL_URL`         |
| API audience / identifier | `##API_IDENTIFIER##`     | `API_IDENTIFIER`     |

Example, in `tenant.yaml`:

```yaml
clients:
  - name: Portal SPA
    callbacks:
      - "##PORTAL_URL##/callback"
    allowed_logout_urls:
      - "##PORTAL_URL##"
    web_origins:
      - "##PORTAL_URL##"
resourceServers:
  - name: T4A API
    identifier: "##API_IDENTIFIER##"
```

On import, the deploy CLI substitutes each `##KEYWORD##` with the matching value
from the target tenant's `AUTH0_KEYWORD_REPLACE_MAPPINGS` (set in that tenant's
dotenvx-encrypted `.env` file — e.g. `auth0/.env.dev`).
