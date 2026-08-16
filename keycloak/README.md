# Keycloak (production mode) — runbook

Keycloak 26.7.1 is the OIDC identity provider for MonitorERP-KB. This stack
runs **production mode** (`start`, not `start-dev`): external Postgres,
explicit hostname, realm imported as code.

## Architecture

```
browser ── https://keycloak.ai.monitorsystem.cn ──► nginx (server-nginx, TLS) ──► 127.0.0.1:8081 ──► keycloak
browser ── https://kb.ai.monitorsystem.cn ────────► nginx ──► 127.0.0.1:4800 ──► kb-web ──► kb-api (OIDC client)
                                                          ▲                                    │
keycloak ── server-postgres (monitorerp_kc DB, shared monitorerp-shared network) ◄─────────────┘
```

- Keycloak listens on `127.0.0.1:8081` only; nginx is the sole public route.
- Realm data lives in the **`monitorerp_kc` database** on the server-level
  Postgres (same container as `monitorerp_kb`), not in embedded H2.
- The realm is **imported as code** from `realms/monitorerp.json` on first
  boot (`--import-realm`). Once the realm exists, later boots skip the import
  (Keycloak's `IGNORE_EXISTING` strategy) — console edits are not clobbered.
- The KB app is the only consumer: confidential client `monitorerp-kb`,
  standard flow, PKCE S256, redirect URI
  `https://kb.ai.monitorsystem.cn/api/auth/oidc/callback`.

## Layout

| Path | Purpose |
|---|---|
| `docker-compose.yml` | production `start`, Postgres wiring, healthcheck, volume, realm-import mount |
| `bootstrap.sh` | creates `keycloak/.env` (secrets, gitignored), ensures `monitorerp_kc` exists, starts the stack |
| `.env` | **server-only, gitignored**: `KC_BOOTSTRAP_ADMIN_*`, `KC_DB_PASSWORD` |
| `realms/monitorerp.json` | realm artifact (from the app repo, production origin substituted) |

Realm settings baked into the artifact (per the shared design):

- Email is the login identifier (`registrationEmailAsUsername`, `loginWithEmailAllowed`); **no SMTP** — `resetPasswordAllowed: false`, `verifyEmail: false`. Password resets are admin-only (set a temporary password in the console).
- **Moderate password policy**: ≥ 10 chars, ≥ 1 digit, ≥ 1 special, must not contain the username.
- **Brute-force protection on**: 10 failures within 15 min → lockout, escalating waits (max 15 min).
- **Long-lived SSO session**: idle 8 h, max 24 h; access token 5 min;
  refresh tokens stay valid for the SSO session lifetime (8 h idle). No
  Remember Me. The app's own 7-day `kb_session` cookie is the real session
  authority.
- No Keycloak-side self-registration (the app's own sign-up remains the second door, per design).

## First-time provisioning (on the server)

```bash
cd ~/src/monitorerp-deploy && git pull
./postgres/bootstrap.sh        # if not yet done — creates postgres/.env + monitorerp-shared network
./keycloak/bootstrap.sh        # creates keycloak/.env, creates monitorerp_kc, starts the stack
./manage.sh up                 # everything, Keycloak included (or ./manage.sh status to check)
```

`keycloak/bootstrap.sh` is idempotent: re-running it never regenerates
existing secrets; if an old `.env` lacks `KC_DB_PASSWORD` it is appended
(the production-mode switch requires it). **Fresh-start note:** the previous
`start-dev` deployment used the embedded H2 database with no volume, so this
recreate discards it by design — the realm is re-created from
`realms/monitorerp.json`.

Then verify:

```bash
curl -f http://127.0.0.1:8081/health/ready
curl -f https://keycloak.ai.monitorsystem.cn/realms/monitorerp/.well-known/openid-configuration
```

The realm `monitorerp` should exist in the admin console
(`https://keycloak.ai.monitorsystem.cn/admin`, credentials in
`keycloak/.env` — note `KC_BOOTSTRAP_ADMIN_*` only applies on **first** boot
of a fresh database).

## Create users (admin-provisioned)

**Batch provisioning:** `./keycloak/create-users.sh` creates every user in
`keycloak/data/monitorerp-internal-users.csv` (one email per line, committed
manifest). It generates a policy-compliant temporary password per user and
prints the handoff table — no SMTP, so that output IS the delivery. Run
`--dry-run` first to see the exact plan. `--file path.csv` overrides the
manifest. See the script header for the full contract.

**Single users / one-off fixes** (console):

1. Console → **monitorerp** realm → **Users** → **Add user**:
   - Username = the user's **email address** (email is the login identifier),
   - Email, First/Last name (optional),
   - Leave "Email verified" as-is (no SMTP — nothing sends mail).
2. **Credentials** tab → **Set password** → tick **Temporary** → set a temp
   password → hand it to the user (out of band). They must change it at first
   login (the temporary flag enforces this; the temp password also must meet
   the realm policy — hand out e.g. `Temp-<something>123!`).

Users created in Keycloak auto-provision in the KB app on first sign-in as
active Members; an existing KB account with the same email is linked instead.

## Wire the KB app (one-time)

1. Console → **monitorerp** realm → **Clients** → `monitorerp-kb` →
   **Credentials** → copy the **Client secret**. (Each instance generates its
   own secret at import — keep it out of git.)
2. On the server, in `kb/.env` (gitignored), set **all four**:

   ```bash
   OIDC_ISSUER_URL=https://keycloak.ai.monitorsystem.cn/realms/monitorerp
   OIDC_CLIENT_ID=monitorerp-kb
   OIDC_CLIENT_SECRET=<the copied secret>
   OIDC_REDIRECT_URI=https://kb.ai.monitorsystem.cn/api/auth/oidc/callback
   ```

   (A partial set is a boot-time error — all four or none. A stale or wrong
   `OIDC_REDIRECT_URI` shows up as Keycloak's *Invalid redirect_uri*.)
3. Restart the API so it picks up the new environment:

   ```bash
   cd ~/src/monitorerp-deploy/kb && docker compose up -d
   ```

4. Verify the feature is on:

   ```bash
   curl http://127.0.0.1:4801/auth/oidc/config
   # {"enabled":true,"loginUrl":"https://kb.ai.monitorsystem.cn/api/auth/oidc/login"}
   ```

## Manual acceptance walkthrough (definition of done)

1. Console → create a test user (temp password) in realm `monitorerp`.
2. Browse `https://kb.ai.monitorsystem.cn` → **Sign in with Keycloak**.
3. Keycloak login page → sign in with the test user → forced password change
   (temp) → lands back on the KB app, signed in.
4. Confirm the session persists across a page reload; sign out; confirm the
   cookie is gone and the sign-in page is back.
5. Repeat sign-in once more without the password change — the user should go
   straight through (SSO session idle 8 h).

## Rotating the client secret

1. Console → **monitorerp** realm → **Clients** → `monitorerp-kb` →
   **Credentials** → **Regenerate Secret**.
2. Update `OIDC_CLIENT_SECRET` in `kb/.env`, then restart the API
   (`cd ~/src/monitorerp-deploy/kb && docker compose up -d`).
3. Verify with `curl http://127.0.0.1:4801/auth/oidc/config` and one
   sign-in. A stale secret surfaces as Keycloak's *Invalid client* at the
   first attempt — never as a hang.

## Restore from scratch (no backups — by design)

There are **no database dumps** for either Postgres database; the realm JSON
in git is the only durable artifact. Losing the server means:

1. Reinstall → `git clone` the deploy repo → ship images
   (`ship-keycloak-images.ps1` etc.).
2. `./postgres/bootstrap.sh` then `./keycloak/bootstrap.sh` — the realm is
   re-imported from `realms/monitorerp.json`; the admin password and client
   secret are freshly generated.
3. Re-create all users in the console (temp passwords), re-paste the client
   secret into `kb/.env`, restart the KB API, re-run the acceptance
   walkthrough.

This is the accepted trade-off (see the design review): realm *structure*
recovers from git; realm *users* and KB documents do not.

## Upgrades

- The version is pinned in `docker-compose.yml` and enforced by
  `ship-keycloak-images.ps1` (refuses a mismatched `-Version`). Upgrade =
  bump the pin, re-ship (`.\\ship-keycloak-images.ps1 -Version X.Y.Z`), verify
  health + the acceptance walkthrough.
- Realm import behavior on boot is `IGNORE_EXISTING` (verified against the
  pinned image): an existing realm is **not** overwritten on restart or
  upgrade, so console edits (users, tweaks) survive. Keep the artifact in
  sync with structural console changes.
- No upgrade policy is decided; a failed upgrade is treated as "restore from
  scratch" (above). Keep the previous image tar (the ship script keeps the
  newest 3 locally) as cheap rollback insurance: flip the pin back and
  `docker compose up -d`.

## Operational notes

- **Health**: compose healthcheck probes `/health/ready` on the container's
  main port (`--http-management-health-enabled=false` keeps it off the
  management :9000, which is occupied on this host). `manage.sh up` also
  waits on it.
- **TLS**: nginx terminates TLS; Keycloak itself runs plain HTTP on the
  loopback port (`--http-enabled=true` — production `start` otherwise refuses
  to boot without key material). Issuer, redirects and frontend URLs are
  generated from `KC_HOSTNAME` (https), never from the loopback request.
- **Hostname strictness**: strict hostname stays at the default (true) —
  verified that `/health/ready` answers 200 on the loopback port even then,
  so the healthcheck, `manage.sh` and the ship script probes work unchanged.
- **Realm import**: `--import-realm` uses Keycloak's `IGNORE_EXISTING`
  strategy (verified): an existing realm is **not** overwritten on boot, so
  console edits (users, tweaks) survive restarts and upgrades. The artifact
  stays a snapshot of the realm *structure* — when you change structure in
  the console, mirror the change back into `realms/monitorerp.json` so the
  git artifact stays truthful.
- **Admin console exposure**: intentionally public (design decision); the
  only brute-force defense is the realm's per-realm lockout. Use strong
  master-realm admin credentials.
- **Two doors**: the KB app's own password sign-up remains enabled — its
  `/auth/sign-in` has no rate limiting (design decision, accepted).
