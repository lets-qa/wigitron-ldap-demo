# Staff Portal API — Domain/Org Create & Seed

**Date:** 2026-10-19
**Status:** Draft for review
**Branch:** `fix/admin-no-expiry`

## Purpose

A small internal **staff tool** for creating and seeding test directories in the
single Samba AD DC. Staff name a domain or sub-host org (e.g. `rmorse.com`,
`orange.rmorse.com`); the API creates the corresponding Organizational Unit in
the existing DC and seeds the standard account/group structure — the same thing
`seed_directory.sh` does, exposed over HTTP.

The interface is **FastAPI's built-in Swagger UI** (`/docs`). There is no custom
frontend. Management of existing accounts is explicitly out of scope — that is
what the LAM web GUI is for. This API only **creates and seeds**.

## Intended outcome (design brief)

- **Who:** internal staff running the LDAP test rig.
- **What success looks like:** a staff member opens Swagger, calls `POST /domains`
  with an FQDN and optional user count, and a new nested OU appears in the DC,
  populated with deterministic users and groups whose mail/UPN match the FQDN.
- **Explicitly NOT in scope:** editing, deleting, or listing individual accounts;
  password management; spinning up new containers; multi-DC orchestration.

## Key decisions (confirmed with stakeholder)

1. **OU model, not new containers.** The API execs `samba-tool` against the one
   existing `samba-dc` container. It never orchestrates Docker.
2. **Nested OU mapping.** `rmorse.com` → `OU=rmorse`; `orange.rmorse.com` →
   `OU=orange,OU=rmorse`. Parent OUs are auto-created if absent. This mirrors
   the hostname hierarchy, consistent with how Exchange treats object placement.
3. **Full-FQDN mail/UPN.** Each org is its own accepted-domain SMTP namespace:
   users in `orange.rmorse.com` get `user@orange.rmorse.com`; users in
   `rmorse.com` get `user@rmorse.com`.
4. **Deterministic group allocation (no randomness).** See "Allocation rule".
   The existing scripts are already deterministic; this generalizes the
   hardcoded 1–10/11–20 ranges into a rule that scales to any N.
5. **Shared allocation source of truth (option A).** Authoritative rule in
   `allocate.py` (used by the API), mirrored by `lib/allocate.sh` (used by the
   shell seed scripts), with a parity test asserting identical output.
6. **Synchronous execution.** `POST /domains` blocks until seeding completes and
   returns a summary. User count is capped (default 20, max 500) to keep request
   duration bounded.
7. **Access control / bind coupling:**
   - Default (no auth env set): HTTP Basic disabled, bind `127.0.0.1` only.
   - Auth enabled (`STAFF_PORTAL_USER` + `STAFF_PORTAL_PASS` set): HTTP Basic
     required, bind `0.0.0.0` (any interface).
   - **Fail-safe:** if configured to bind a non-loopback address while auth is
     disabled, the app refuses to start.
8. **Host-side execution.** The API runs on the host (like the scripts) and
   shells out to `docker exec samba-dc samba-tool ...`. No raw LDAP.

## Allocation rule (authoritative definition)

Given `N` users (`testuser1 .. testuserN`) in an org:

- `All_Company` — **every** user (1..N).
- `Dev_Team` — first half: users `1 .. floor(N/2)`.
- `QA_Team` — second half: users `floor(N/2)+1 .. N`.
- `All_Engineering` — nests `Dev_Team` and `QA_Team` (contains no users directly).
- `Support_Team` — first proportional quarter: users `1 .. floor(N/4)`.
- `Marketing_Team` — next proportional quarter: users `floor(N/4)+1 .. floor(N/2)`.

Worked examples:

| N | Dev_Team | QA_Team | Support_Team | Marketing_Team |
|---|---|---|---|---|
| 20 | 1–10 | 11–20 | 1–5 | 6–10 |
| 50 | 1–25 | 26–50 | 1–12 | 13–25 |
| 1 | 1 | — | — | — |
| 2 | 1 | 2 | — | 1 |

Edge behavior: with small N some teams may be empty (floor division). That is
acceptable and deterministic. `All_Company` always contains everyone.
`Support_Team`/`Marketing_Team` are subsets of the Dev (first-half) range,
matching today's 1–5 / 6–10 intent.

This rule is identical in `allocate.py` and `lib/allocate.sh`; the parity test
is the guard against drift.

## Architecture

```
staff-portal/
  backend/
    app/
      __init__.py
      main.py          # FastAPI app, endpoints, auth + bind wiring
      allocate.py      # authoritative allocation rule (pure, no I/O)
      seeder.py        # builds and runs samba-tool commands via docker exec
      models.py        # pydantic request/response models
      config.py        # env parsing: auth creds, container name, bind host, caps
    tests/
      test_allocate.py # unit tests for the rule
      test_seeder.py   # command-plan tests (no Docker; assert generated argv)
      test_api.py      # endpoint tests with seeder mocked
    requirements.txt
    README.md
  lib/
    allocate.sh        # shell mirror of the allocation rule
  tests/
    test_parity.sh     # asserts allocate.py and allocate.sh agree for many N
```

The existing `seed_directory.sh` / `seed_ou.sh` are refactored to source
`lib/allocate.sh` instead of hardcoding ranges. Behavior for N=20 is unchanged
(regression-checked against the current 1–10/11–20 layout).

### Components and responsibilities

- **`allocate.py`** — pure function `allocate(n) -> {group: [user_indices]}`.
  No I/O, no Docker. Fully unit-tested. The single source of truth in code.
