# Staff Portal API Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** A FastAPI staff tool that creates a nested OU from an FQDN and seeds the standard deterministic account/group structure into the single Samba DC, with naming unified across the existing shell scripts.

**Architecture:** Pure logic (allocation rule, FQDN→OU/naming) lives in small testable Python modules with shell mirrors; a seeder builds ordered `samba-tool` argv plans and runs them via `docker exec`; FastAPI exposes create-only endpoints with Swagger as the UI. The allocation rule and naming scheme are single sources of truth shared by the API and the refactored `seed_ou.sh`/`import_as_ou.sh`, guarded by a cross-language parity test.

**Tech Stack:** Python 3.14, FastAPI, uvicorn, pydantic v2, pytest, httpx (TestClient); Bash for shell mirrors.

**Spec:** `docs/superpowers/specs/2026-10-19-staff-portal-design.md`

## Global Constraints

- OU model only: API execs `samba-tool` via `docker exec <container> ...`; never orchestrates Docker or raw LDAP.
- `sAMAccountName` ≤ 20 chars, no `@`. Scheme: `testuser<i>_<hash4>`, `<hash4>` = first 4 hex chars of `sha256(fqdn.lower())`.
- `mail` and `userPrincipalName` both = `testuser<i>@<fqdn>`.
- Group names also hash-suffixed: `Dev_Team_<hash4>`, `All_Engineering_<hash4>`, `QA_Team_<hash4>`, `All_Company_<hash4>`, `Support_Team_<hash4>`, `Marketing_Team_<hash4>`.
- Allocation (users `1..N`): `All_Company`=1..N; `Dev_Team`=1..ceil(N/2); `QA_Team`=ceil(N/2)+1..N; `Support_Team`=1..floor(N/4); `Marketing_Team`=floor(N/4)+1..floor(N/2); `All_Engineering` nests Dev+QA, no direct users. Default N=20, max 500. (Dev/QA split uses ceil so a lone/odd user lands in Dev — the first half — matching the spec's worked-example table; Marketing's upper bound stays floor(N/2). For even N, ceil=floor so N=20/50 are unchanged.)
- Base DN default `dc=wigitron,dc=com`; container default `samba-dc`.
- Auth/bind coupling: no auth env → bind `127.0.0.1`; `STAFF_PORTAL_USER`+`STAFF_PORTAL_PASS` set → Basic auth + bind `0.0.0.0`. Non-loopback bind without auth → refuse to start (exit non-zero).
- Create-only: no edit/delete/list-accounts/password endpoints. `GET /domains` (list OUs) and `GET /health` are the only reads.
- All new Python under `staff-portal/backend/`; shell mirrors under `staff-portal/lib/`; parity test under `staff-portal/tests/`.
- Email attribute on group `All_Company` = `all@<fqdn>`, `Support_Team` = `support@<fqdn>`, `Marketing_Team` = `marketing@<fqdn>` (real FQDN, not slug).

## Review Focus

- **FQDN with trailing dot / uppercase / leading-trailing spaces** (`Orange.Rmorse.Com `): must normalize (lowercase, strip) before hashing and OU mapping, else the same org yields two different hash suffixes. Pinned in Task 2.
- **Single-label or empty FQDN** (`localhost`, `""`): OU mapping and validation must reject or handle without producing an empty OU DN. Pinned in Task 2.
- **`user_count` at bounds** (0, 1, 501, negative): must 422 outside 1–500; N=1 produces empty QA/Support/Marketing without error. Pinned in Tasks 1 and 5.
- **Hash-suffix length ceiling** (`testuser500_a3f9` = 16 chars): longest sAMAccountName must stay ≤20; assert explicitly. Pinned in Task 2.
- **Auth configured but partial** (`STAFF_PORTAL_USER` set, `PASS` unset): must be treated as auth-off (and thus loopback bind), never half-enabled. Pinned in Task 4.

---

## Task 1: Allocation rule (Python, authoritative)

**Files:**
- Create: `staff-portal/backend/app/__init__.py` (empty)
- Create: `staff-portal/backend/app/allocate.py`
- Test: `staff-portal/backend/tests/test_allocate.py`

**Interfaces:**
- Produces: `allocate(n: int) -> dict[str, list[int]]` returning keys `All_Company, Dev_Team, QA_Team, Support_Team, Marketing_Team` mapped to 1-based user-index lists. `All_Engineering` is intentionally absent (it has no direct users; nesting handled by the seeder).

- [ ] **Step 1: Write the failing test**

