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
