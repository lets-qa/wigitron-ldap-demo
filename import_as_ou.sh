#!/bin/bash
#
# Import a directory manifest (from export_directory.sh) into an OU inside the
# single main DC — no new container, no extra ports. This is the "one container,
# one port set" consolidation of a separate-port domain.
#
# AD requires sAMAccountName and group names to be unique DOMAIN-WIDE, so every
# object is prefixed with a slug (default derived from the OU name). Passwords
# are re-set on import (AD cannot export plaintext): testuserN -> Password!N,
# anything else -> DEFAULT_PASSWORD.
#
# Usage:
#   ./import_as_ou.sh <ou-name> <manifest.json> [--prefix SLUG] [--dry-run]
#
# Examples:
#   ./import_as_ou.sh international intl.json                 # prefix "international"
#   ./import_as_ou.sh international intl.json --prefix intl   # shorter prefix
#   ./import_as_ou.sh international intl.json --dry-run        # print, don't execute

set -u

CONTAINER="${CONTAINER:-samba-dc}"
DEFAULT_PASSWORD="${DEFAULT_PASSWORD:-Admin!Test1234}"

OU_NAME=""; MANIFEST=""; PREFIX=""; DRY_RUN="false"
POSITIONAL=()
while [ $# -gt 0 ]; do
  case "$1" in
    --prefix) PREFIX="$2"; shift 2;;
    --dry-run) DRY_RUN="true"; shift;;
    -h|--help) echo "Usage: $0 <ou-name> <manifest.json> [--prefix SLUG] [--dry-run]"; exit 0;;
    *) POSITIONAL+=("$1"); shift;;
  esac
done
OU_NAME="${POSITIONAL[0]:-}"
MANIFEST="${POSITIONAL[1]:-}"

if [ -z "$OU_NAME" ] || [ -z "$MANIFEST" ]; then
  echo "Usage: $0 <ou-name> <manifest.json> [--prefix SLUG] [--dry-run]" >&2
  exit 1
fi
if [ ! -f "$MANIFEST" ]; then
  echo "Error: manifest '$MANIFEST' not found." >&2
  exit 1
fi

# Slug: lowercase alphanumerics, used as the domain-wide-unique prefix.
if [ -z "$PREFIX" ]; then
  PREFIX=$(printf '%s' "$OU_NAME" | tr '[:upper:]' '[:lower:]' | tr -cd 'a-z0-9')
fi
if [ -z "$PREFIX" ]; then
  echo "Error: could not derive a usable prefix from '$OU_NAME'; pass --prefix." >&2
  exit 1
fi

# Emit a tab-separated action plan from the manifest; bash executes it. This
# keeps JSON parsing in python and command execution in bash.
PLAN=$(PREFIX="$PREFIX" DEFAULT_PASSWORD="$DEFAULT_PASSWORD" \
  python3 -I - "$MANIFEST" <<'PY'
import json, os, re, sys
prefix = os.environ["PREFIX"]
default_pw = os.environ["DEFAULT_PASSWORD"]
with open(sys.argv[1], encoding="utf-8") as fh:
    m = json.load(fh)

if m.get("schema") != "ldap-directory-export/v1":
    sys.stderr.write("Warning: unexpected manifest schema: %r\n" % m.get("schema"))

def pfx(name):
    return "%s_%s" % (prefix, name)

# Fields are joined with ASCII Unit Separator (\x1f), NOT tab: tab is an
# IFS-whitespace char in bash and collapses consecutive/empty fields, which
# would shift columns whenever an optional value (e.g. mail) is empty.
SEP = "\x1f"
lines = []
# Users: USER | newsam | password | given | surname | mail | disabled
for u in m.get("users", []):
    sam = u["sam"]
    mobj = re.match(r"^testuser(\d+)$", sam)
    pw = "Password!%s" % mobj.group(1) if mobj else default_pw
    new_mail = u.get("mail", "")
    lines.append(SEP.join([
        "USER", pfx(sam), pw, u.get("givenName", ""), u.get("surname", ""),
        new_mail, "true" if u.get("disabled") else "false",
    ]))
# Groups first (create), then memberships (after all objects exist)
for g in m.get("groups", []):
    lines.append(SEP.join(["GROUP", pfx(g["name"]), g.get("mail", "")]))
for g in m.get("groups", []):
    for mem in g.get("members", []):
        # Prefix member names too; they refer to other objects in this manifest.
        lines.append(SEP.join(["MEMBER", pfx(g["name"]), pfx(mem)]))
print("\n".join(lines))
PY
)
if [ $? -ne 0 ]; then
  echo "Error: failed to parse manifest." >&2
  exit 1
fi

OU_DN="OU=${OU_NAME},${LDAP_BASE_DN:-dc=wigitron,dc=com}"

run() { # echoes in dry-run, executes otherwise
  if [ "$DRY_RUN" = "true" ]; then
    printf '  [dry-run] docker exec %s samba-tool %s\n' "$CONTAINER" "$*"
  else
    docker exec "$CONTAINER" samba-tool "$@" || echo "   (non-fatal: $*)"
  fi
}

echo "== Importing manifest '$MANIFEST' into OU '$OU_NAME' (prefix '${PREFIX}_') =="
[ "$DRY_RUN" = "true" ] && echo "   (dry-run: no changes will be made)"

echo "-- Ensure OU exists: $OU_DN"
run ou create "$OU_DN"

while IFS=$'\x1f' read -r kind a b c d e f; do
  case "$kind" in
    USER)
      # a=sam b=pw c=given d=surname e=mail f=disabled
      if [ -n "$e" ]; then
        run user create "$a" "$b" --userou="OU=${OU_NAME}" \
          --given-name="$c" --surname="$d" --mail-address="$e"
      else
        run user create "$a" "$b" --userou="OU=${OU_NAME}" \
          --given-name="$c" --surname="$d"
      fi
      run user setexpiry "$a" --noexpiry
      [ "$f" = "true" ] && run user disable "$a"
      ;;
    GROUP)
      # a=name b=mail
      if [ -n "$b" ]; then
        run group add "$a" --groupou="OU=${OU_NAME}" --mail-address="$b"
      else
        run group add "$a" --groupou="OU=${OU_NAME}"
      fi
      ;;
    MEMBER)
      # a=group b=member
      run group addmembers "$a" "$b"
      ;;
  esac
done <<< "$PLAN"

echo "== Done. Verify with: =="
echo "   docker exec ${CONTAINER} samba-tool user list | grep '^${PREFIX}_'"