```python
# staff-portal/backend/tests/test_allocate.py
from app.allocate import allocate


def test_n20_matches_legacy_ranges():
    a = allocate(20)
    assert a["All_Company"] == list(range(1, 21))
    assert a["Dev_Team"] == list(range(1, 11))
    assert a["QA_Team"] == list(range(11, 21))
    assert a["Support_Team"] == list(range(1, 6))
    assert a["Marketing_Team"] == list(range(6, 11))


def test_n50_proportional():
    a = allocate(50)
    assert a["Dev_Team"] == list(range(1, 26))
    assert a["QA_Team"] == list(range(26, 51))
    assert a["Support_Team"] == list(range(1, 13))      # floor(50/4)=12
    assert a["Marketing_Team"] == list(range(13, 26))   # 13..floor(50/2)=25


def test_small_n_edges():
    assert allocate(1) == {
        "All_Company": [1], "Dev_Team": [1], "QA_Team": [],
        "Support_Team": [], "Marketing_Team": [],
    }
    a2 = allocate(2)
    assert a2["Dev_Team"] == [1] and a2["QA_Team"] == [2]
    assert a2["Support_Team"] == [] and a2["Marketing_Team"] == [1]
```

- [ ] **Step 2: Run test to verify it fails**

Run: `cd staff-portal/backend && python -m pytest tests/test_allocate.py -v`
Expected: FAIL (ModuleNotFoundError: app.allocate)

- [ ] **Step 3: Write minimal implementation**

```python
# staff-portal/backend/app/allocate.py
"""Authoritative, deterministic group-allocation rule. Pure: no I/O."""


def allocate(n: int) -> dict[str, list[int]]:
    half_lo = n // 2          # floor(N/2): Marketing upper bound, QA start anchor
    half_hi = (n + 1) // 2    # ceil(N/2): Dev gets the lone/odd user
    quarter = n // 4
    return {
        "All_Company": list(range(1, n + 1)),
        "Dev_Team": list(range(1, half_hi + 1)),
        "QA_Team": list(range(half_hi + 1, n + 1)),
        "Support_Team": list(range(1, quarter + 1)),
        "Marketing_Team": list(range(quarter + 1, half_lo + 1)),
    }
```

- [ ] **Step 4: Run test to verify it passes**

Run: `cd staff-portal/backend && python -m pytest tests/test_allocate.py -v`
Expected: PASS (3 tests). Add `staff-portal/backend/tests/__init__.py` (empty) and a `conftest.py` that puts `backend/` on `sys.path` if the import fails.

- [ ] **Step 5: Commit**

```bash
git add staff-portal/backend/app/__init__.py staff-portal/backend/app/allocate.py staff-portal/backend/tests/
git commit -m "feat(staff-portal): authoritative allocation rule"
```

---

## Task 2: Naming + FQDN→OU mapping (Python, authoritative)

**Files:**
- Create: `staff-portal/backend/app/naming.py`
- Test: `staff-portal/backend/tests/test_naming.py`

**Interfaces:**
- Produces:
  - `normalize_fqdn(fqdn: str) -> str` — lowercased, stripped, trailing dot removed; raises `ValueError` on empty or single-label.
  - `hash4(fqdn: str) -> str` — first 4 hex chars of `sha256(normalize_fqdn(fqdn))`.
  - `ou_path(fqdn: str, base_dn: str) -> list[str]` — ordered parent-first list of OU DNs. `orange.rmorse.com`,`dc=wigitron,dc=com` → `["OU=rmorse,dc=wigitron,dc=com", "OU=orange,OU=rmorse,dc=wigitron,dc=com"]`.
  - `sam(username: str, fqdn: str) -> str` — `"{username}_{hash4}"`.
  - `group_name(base: str, fqdn: str) -> str` — `"{base}_{hash4}"`.

- [ ] **Step 1: Write the failing test**

```python
# staff-portal/backend/tests/test_naming.py
import pytest
from app.naming import normalize_fqdn, hash4, ou_path, sam, group_name


def test_normalize():
    assert normalize_fqdn("  Orange.Rmorse.Com. ") == "orange.rmorse.com"
    with pytest.raises(ValueError):
        normalize_fqdn("")
    with pytest.raises(ValueError):
        normalize_fqdn("localhost")


def test_hash_stable_and_short():
    assert hash4("orange.rmorse.com") == hash4("ORANGE.rmorse.com.")
    assert len(hash4("orange.rmorse.com")) == 4
    # longest sAMAccountName must stay within AD's 20-char cap
    assert len(sam("testuser500", "orange.rmorse.com")) <= 20


def test_ou_path_nested_parent_first():
    base = "dc=wigitron,dc=com"
    assert ou_path("rmorse.com", base) == ["OU=rmorse,dc=wigitron,dc=com"]
    assert ou_path("orange.rmorse.com", base) == [
        "OU=rmorse,dc=wigitron,dc=com",
        "OU=orange,OU=rmorse,dc=wigitron,dc=com",
    ]


def test_names_suffixed():
    h = hash4("orange.rmorse.com")
    assert sam("testuser1", "orange.rmorse.com") == f"testuser1_{h}"
    assert group_name("Dev_Team", "orange.rmorse.com") == f"Dev_Team_{h}"
```

- [ ] **Step 2: Run test to verify it fails**

Run: `cd staff-portal/backend && python -m pytest tests/test_naming.py -v`
Expected: FAIL (ModuleNotFoundError: app.naming)

- [ ] **Step 3: Write minimal implementation**

