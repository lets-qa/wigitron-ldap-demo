# Staff Portal

A small FastAPI tool for seeding a Samba AD test directory. It creates an OU
tree plus users and groups for a domain by driving `samba-tool` inside the DC
container. Create-only: it does not edit or delete anything.

## Setup

    python3 -m venv .venv && .venv/bin/pip install -r staff-portal/backend/requirements.txt

`run.sh` honors a `PYTHON` env var (default `/tmp/sap-venv/bin/python`) and
`UVICORN` (default `/tmp/sap-venv/bin/uvicorn`). `/tmp` is ephemeral and not
for durable use, so point at your own venv, e.g.
`PYTHON=$PWD/.venv/bin/python UVICORN=$PWD/.venv/bin/uvicorn bash staff-portal/run.sh`.

## Run

    bash staff-portal/run.sh

`run.sh` computes the bind host from `app.config.load_settings` (never
hardcoded), then execs uvicorn. Override interpreter with `PYTHON` and
`UVICORN` (default `/tmp/sap-venv/bin/...`).

## Environment variables

| Variable | Default | Meaning |
|---|---|---|
| `STAFF_PORTAL_USER` | unset | HTTP Basic auth user |
| `STAFF_PORTAL_PASS` | unset | HTTP Basic auth password |
| `STAFF_PORTAL_BIND` | derived | Explicit bind host |
| `STAFF_PORTAL_CONTAINER` | `samba-dc` | Docker container running samba-tool |
| `STAFF_PORTAL_BASE_DN` | `dc=wigitron,dc=com` | Base DN |
| `STAFF_PORTAL_MAX_USERS` | `500` | Secondary cap on `user_count`. The model hard-caps `user_count` at 500 (422 above that), so this can only LOWER the effective cap, never raise it |
| `STAFF_PORTAL_PORT` | `8099` | Port (read by run.sh) |

## Auth / bind coupling and fail-safe

- Both USER and PASS set: auth is on, bind defaults to `0.0.0.0`.
- Partial or no auth: auth is off, bind defaults to `127.0.0.1`.
- `STAFF_PORTAL_BIND` set to a non-loopback address WITHOUT auth: startup
  raises `RuntimeError` (the portal refuses to expose an unauthenticated API).

## Swagger

Open `http://<bind>:${STAFF_PORTAL_PORT:-8099}/docs`. When bind is `0.0.0.0`, use the host's address or `127.0.0.1`.

Endpoints: `GET /health` (open, unauthenticated), `GET /domains` (read-only list), `POST /domains` (create).

## POST /domains

Body:

    {"fqdn": "orange.rmorse.com", "user_count": 20, "dry_run": true}

**WARNING: `dry_run` defaults to false. A request without it performs a live seed. Pass `dry_run: true` to preview the samba-tool commands without executing.**

- `fqdn` required; `user_count` defaults to 20 (bounded by MAX_USERS);
  `dry_run` returns the plan/summary without executing.
- Creates a nested OU (e.g. `OU=orange,OU=rmorse,dc=wigitron,dc=com`), parent first.
- mail and UPN are the clean `testuser<i>@<fqdn>`; sAMAccountName is
  hash-suffixed (max 20 chars) to stay unique.

## Non-goals

Create-only. Management (edit/delete/browse) is done via LAM, not this API.

## Known limitations / first-live-run checks

- The live `samba-tool` run (dry_run=false) needs Docker and a DC and is NOT
  automated here; run a dry run, then a real seed, manually.
- RISK: `--userou/--groupou` is passed a FULL DN
  (`OU=orange,OU=rmorse,dc=wigitron,dc=com`), and `ou create` also receives the full DN (same relative-vs-full question). samba-tool may expect an OU path
  RELATIVE to the base DN, which would double the base. On first live run,
  verify; if it doubles, strip the `base_dn` suffix from the value (for OU creation too).
