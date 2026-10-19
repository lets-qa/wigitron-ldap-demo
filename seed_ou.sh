#!/bin/bash
#
# Seed a self-contained "directory" as an Organizational Unit inside the single
# existing Samba DC — no new container, no new ports. Each OU gets the same
# standard structure (nested groups, test users, email distribution lists) that
# seed_directory.sh + add_email_groups.sh create at the root.
#
# Usage:
#   ./seed_ou.sh <ou-name> [user-count]
#
# Examples:
#   ./seed_ou.sh international        # ou=international, 20 users
#   ./seed_ou.sh emea 10             # ou=emea, 10 users
#
# Because AD requires sAMAccountName and group names to be unique DOMAIN-WIDE
# (not just per-OU), every object created here is prefixed with a slug derived
# from the OU name — e.g. ou "international" -> users intl... is too lossy, so we
# use the full lowercased OU name as the prefix: international_testuser1,
# international_Dev_Team, international.<user>@wigitron.com.
#
# Safe to re-run: samba-tool errors harmlessly on objects that already exist.

set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/staff-portal/lib/naming.sh"
source "${SCRIPT_DIR}/staff-portal/lib/allocate.sh"

# Test/support hook: `seed_ou.sh print-sam <user> <fqdn>` echoes the shared sAM.
if [ "${1:-}" = "print-sam" ]; then sam "$2" "$3"; exit 0; fi
# Test/support hook: `seed_ou.sh print-mail <user> <fqdn>` echoes the clean email.
if [ "${1:-}" = "print-mail" ]; then echo "$2@$3"; exit 0; fi

CONTAINER="${CONTAINER:-samba-dc}"
BASE_DN="${LDAP_BASE_DN:-dc=wigitron,dc=com}"
MAIL_DOMAIN="${MAIL_DOMAIN:-wigitron.com}"

OU_NAME="${1:-}"
COUNT="${2:-20}"

if [ -z "$OU_NAME" ]; then
  echo "Usage: $0 <ou-name> [user-count]" >&2
  exit 1
fi

# Slug: lowercase, strip anything but [a-z0-9], used to keep names domain-unique.
SLUG=$(printf '%s' "$OU_NAME" | tr '[:upper:]' '[:lower:]' | tr -cd 'a-z0-9')
if [ -z "$SLUG" ]; then
  echo "Error: OU name '$OU_NAME' has no usable alphanumeric characters." >&2
  exit 1
fi

# Naming domain: same <slug>.<mail-domain> already used for the distribution-list
# addresses below; hashed by the shared lib so names match the API/staff portal.
FQDN="${SLUG}.${MAIL_DOMAIN}"
G_ALL_ENG=$(group_name All_Engineering "$FQDN")
G_DEV=$(group_name Dev_Team "$FQDN")
G_QA=$(group_name QA_Team "$FQDN")
G_ALL=$(group_name All_Company "$FQDN")
G_SUP=$(group_name Support_Team "$FQDN")

OU_DN="OU=${OU_NAME},${BASE_DN}"
dc() { docker exec "$CONTAINER" samba-tool "$@"; }

echo "== Seeding directory OU '${OU_NAME}' (${COUNT} users) under ${BASE_DN} =="

echo "-- Creating the OU: ${OU_DN}"
dc ou create "$OU_DN" || echo "   (OU may already exist — continuing)"

echo "-- Creating nested groups inside the OU"
for g in "$G_ALL_ENG" "$G_DEV" "$G_QA"; do
  dc group add "$g" --groupou="OU=${OU_NAME}" \
    || echo "   (${g} may already exist)"
done
dc group addmembers "$G_ALL_ENG" "$G_DEV" || true
dc group addmembers "$G_ALL_ENG" "$G_QA"  || true

echo "-- Creating ${COUNT} test users"
for ((i=1; i<=COUNT; i++)); do
  user=$(sam "testuser${i}" "$FQDN")
  pass="Password!${i}"
  dc user create "$user" "$pass" \
    --userou="OU=${OU_NAME}" \
    --given-name="Test" --surname="User${i}" \
    --mail-address="testuser${i}@${FQDN}" \
    --user-principal-name="testuser${i}@${FQDN}" \
    || echo "   (${user} may already exist)"
  # Never let these expire (matches the hardening applied elsewhere).
  dc user setexpiry "$user" --noexpiry >/dev/null 2>&1 || true
done

echo "-- Assigning group memberships (shared allocation)"
for i in $(alloc_group Dev_Team "$COUNT"); do
  dc group addmembers "$G_DEV" "$(sam "testuser${i}" "$FQDN")" || true
done
for i in $(alloc_group QA_Team "$COUNT"); do
  dc group addmembers "$G_QA" "$(sam "testuser${i}" "$FQDN")" || true
done

echo "-- Creating email distribution lists"
dc group add "$G_ALL" --groupou="OU=${OU_NAME}" \
  --mail-address="all@${SLUG}.${MAIL_DOMAIN}"     || true
dc group add "$G_SUP" --groupou="OU=${OU_NAME}" \
  --mail-address="support@${SLUG}.${MAIL_DOMAIN}" || true

for i in $(alloc_group All_Company "$COUNT"); do
  dc group addmembers "$G_ALL" "$(sam "testuser${i}" "$FQDN")" || true
done
for i in $(alloc_group Support_Team "$COUNT"); do
  dc group addmembers "$G_SUP" "$(sam "testuser${i}" "$FQDN")" || true
done

echo "== Done. Verify with: =="
echo "   docker exec ${CONTAINER} samba-tool user list | grep '_$(hash4 "$FQDN")$'"
echo "   ldapsearch -H ldap://localhost:\${LDAP_PORT:-389} -x \\"
echo "     -D \"cn=Administrator,cn=Users,${BASE_DN}\" -w 'Admin!Test1234' \\"
echo "     -b \"${OU_DN}\" \"(objectClass=user)\" sAMAccountName"