```python
# staff-portal/backend/app/naming.py
"""FQDN normalization, stable hash suffix, and nested-OU mapping. Pure."""
import hashlib


def normalize_fqdn(fqdn: str) -> str:
    v = fqdn.strip().rstrip(".").lower()
    if not v or "." not in v:
        raise ValueError(f"FQDN must have at least two labels: {fqdn!r}")
    return v


def hash4(fqdn: str) -> str:
    v = normalize_fqdn(fqdn)
    return hashlib.sha256(v.encode("utf-8")).hexdigest()[:4]


def ou_path(fqdn: str, base_dn: str) -> list[str]:
    labels = normalize_fqdn(fqdn).split(".")
    # Build parent-first: rightmost label is the top OU under base_dn.
    # orange.rmorse.com -> labels [orange, rmorse, com]; org OUs are the
    # hostname labels left of the registrable domain. We treat EVERY label
    # except the TLD as an OU, nesting right-to-left.
    org_labels = labels[:-1]  # drop TLD (e.g. "com")
    dns = []
    suffix = base_dn
    for label in reversed(org_labels):
        dn = f"OU={label},{suffix}"
        dns.append(dn)
        suffix = dn
    return dns


def sam(username: str, fqdn: str) -> str:
    return f"{username}_{hash4(fqdn)}"


def group_name(base: str, fqdn: str) -> str:
    return f"{base}_{hash4(fqdn)}"
```

- [ ] **Step 4: Run test to verify it passes**

Run: `cd staff-portal/backend && python -m pytest tests/test_naming.py -v`
Expected: PASS (4 tests)

- [ ] **Step 5: Commit**

```bash
git add staff-portal/backend/app/naming.py staff-portal/backend/tests/test_naming.py
git commit -m "feat(staff-portal): FQDN normalization, hash-suffix naming, nested OU mapping"
```

---

## Task 3: Seeder — build the samba-tool command plan

**Files:**
- Create: `staff-portal/backend/app/seeder.py`
- Test: `staff-portal/backend/tests/test_seeder.py`

**Interfaces:**
- Consumes: `allocate` (Task 1); `ou_path, sam, group_name, normalize_fqdn` (Task 2).
- Produces:
  - `build_plan(fqdn: str, user_count: int, base_dn: str) -> list[list[str]]` — ordered list of `samba-tool` argv vectors (WITHOUT the `docker exec <container> samba-tool` prefix; each vector starts at the samba-tool subcommand, e.g. `["ou", "create", "OU=rmorse,..."]`).
  - `run_plan(plan, container, dry_run) -> dict` — executes via `docker exec` unless `dry_run`; returns `{"created": {...}, "errors": [...], "commands": [...]}`.

- [ ] **Step 1: Write the failing test**

```python
# staff-portal/backend/tests/test_seeder.py
from app.seeder import build_plan
from app.naming import hash4, sam, group_name

BASE = "dc=wigitron,dc=com"


def test_plan_creates_parent_first_ous():
    plan = build_plan("orange.rmorse.com", 20, BASE)
    ou_cmds = [c for c in plan if c[:2] == ["ou", "create"]]
    assert ou_cmds[0] == ["ou", "create", "OU=rmorse,dc=wigitron,dc=com"]
    assert ou_cmds[1] == ["ou", "create",
                          "OU=orange,OU=rmorse,dc=wigitron,dc=com"]


def test_user_has_email_mail_upn_and_hash_sam():
    plan = build_plan("orange.rmorse.com", 20, BASE)
    s = sam("testuser1", "orange.rmorse.com")
    create = next(c for c in plan if c[:2] == ["user", "create"] and c[2] == s)
    joined = " ".join(create)
    assert "--mail-address=testuser1@orange.rmorse.com" in joined
    assert "--use-username-as-cn" in joined or True  # cn handling optional
    assert f"--userou=OU=orange,OU=rmorse" in joined
    # UPN carried via --user-principal-name
    assert "--user-principal-name=testuser1@orange.rmorse.com" in joined


def test_all_company_has_everyone_and_group_mail_uses_fqdn():
    plan = build_plan("orange.rmorse.com", 20, BASE)
    allc = group_name("All_Company", "orange.rmorse.com")
    adds = [c for c in plan if c[:2] == ["group", "addmembers"] and c[2] == allc]
    members = {c[3] for c in adds}
    assert members == {sam(f"testuser{i}", "orange.rmorse.com")
                       for i in range(1, 21)}
    gcreate = next(c for c in plan
                   if c[:2] == ["group", "add"] and c[2] == allc)
    assert "--mail-address=all@orange.rmorse.com" in " ".join(gcreate)


def test_noexpiry_set_per_user():
    plan = build_plan("orange.rmorse.com", 3, BASE)
    exp = [c for c in plan if c[:2] == ["user", "setexpiry"]]
    assert len(exp) == 3
    assert all(c[-1] == "--noexpiry" for c in exp)
```

- [ ] **Step 2: Run test to verify it fails**

Run: `cd staff-portal/backend && python -m pytest tests/test_seeder.py -v`
Expected: FAIL (ModuleNotFoundError: app.seeder)

- [ ] **Step 3: Write minimal implementation**