- **`lib/allocate.sh`** — shell function emitting the same assignments (e.g.
  `allocate_group dev N` → index range). Mirrors `allocate.py`.
- **`seeder.py`** — translates an org request into an ordered list of
  `samba-tool` argv vectors (OU create for each path segment, group adds, user
  creates with FQDN mail, membership adds, `--noexpiry`), then executes them via
  `docker exec`. Collects per-command success/failure. A `dry_run` flag returns
  the plan without executing (mirrors `import_as_ou.sh --dry-run`; used in tests
  and optionally exposed as a query param).
- **`main.py`** — endpoints, Basic-auth dependency (active only when configured),
  startup bind/auth fail-safe check.

## API surface

| Method | Path | Purpose |
|---|---|---|
| `GET` | `/health` | Liveness. Always open (no auth), returns `{status:"ok"}`. |
| `GET` | `/domains` | List existing OUs (read-only), so staff see current state. |
| `POST` | `/domains` | Create nested OU + seed. Synchronous. Returns summary. |

### `POST /domains`

Request:
```json
{ "fqdn": "orange.rmorse.com", "user_count": 20, "dry_run": false }
```

- `fqdn` (required): validated against a hostname regex; lowercased. Rejected if
  malformed.
- `user_count` (optional, default 20): integer 1–500.
- `dry_run` (optional, default false): if true, returns the planned `samba-tool`
  commands without executing.

Response (200):
```json
{
  "fqdn": "orange.rmorse.com",
  "ou_dn": "OU=orange,OU=rmorse,dc=wigitron,dc=com",
  "mail_domain": "orange.rmorse.com",
  "created": { "users": 20, "groups": 5 },
  "skipped": [],
  "errors": []
}
```

- Partial failures: individual `samba-tool` errors are collected into `errors[]`
  rather than aborting the whole seed (idempotent re-run friendly). HTTP stays
  200 with a populated `errors[]`; a total failure (e.g. container unreachable)
  returns 502.
- Input validation failures return 422 (pydantic) or 400.

### Naming / uniqueness

AD requires `sAMAccountName` and group names to be unique **domain-wide**. Object
names are slug-prefixed with the org slug derived from the FQDN (same convention
as `seed_ou.sh` / `import_as_ou.sh`): e.g. `orangermorsecom_testuser1`,
`orangermorsecom_Dev_Team`. Mail/UPN uses the real FQDN and is unaffected by the
prefix. (Prefix derivation and collision behavior match the existing scripts.)

## Configuration (env)

| Var | Default | Effect |
|---|---|---|
| `STAFF_PORTAL_USER` | unset | Basic-auth username. Setting both user+pass enables auth. |
| `STAFF_PORTAL_PASS` | unset | Basic-auth password. |
| `STAFF_PORTAL_BIND` | derived | Bind host. Derived: `127.0.0.1` if auth off, `0.0.0.0` if auth on. Explicit override honored only if it passes the fail-safe. |
| `STAFF_PORTAL_CONTAINER` | `samba-dc` | DC container to exec against. |
| `STAFF_PORTAL_BASE_DN` | `dc=wigitron,dc=com` | Base DN for OU placement. |
| `STAFF_PORTAL_MAX_USERS` | `500` | Upper bound on `user_count`. |

Startup fail-safe: if the resolved bind is not loopback AND auth is disabled, the
app logs an error and exits non-zero.

## Error handling

- Container unreachable / `docker exec` fails entirely → 502 with detail.
- Malformed FQDN or out-of-range `user_count` → 422/400.
- Per-object `samba-tool` failure → captured in `errors[]`, seed continues, 200.
- Auth required but missing/wrong → 401 (Basic challenge).

## Testing strategy

- **`test_allocate.py`** — the rule for N = 1, 2, 3, 4, 20, 50, odd values;
  asserts All_Company=all, halves/quarters correct, no overlaps beyond spec.
- **`test_seeder.py`** — given an org request, assert the generated `samba-tool`
  argv plan: OU-per-segment creation order, FQDN mail, prefixing, membership,
  `--noexpiry`. No Docker — inspect the plan from `dry_run`.
- **`test_api.py`** — endpoint behavior with `seeder` mocked: validation,
  auth on/off, fail-safe bind logic, response shape, error aggregation.
- **`test_parity.sh`** — run `allocate.py` and `lib/allocate.sh` across many N and
  diff; fail on any mismatch. This is the anti-drift guard for option A.
- **Regression:** confirm refactored `seed_directory.sh` still yields 1–10/11–20
  for N=20 (dry comparison against current output).

Live run against a real DC remains a manual step (no Docker in this environment);
`dry_run` plan inspection is the automated substitute.

## Non-goals

- No account edit/delete/list of individual users. No password reset endpoints.
- No container lifecycle management. No DNS/realm creation.
- No custom frontend — Swagger `/docs` is the UI.
- No async job system — synchronous only.

## Open risks

- **samba-tool flag fidelity:** `seeder.py` must match the exact flags the shell
  scripts use (`--userou`, `--groupou`, `--use-rfc2307` implications, mail). Will
  be cross-checked against the existing scripts during implementation.
- **Nested OU creation order:** each FQDN segment's OU must be created
  parent-first. Covered in `test_seeder.py`.
- **Unverified live:** as with the rest of this branch, end-to-end against a live
  DC is not runnable here; dry-run plans are the validation proxy.
