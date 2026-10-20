#!/bin/bash
#
# Export the STRUCTURE of a live Samba DC to a portable JSON manifest.
# Read-only: it never modifies the source directory, so it is safe to run
# against a production/live DC such as the international one.
#
# Secrets are deliberately NOT exported — AD only stores one-way password
# hashes, and for this test rig the passwords are known by convention
# (testuserN -> Password!N). import_as_ou.sh re-sets them on the way in.
#
# Usage:
#   ./export_directory.sh <container> [output.json]
#
# Examples:
#   ./export_directory.sh samba-dc-international intl.json
#   ./export_directory.sh samba-dc-international        # -> <container>.json
#
# What it captures per object:
#   users:  sAMAccountName, givenName, surname, mail, enabled/disabled
#   groups: name, mail, direct members (users AND nested groups)

set -u

CONTAINER="${1:-}"
if [ -z "$CONTAINER" ]; then
  echo "Usage: $0 <container> [output.json]" >&2
  exit 1
fi
OUT="${2:-${CONTAINER}.json}"

dc() { docker exec "$CONTAINER" samba-tool "$@" 2>/dev/null; }

# Confirm the container answers before we start emitting.
if ! dc domain info 127.0.0.1 >/dev/null 2>&1 && ! dc user list >/dev/null 2>&1; then
  echo "Error: cannot reach samba-tool in container '${CONTAINER}'." >&2
  exit 1
fi

echo "Exporting directory from '${CONTAINER}'..." >&2

# Pull a single field out of 'samba-tool <obj> show' LDIF-ish output.
show_field() { # <obj-type> <name> <attr>
  docker exec "$CONTAINER" samba-tool "$1" show "$2" 2>/dev/null \
    | tr -d '\r' | awk -F': ' -v a="$3" '$1==a {print $2; exit}'
}

# Build the manifest with python for correct JSON escaping. We feed it the
# object lists via env + stdin-free calls to keep quoting sane.
TMPDIR_EXPORT="$(mktemp -d)"
trap 'rm -rf "$TMPDIR_EXPORT"' EXIT

# --- Users ---
USERS_FILE="$TMPDIR_EXPORT/users.tsv"
: > "$USERS_FILE"
while IFS= read -r u; do
  [ -z "$u" ] && continue
  given=$(show_field user "$u" givenName)
  sn=$(show_field user "$u" sn)
  mail=$(show_field user "$u" mail)
  uac=$(show_field user "$u" userAccountControl)
  # userAccountControl bit 0x2 (2) = ACCOUNTDISABLE
  disabled="false"
  if [ -n "$uac" ] && [ $(( uac & 2 )) -ne 0 ]; then disabled="true"; fi
  printf '%s\t%s\t%s\t%s\t%s\n' "$u" "$given" "$sn" "$mail" "$disabled" >> "$USERS_FILE"
done < <(dc user list | tr -d '\r' | grep -vE '^(Administrator|Guest|krbtgt)$' | sort)

# --- Groups ---
GROUPS_FILE="$TMPDIR_EXPORT/groups.tsv"
MEMBERS_FILE="$TMPDIR_EXPORT/members.tsv"
: > "$GROUPS_FILE"; : > "$MEMBERS_FILE"
while IFS= read -r g; do
  [ -z "$g" ] && continue
  mail=$(show_field group "$g" mail)
  printf '%s\t%s\n' "$g" "$mail" >> "$GROUPS_FILE"
  while IFS= read -r m; do
    [ -z "$m" ] && continue
    printf '%s\t%s\n' "$g" "$m" >> "$MEMBERS_FILE"
  done < <(dc group listmembers "$g" | tr -d '\r' | sort)
done < <(dc group list | tr -d '\r' | sort)

SOURCE_CONTAINER="$CONTAINER" python3 -I - "$USERS_FILE" "$GROUPS_FILE" "$MEMBERS_FILE" > "$OUT" <<'PY'
import json, os, sys
users_f, groups_f, members_f = sys.argv[1], sys.argv[2], sys.argv[3]

def rows(path, n):
    out = []
    with open(path, encoding="utf-8") as fh:
        for line in fh:
            line = line.rstrip("\n")
            if not line:
                continue
            parts = line.split("\t")
            parts += [""] * (n - len(parts))
            out.append(parts[:n])
    return out

users = [
    {"sam": s, "givenName": g, "surname": sn, "mail": m, "disabled": d == "true"}
    for s, g, sn, m, d in rows(users_f, 5)
]
members = {}
for g, m in rows(members_f, 2):
    members.setdefault(g, []).append(m)
groups = [
    {"name": n, "mail": ml, "members": members.get(n, [])}
    for n, ml in rows(groups_f, 2)
]

manifest = {
    "schema": "ldap-directory-export/v1",
    "source": os.environ.get("SOURCE_CONTAINER", ""),
    "users": users,
    "groups": groups,
}
print(json.dumps(manifest, indent=2))
PY

U=$(grep -c '' "$USERS_FILE" 2>/dev/null || echo 0)
G=$(grep -c '' "$GROUPS_FILE" 2>/dev/null || echo 0)
echo "Wrote ${OUT} (${U} users, ${G} groups)." >&2