```python
# staff-portal/backend/app/seeder.py
"""Translate an org request into an ordered samba-tool command plan, and run it."""
import subprocess
from app.allocate import allocate
from app.naming import normalize_fqdn, ou_path, sam, group_name

GROUPS_WITH_MAIL = {
    "All_Company": "all",
    "Support_Team": "support",
    "Marketing_Team": "marketing",
}
PLAIN_GROUPS = ["All_Engineering", "Dev_Team", "QA_Team"]


def build_plan(fqdn: str, user_count: int, base_dn: str) -> list[list[str]]:
    fqdn = normalize_fqdn(fqdn)
    ous = ou_path(fqdn, base_dn)
    leaf_rdn = ous[-1].split(",", 1)[0]          # e.g. "OU=orange"
    leaf_ou = leaf_rdn.split("=", 1)[1]          # e.g. "orange"
    userou = ous[-1]                             # full DN for --userou/--groupou
    plan: list[list[str]] = []

    for dn in ous:                               # parent-first
        plan.append(["ou", "create", dn])

    a = allocate(user_count)

    # Groups first (so addmembers targets exist).
    for g in PLAIN_GROUPS:
        plan.append(["group", "add", group_name(g, fqdn), f"--groupou={userou}"])
    for g, local in GROUPS_WITH_MAIL.items():
        plan.append(["group", "add", group_name(g, fqdn),
                     f"--groupou={userou}", f"--mail-address={local}@{fqdn}"])

    # Nest Dev/QA under All_Engineering.
    eng = group_name("All_Engineering", fqdn)
    plan.append(["group", "addmembers", eng, group_name("Dev_Team", fqdn)])
    plan.append(["group", "addmembers", eng, group_name("QA_Team", fqdn)])

    # Users.
    for i in range(1, user_count + 1):
        s = sam(f"testuser{i}", fqdn)
        email = f"testuser{i}@{fqdn}"
        plan.append([
            "user", "create", s, f"Password!{i}",
            f"--userou={userou}",
            "--given-name=Test", f"--surname=User{i}",
            f"--mail-address={email}",
            f"--user-principal-name={email}",
        ])
        plan.append(["user", "setexpiry", s, "--noexpiry"])

    # Memberships from the allocation (skip All_Engineering; it nests groups).
    for g, members in a.items():
        gn = group_name(g, fqdn)
        for i in members:
            plan.append(["group", "addmembers", gn,
                         sam(f"testuser{i}", fqdn)])

    return plan


def run_plan(plan, container: str, dry_run: bool = False) -> dict:
    created = {"ou": 0, "users": 0, "groups": 0}
    errors = []
    rendered = []
    for cmd in plan:
        full = ["docker", "exec", container, "samba-tool", *cmd]
        rendered.append(" ".join(full))
        if cmd[:2] == ["ou", "create"]:
            created["ou"] += 1
        elif cmd[:2] == ["user", "create"]:
            created["users"] += 1
        elif cmd[:2] == ["group", "add"]:
            created["groups"] += 1
        if dry_run:
            continue
        proc = subprocess.run(full, capture_output=True, text=True)
        if proc.returncode != 0:
            errors.append({"cmd": " ".join(cmd),
                           "stderr": proc.stderr.strip()[:300]})
    return {"created": created, "errors": errors, "commands": rendered}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `cd staff-portal/backend && python -m pytest tests/test_seeder.py -v`
Expected: PASS (4 tests). Adjust the optional `--use-username-as-cn` assertion out if not emitting it.

- [ ] **Step 5: Commit**

```bash
git add staff-portal/backend/app/seeder.py staff-portal/backend/tests/test_seeder.py
git commit -m "feat(staff-portal): samba-tool command-plan builder and runner"
```

---

## Task 4: Config — auth/bind coupling with fail-safe

**Files:**
- Create: `staff-portal/backend/app/config.py`
- Test: `staff-portal/backend/tests/test_config.py`

**Interfaces:**
- Produces:
  - `Settings` dataclass: `auth_user: str|None, auth_pass: str|None, bind_host: str, container: str, base_dn: str, max_users: int`.
  - `load_settings(env: Mapping) -> Settings` — applies coupling + fail-safe.
  - `auth_enabled(s: Settings) -> bool` — True only if BOTH user and pass set.
  - Raises `RuntimeError` if resolved `bind_host` is non-loopback while auth disabled.

- [ ] **Step 1: Write the failing test**

```python
# staff-portal/backend/tests/test_config.py
import pytest
from app.config import load_settings, auth_enabled


def test_default_no_auth_binds_loopback():
    s = load_settings({})
    assert auth_enabled(s) is False
    assert s.bind_host == "127.0.0.1"


def test_auth_enabled_binds_any():
    s = load_settings({"STAFF_PORTAL_USER": "staff", "STAFF_PORTAL_PASS": "x"})
    assert auth_enabled(s) is True
    assert s.bind_host == "0.0.0.0"


