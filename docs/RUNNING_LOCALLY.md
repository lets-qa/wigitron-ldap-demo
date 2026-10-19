# Running Locally

How to run the directory and access each feature on your own machine. There are
two independent pieces: the **directory** (Samba AD, in Docker) and the
**staff-portal API** (Python on your host, which shells into the container).

> Note: as of this writing these features live on the `fix/admin-no-expiry`
> branch and are not yet merged to `main`.

## 1. Start the directory (the Samba DC)

```bash
cd ~/personal/Simulated-Active-Directory-LDAP-Test-Server
docker compose up -d --build samba-dc      # DC only
# wait ~10-15s for provisioning
docker exec samba-dc samba-tool domain info 127.0.0.1   # confirm it's up
```

This gives a live `wigitron.com` AD at:

- **LDAP:** `ldap://localhost:389`
- **LDAPS:** `ldaps://localhost:636` (self-signed cert)
- **Admin:** `Administrator` / `Admin!Test1234`
- **Base DN:** `dc=wigitron,dc=com`

Ports are overridable via a `.env` (`LDAP_PORT` / `LDAPS_PORT`) when 389/636 are
already taken — the container always listens on 389/636 internally. See
`.env.example`.

## 2. Seed test data (shell scripts, run from host)

```bash
./seed_directory.sh        # 20 users (testuser1..20 / Password!1..20) + nested groups
./add_email_groups.sh      # distribution lists (all@, support@, marketing@)
./test_binds.sh            # verify auth — 5 good logins + 2 deliberate failures
./harden_accounts.sh       # disable Guest, kill password aging, un-expire everyone
```

## 3. LAM web GUI (manage accounts in a browser)

```bash
docker compose up -d lam
```

Open **http://localhost:7080**. LAM talks to the DC internally
(`ldap://samba-dc:389`), so it is independent of the host port mapping. Use it to
browse, edit, disable, and reset accounts. Override the port with
`LAM_PORT=9090 docker compose up -d lam`.

## 4. Staff-portal API + Swagger (create & seed new org directories)

Runs on your **host**, not in Docker; it shells into `samba-dc`.

One-time setup (durable venv recommended over the ephemeral `/tmp` default):

```bash
python3 -m venv .venv
.venv/bin/pip install -r staff-portal/backend/requirements.txt
```

Launch (no auth → binds `127.0.0.1:8099`):

```bash
PYTHON=$PWD/.venv/bin/python UVICORN=$PWD/.venv/bin/uvicorn ./staff-portal/run.sh
```

Open **http://localhost:8099/docs** — the Swagger UI is the interface.

Endpoints:

- `GET /health` — liveness.
- `GET /domains` — list OUs.
- `POST /domains` — create a nested OU from an FQDN and seed it. Body:

  ```json
  { "fqdn": "orange.rmorse.com", "user_count": 20, "dry_run": true }
  ```

  Run with **`dry_run: true` first** — it returns the exact `samba-tool` commands
  without touching the DC. Set `dry_run: false` (or omit it) to actually seed.

  `orange.rmorse.com` becomes `OU=orange,OU=rmorse`; users get clean
  `testuser<i>@orange.rmorse.com` mail + UPN, and a hash-suffixed
  `sAMAccountName` (e.g. `testuser1_4e2a`).

Expose on the network with a login (binds `0.0.0.0:8099`, HTTP Basic):

```bash
STAFF_PORTAL_USER=staff STAFF_PORTAL_PASS=secret \
PYTHON=$PWD/.venv/bin/python UVICORN=$PWD/.venv/bin/uvicorn ./staff-portal/run.sh
```

Fail-safe: the app refuses to bind a non-loopback address without auth. Swagger's
"Authorize" button handles the Basic login.

Other env vars: `STAFF_PORTAL_CONTAINER` (default `samba-dc`),
`STAFF_PORTAL_BASE_DN` (default `dc=wigitron,dc=com`), `STAFF_PORTAL_MAX_USERS`
(default 500, hard-capped at 500 by the model), `STAFF_PORTAL_PORT` (default 8099).

## 5. Consolidate a separate-port domain into an OU (export / import)

```bash
./export_directory.sh samba-dc-international intl.json             # dump a live DC's structure (read-only)
./import_as_ou.sh international intl.json --prefix intl --dry-run   # preview the samba-tool commands
./import_as_ou.sh international intl.json --prefix intl             # import into the main DC as OU=international
```

Passwords are re-set on import (AD cannot export plaintext): `testuser<N>` →
`Password!<N>`, everything else → `Admin!Test1234`.

## Teardown

```bash
docker compose down        # stop, keep data in volumes
docker compose down -v     # wipe everything (fresh provision next start)
```

## Notes / gotchas

- `/tmp/sap-venv` is the `run.sh` default but `/tmp` is ephemeral; use a durable
  `.venv` and point at it with `PYTHON` / `UVICORN` as shown above.
- The staff-portal is **create-only** by design — editing/deleting accounts is
  done in LAM, not the API.
- samba-tool quirks the seeder handles (relevant if you script against the DC
  directly): `--userou`/`--groupou` take an OU path **relative** to the base DN
  (not a full DN), `user create` has **no** `--user-principal-name` flag (set it
  with `user rename --upn=`), and a clean UPN suffix must be registered first via
  `domain trust namespaces --add-upn-suffix=<fqdn>`.
