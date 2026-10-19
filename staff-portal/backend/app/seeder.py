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