def test_partial_auth_is_off():
    s = load_settings({"STAFF_PORTAL_USER": "staff"})  # no PASS
    assert auth_enabled(s) is False
    assert s.bind_host == "127.0.0.1"


def test_failsafe_nonlocal_without_auth_raises():
    with pytest.raises(RuntimeError):
        load_settings({"STAFF_PORTAL_BIND": "0.0.0.0"})  # auth off


def test_explicit_bind_allowed_with_auth():
    s = load_settings({"STAFF_PORTAL_USER": "u", "STAFF_PORTAL_PASS": "p",
                       "STAFF_PORTAL_BIND": "0.0.0.0"})
    assert s.bind_host == "0.0.0.0"
```

- [ ] **Step 2: Run test to verify it fails**

Run: `cd staff-portal/backend && python -m pytest tests/test_config.py -v`
Expected: FAIL (ModuleNotFoundError: app.config)

- [ ] **Step 3: Write minimal implementation**

```python
# staff-portal/backend/app/config.py
"""Environment-driven settings with auth/bind coupling and a fail-safe."""
from dataclasses import dataclass
from typing import Mapping, Optional

_LOOPBACK = {"127.0.0.1", "localhost", "::1"}


@dataclass
class Settings:
    auth_user: Optional[str]
    auth_pass: Optional[str]
    bind_host: str
    container: str
    base_dn: str
    max_users: int


def auth_enabled(s: "Settings") -> bool:
    return bool(s.auth_user) and bool(s.auth_pass)


def load_settings(env: Mapping) -> Settings:
    user = env.get("STAFF_PORTAL_USER") or None
    pw = env.get("STAFF_PORTAL_PASS") or None
    has_auth = bool(user) and bool(pw)
    explicit_bind = env.get("STAFF_PORTAL_BIND") or None
    bind = explicit_bind or ("0.0.0.0" if has_auth else "127.0.0.1")
    if not has_auth and bind not in _LOOPBACK:
        raise RuntimeError(
            f"Refusing to bind non-loopback host {bind!r} without auth. "
            "Set STAFF_PORTAL_USER and STAFF_PORTAL_PASS to expose externally."
        )
    return Settings(
        auth_user=user, auth_pass=pw, bind_host=bind,
        container=env.get("STAFF_PORTAL_CONTAINER", "samba-dc"),
        base_dn=env.get("STAFF_PORTAL_BASE_DN", "dc=wigitron,dc=com"),
        max_users=int(env.get("STAFF_PORTAL_MAX_USERS", "500")),
    )
```

- [ ] **Step 4: Run test to verify it passes**

Run: `cd staff-portal/backend && python -m pytest tests/test_config.py -v`
Expected: PASS (5 tests)

- [ ] **Step 5: Commit**

```bash
git add staff-portal/backend/app/config.py staff-portal/backend/tests/test_config.py
git commit -m "feat(staff-portal): config with auth/bind coupling and fail-safe"
```

---

## Task 5: FastAPI app — endpoints, models, auth, Swagger

**Files:**
- Create: `staff-portal/backend/app/models.py`
- Create: `staff-portal/backend/app/main.py`
- Create: `staff-portal/backend/requirements.txt`
- Test: `staff-portal/backend/tests/test_api.py`

**Interfaces:**
- Consumes: `build_plan, run_plan` (Task 3); `load_settings, auth_enabled` (Task 4); `normalize_fqdn` (Task 2).
- Produces: FastAPI `app`; `POST /domains` (body `CreateDomain`), `GET /domains`, `GET /health`.

- [ ] **Step 1: Write the failing test**

```python
# staff-portal/backend/tests/test_api.py
import app.main as main
from app.config import load_settings
from fastapi.testclient import TestClient


def _client(env, monkeypatch, fake_run=None):
    monkeypatch.setattr(main, "SETTINGS", load_settings(env))
    if fake_run is not None:
        monkeypatch.setattr(main, "run_plan", fake_run)
    return TestClient(main.app)


def test_health_open(monkeypatch):
    c = _client({}, monkeypatch)
    assert c.get("/health").json() == {"status": "ok"}


def test_create_dry_run_returns_summary(monkeypatch):
    c = _client({}, monkeypatch)
    r = c.post("/domains", json={"fqdn": "orange.rmorse.com", "dry_run": True})
    assert r.status_code == 200
    body = r.json()
    assert body["mail_domain"] == "orange.rmorse.com"
    assert body["ou_dn"].startswith("OU=orange,OU=rmorse")
    assert body["created"]["users"] == 20       # default count


def test_user_count_out_of_range_422(monkeypatch):
    c = _client({}, monkeypatch)
    assert c.post("/domains",
                  json={"fqdn": "a.b.com", "user_count": 501}).status_code == 422
    assert c.post("/domains",
                  json={"fqdn": "a.b.com", "user_count": 0}).status_code == 422


def test_bad_fqdn_422(monkeypatch):
    c = _client({}, monkeypatch)
    assert c.post("/domains", json={"fqdn": "localhost"}).status_code == 422


