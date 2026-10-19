"""FastAPI staff tool: create a nested OU from an FQDN and seed it. Swagger = UI."""
import os
import secrets
from fastapi import Depends, FastAPI, HTTPException, status
from fastapi.security import HTTPBasic, HTTPBasicCredentials
from app.config import load_settings, auth_enabled
from app.models import CreateDomain
from app.naming import normalize_fqdn, ou_path
from app.seeder import build_plan, run_plan

# Fail-safe: load_settings may raise RuntimeError, aborting startup.
SETTINGS = load_settings(os.environ)
app = FastAPI(title="LDAP Staff Portal", description="Create & seed test directories.")
_basic = HTTPBasic(auto_error=False)


def require_auth(creds: HTTPBasicCredentials = Depends(_basic)):
    if not auth_enabled(SETTINGS):
        return
    ok = creds is not None \
        and secrets.compare_digest(creds.username.encode(), SETTINGS.auth_user.encode()) \
        and secrets.compare_digest(creds.password.encode(), SETTINGS.auth_pass.encode())
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
