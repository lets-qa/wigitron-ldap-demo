# Staff Portal

A small FastAPI tool for seeding a Samba AD test directory. It creates an OU
tree plus users and groups for a domain by driving `samba-tool` inside the DC
container. Create-only: it does not edit or delete anything.

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
| `STAFF_PORTAL_MAX_USERS` | `500` | Upper bound for `user_count` |
| `STAFF_PORTAL_PORT` | `8099` | Port (read by run.sh) |

## Auth / bind coupling and fail-safe

- Both USER and PASS set: auth is on, bind defaults to `0.0.0.0`.
- Partial or no auth: auth is off, bind defaults to `127.0.0.1`.
- `STAFF_PORTAL_BIND` set to a non-loopback address WITHOUT auth: startup
  raises `RuntimeError` (the portal refuses to expose an unauthenticated API).

## Swagger

Open `http://<bind>:8099/docs`.

## POST /domains

Body:

    {"fqdn": "orange.rmorse.com", "user_count": 20, "dry_run": true}

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
  (`OU=orange,OU=rmorse,dc=wigitron,dc=com`). samba-tool may expect an OU path
  RELATIVE to the base DN, which would double the base. On first live run,
  verify; if it doubles, strip the `base_dn` suffix from the value.