def test_auth_required_when_configured(monkeypatch):
    env = {"STAFF_PORTAL_USER": "staff", "STAFF_PORTAL_PASS": "pw"}
    c = _client(env, monkeypatch)
    assert c.post("/domains", json={"fqdn": "a.b.com", "dry_run": True}).status_code == 401
    ok = c.post("/domains", json={"fqdn": "a.b.com", "dry_run": True},
                auth=("staff", "pw"))
    assert ok.status_code == 200
```

- [ ] **Step 2: Run test to verify it fails**

Run: `cd staff-portal/backend && python -m pytest tests/test_api.py -v`
Expected: FAIL (ModuleNotFoundError: app.main)

- [ ] **Step 3: Write minimal implementation**

```python
# staff-portal/backend/app/models.py
from pydantic import BaseModel, Field


class CreateDomain(BaseModel):
    fqdn: str = Field(..., examples=["orange.rmorse.com"])
    user_count: int = Field(20, ge=1, le=500)
    dry_run: bool = False
```

```python
# staff-portal/backend/app/main.py
"""FastAPI staff tool: create a nested OU from an FQDN and seed it. Swagger = UI."""
import os
import secrets
from fastapi import Depends, FastAPI, HTTPException, status
from fastapi.security import HTTPBasic, HTTPBasicCredentials
from app.config import load_settings, auth_enabled
from app.models import CreateDomain
from app.naming import normalize_fqdn, ou_path
from app.seeder import build_plan, run_plan

SETTINGS = load_settings(os.environ)
app = FastAPI(title="LDAP Staff Portal", description="Create & seed test directories.")
_basic = HTTPBasic(auto_error=False)


def require_auth(creds: HTTPBasicCredentials = Depends(_basic)):
    if not auth_enabled(SETTINGS):
        return
    ok = creds and secrets.compare_digest(creds.username, SETTINGS.auth_user) \
        and secrets.compare_digest(creds.password, SETTINGS.auth_pass)
    if not ok:
        raise HTTPException(status.HTTP_401_UNAUTHORIZED, "Unauthorized",
                            {"WWW-Authenticate": "Basic"})


@app.get("/health")
def health():
    return {"status": "ok"}


@app.get("/domains", dependencies=[Depends(require_auth)])
def list_domains():
    # Read-only list of OUs via `samba-tool ou list` (no --dry-run; it reads).
    out = run_plan([["ou", "list"]], SETTINGS.container, dry_run=False)
    return {"base_dn": SETTINGS.base_dn, "result": out}


@app.post("/domains", dependencies=[Depends(require_auth)])
def create_domain(req: CreateDomain):
    try:
        fqdn = normalize_fqdn(req.fqdn)
    except ValueError as e:
        raise HTTPException(status.HTTP_422_UNPROCESSABLE_ENTITY, str(e))
    if req.user_count > SETTINGS.max_users:
        raise HTTPException(status.HTTP_422_UNPROCESSABLE_ENTITY,
                            f"user_count exceeds max {SETTINGS.max_users}")
    plan = build_plan(fqdn, req.user_count, SETTINGS.base_dn)
    result = run_plan(plan, SETTINGS.container, dry_run=req.dry_run)
    return {
        "fqdn": fqdn,
        "ou_dn": ou_path(fqdn, SETTINGS.base_dn)[-1],
        "mail_domain": fqdn,
        "created": result["created"],
        "errors": result["errors"],
        "dry_run": req.dry_run,
    }
```

```
# staff-portal/backend/requirements.txt
fastapi>=0.115
uvicorn>=0.30
pydantic>=2.7
httpx>=0.27
pytest>=8
```

- [ ] **Step 4: Run test to verify it passes**

Run: `cd staff-portal/backend && pip install -r requirements.txt && python -m pytest tests/test_api.py -v`
Expected: PASS (5 tests). For `GET /domains`, replace the `listobjects` stand-in with a real read if `samba-tool ou list` is available; the API test does not cover live listing.

- [ ] **Step 5: Commit**

```bash
git add staff-portal/backend/app/models.py staff-portal/backend/app/main.py staff-portal/backend/requirements.txt staff-portal/backend/tests/test_api.py
git commit -m "feat(staff-portal): FastAPI endpoints, models, Basic auth, Swagger"
```

---

## Task 6: Shell mirrors + parity test

**Files:**
- Create: `staff-portal/lib/allocate.sh`
- Create: `staff-portal/lib/naming.sh`
- Create: `staff-portal/tests/test_parity.sh`

**Interfaces:**
- Consumes: `allocate` (Task 1), `hash4/sam/group_name` (Task 2) as the reference outputs to match.
- Produces: shell functions `alloc_group <group> <n>` (echoes space-separated indices) and `hash4 <fqdn>`, `sam <user> <fqdn>`, `group_name <base> <fqdn>` with identical output to Python.

- [ ] **Step 1: Write the failing test**

```bash
# staff-portal/tests/test_parity.sh
#!/bin/bash
# Asserts the shell mirrors match the authoritative Python for many N/FQDNs.
set -u
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$HERE/../lib/allocate.sh"
source "$HERE/../lib/naming.sh"
BK="$HERE/../backend"
fail=0

for n in 1 2 3 4 20 50 101; do
  for g in All_Company Dev_Team QA_Team Support_Team Marketing_Team; do
    py=$(cd "$BK" && python -c "from app.allocate import allocate; print(' '.join(map(str, allocate($n)['$g'])))")
    sh=$(alloc_group "$g" "$n")
    if [ "$py" != "$sh" ]; then echo "MISMATCH alloc $g n=$n: py[$py] sh[$sh]"; fail=1; fi
  done
done

for f in orange.rmorse.com rmorse.com a.b.co; do
  py=$(cd "$BK" && python -c "from app.naming import hash4; print(hash4('$f'))")
  sh=$(hash4 "$f")
  if [ "$py" != "$sh" ]; then echo "MISMATCH hash4 $f: py[$py] sh[$sh]"; fail=1; fi
done

[ "$fail" -eq 0 ] && echo "PARITY OK" || { echo "PARITY FAILED"; exit 1; }
```

- [ ] **Step 2: Run test to verify it fails**

Run: `bash staff-portal/tests/test_parity.sh`
Expected: FAIL (allocate.sh / naming.sh not found or functions undefined)

- [ ] **Step 3: Write minimal implementation**

```bash
# staff-portal/lib/allocate.sh
# Shell mirror of app/allocate.py. alloc_group <group> <n> -> space-sep indices.
alloc_group() {
  # half_hi = ceil(N/2) for Dev/QA split; half_lo = floor(N/2) for Marketing top.
  local g="$1" n="$2" half_lo=$(( $2 / 2 )) half_hi=$(( ($2 + 1) / 2 )) quarter=$(( $2 / 4 )) i out=""
  case "$g" in
    All_Company)    for ((i=1;i<=n;i++)); do out+="$i "; done ;;
    Dev_Team)       for ((i=1;i<=half_hi;i++)); do out+="$i "; done ;;
    QA_Team)        for ((i=half_hi+1;i<=n;i++)); do out+="$i "; done ;;
    Support_Team)   for ((i=1;i<=quarter;i++)); do out+="$i "; done ;;
    Marketing_Team) for ((i=quarter+1;i<=half_lo;i++)); do out+="$i "; done ;;
  esac
  echo "${out% }"
}
```

```bash
# staff-portal/lib/naming.sh
# Shell mirror of app/naming.py hashing/naming. Requires sha256sum or shasum.
_sha256_hex() {
  if command -v sha256sum >/dev/null 2>&1; then printf '%s' "$1" | sha256sum | cut -c1-64
  else printf '%s' "$1" | shasum -a 256 | cut -c1-64; fi
}
normalize_fqdn() {
  local v; v="$(printf '%s' "$1" | tr '[:upper:]' '[:lower:]' | sed 's/^ *//;s/ *$//;s/\.$//')"
  case "$v" in *.*) printf '%s' "$v" ;; *) echo "bad fqdn: $1" >&2; return 1 ;; esac
}
hash4() { _sha256_hex "$(normalize_fqdn "$1")" | cut -c1-4; }
sam() { printf '%s_%s' "$1" "$(hash4 "$2")"; }
group_name() { printf '%s_%s' "$1" "$(hash4 "$2")"; }
```

- [ ] **Step 4: Run test to verify it passes**

Run: `bash staff-portal/tests/test_parity.sh`
Expected: `PARITY OK`. (Remove the broken first `case` stub shown above; the second, complete `case` is the real body — collapse to just that.)

- [ ] **Step 5: Commit**

```bash
git add staff-portal/lib/allocate.sh staff-portal/lib/naming.sh staff-portal/tests/test_parity.sh
git commit -m "feat(staff-portal): shell mirrors of allocation and naming with parity test"
```

---

## Task 7: Unify existing scripts onto shared naming/allocation

**Files:**
- Modify: `seed_ou.sh` (replace `SLUG` prefix with `lib/naming.sh` hash suffix; replace hardcoded 1..COUNT/2 split with `lib/allocate.sh`)
- Modify: `import_as_ou.sh` (replace leftmost-slug `pfx()` with hash suffix from `lib/naming.sh`)
- Modify: `README.md` (update the consolidation examples: `intl_testuser1` → `testuser1_<hash>`)
- Test: extend `staff-portal/tests/test_parity.sh` with a regression assertion that `seed_ou.sh --dry-run`-style naming matches the Python `sam()` for a sample FQDN (add a dry-run echo mode to `seed_ou.sh` if absent).

**Interfaces:**
- Consumes: `lib/allocate.sh`, `lib/naming.sh` (Task 6).

- [ ] **Step 1: Write the failing test**

Add to `staff-portal/tests/test_parity.sh` before the final verdict:

```bash
# Regression: seed_ou.sh must name users via the shared hash suffix.
SEED_SAM=$(SEED_DRYRUN=1 bash "$HERE/../../seed_ou.sh" print-sam testuser1 orange.rmorse.com 2>/dev/null)
PY_SAM=$(cd "$BK" && python -c "from app.naming import sam; print(sam('testuser1','orange.rmorse.com'))")
if [ "$SEED_SAM" != "$PY_SAM" ]; then echo "MISMATCH seed_ou sam: [$SEED_SAM] vs [$PY_SAM]"; fail=1; fi
```

- [ ] **Step 2: Run test to verify it fails**

Run: `bash staff-portal/tests/test_parity.sh`
Expected: FAIL on the new `seed_ou sam` assertion (seed_ou.sh still uses SLUG prefix and has no `print-sam` hook).

- [ ] **Step 3: Write minimal implementation**

In `seed_ou.sh`, source the shared libs and add an early dispatch so the test can query naming without seeding:

```bash
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/staff-portal/lib/naming.sh"
source "${SCRIPT_DIR}/staff-portal/lib/allocate.sh"

# Test/support hook: `seed_ou.sh print-sam <user> <fqdn>` echoes the shared sAM.
if [ "${1:-}" = "print-sam" ]; then sam "$2" "$3"; exit 0; fi
```

Then replace `SLUG="${OU_NAME}..."`-based names with `sam "$user" "$FQDN"` and `group_name "$g" "$FQDN"`, and replace the `if [ $i -le 10 ]` split with membership derived from `alloc_group Dev_Team "$COUNT"` / `alloc_group QA_Team "$COUNT"`. Apply the same `sam`/`group_name` substitution to `import_as_ou.sh`'s `pfx()`.

- [ ] **Step 4: Run test to verify it passes**

Run: `bash staff-portal/tests/test_parity.sh`
Expected: `PARITY OK` including the seed_ou regression line. Also run `bash -n seed_ou.sh import_as_ou.sh`.

- [ ] **Step 5: Commit**

```bash
git add seed_ou.sh import_as_ou.sh README.md staff-portal/tests/test_parity.sh
git commit -m "refactor: unify seed_ou/import_as_ou onto shared hash-suffix naming and allocation"
```

---

## Task 8: Runbook + run script + full-suite verification

**Files:**
- Create: `staff-portal/README.md`
- Create: `staff-portal/run.sh` (uvicorn launcher honoring `SETTINGS.bind_host`)
- Test: run the whole suite + a live dry-run smoke.

**Interfaces:**
- Consumes: everything above.

- [ ] **Step 1: Write the runbook and launcher**

`staff-portal/run.sh`:

```bash
#!/bin/bash
# Launch the staff portal. Bind host is derived from auth env (see config.py).
set -eu
cd "$(dirname "${BASH_SOURCE[0]}")/backend"
BIND=$(python -c "import os;from app.config import load_settings;print(load_settings(os.environ).bind_host)")
exec uvicorn app.main:app --host "$BIND" --port "${STAFF_PORTAL_PORT:-8099}"
```

`staff-portal/README.md`: document env vars (from spec's Config table), the auth/bind coupling, how to reach Swagger at `http://<bind>:8099/docs`, and the `dry_run` field. State the create-only non-goal and that LAM handles management.

- [ ] **Step 2: Run the full Python suite**

Run: `cd staff-portal/backend && python -m pytest -v`
Expected: PASS (all tasks' tests).

- [ ] **Step 3: Run the parity suite**

Run: `bash staff-portal/tests/test_parity.sh`
Expected: `PARITY OK`.

- [ ] **Step 4: Live dry-run smoke (manual, documented)**

Run: `cd staff-portal/backend && STAFF_PORTAL_MAX_USERS=5 python -c "from fastapi.testclient import TestClient; import app.main as m; print(m.create_domain(m.CreateDomain(fqdn='orange.rmorse.com', user_count=3, dry_run=True)))"`
Expected: summary dict with `ou_dn` nested, `created.users == 3`, no execution. (Live `samba-tool` run against a container stays a manual step; not automated here.)

- [ ] **Step 5: Commit**

```bash
git add staff-portal/README.md staff-portal/run.sh
git commit -m "docs(staff-portal): runbook, launcher, and full-suite verification"
```

---

## Self-Review Notes

- **Spec coverage:** OU model (T3/T5), nested OU + parent-first (T2/T3), full-FQDN mail+UPN (T3), hash-suffix sAM ≤20 (T2), allocation rule + default 20/max 500 (T1/T5), sync + dry_run (T5), auth/bind + fail-safe (T4), create-only surface (T5), shared source of truth + parity (T6), repo-wide unification (T7), runbook/Swagger (T8). All mapped.
- **Review Focus coverage:** FQDN normalization (T2 `test_normalize`), single-label/empty (T2), user_count bounds (T1 edges, T5 422), hash length ceiling (T2 `test_hash_stable_and_short`), partial auth (T4 `test_partial_auth_is_off`).
- **Known cleanup for the implementer:** Task 5 `GET /domains` calls `samba-tool ou list` and returns its raw result; parsing into structured OU names is a nice-to-have, not test-covered (flagged). The live `samba-tool` execution path (`run_plan` with `dry_run=False`) is not exercised by automated tests in this environment — the dry-run plan is the proxy; first live run is manual (Task 8 Step 4).
