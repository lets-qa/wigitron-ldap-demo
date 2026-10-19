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

OU_DN="OU=${OU_NAME},${BASE_DN}"
dc() { docker exec "$CONTAINER" samba-tool "$@"; }

echo "== Seeding directory OU '${OU_NAME}' (${COUNT} users) under ${BASE_DN} =="

echo "-- Creating the OU: ${OU_DN}"
dc ou create "$OU_DN" || echo "   (OU may already exist — continuing)"

echo "-- Creating nested groups inside the OU"
for g in All_Engineering Dev_Team QA_Team; do
  dc group add "${SLUG}_${g}" --groupou="OU=${OU_NAME}" \
    || echo "   (${SLUG}_${g} may already exist)"
done
dc group addmembers "${SLUG}_All_Engineering" "${SLUG}_Dev_Team" || true
dc group addmembers "${SLUG}_All_Engineering" "${SLUG}_QA_Team"  || true

echo "-- Creating and assigning ${COUNT} test users"
for ((i=1; i<=COUNT; i++)); do
  user="${SLUG}_testuser${i}"
  pass="Password!${i}"
  dc user create "$user" "$pass" \
    --userou="OU=${OU_NAME}" \
    --given-name="Test" --surname="User${i}" \
    --mail-address="${user}@${MAIL_DOMAIN}" \
    || echo "   (${user} may already exist)"
  # Never let these expire (matches the hardening applied elsewhere).
  dc user setexpiry "$user" --noexpiry >/dev/null 2>&1 || true

  if [ "$i" -le $(( COUNT / 2 )) ]; then
    dc group addmembers "${SLUG}_Dev_Team" "$user" || true
  else
    dc group addmembers "${SLUG}_QA_Team" "$user" || true
  fi
done

echo "-- Creating email distribution lists"
dc group add "${SLUG}_All_Company" --groupou="OU=${OU_NAME}" \
  --mail-address="all@${SLUG}.${MAIL_DOMAIN}"     || true
dc group add "${SLUG}_Support_Team" --groupou="OU=${OU_NAME}" \
  --mail-address="support@${SLUG}.${MAIL_DOMAIN}" || true

for ((i=1; i<=COUNT; i++)); do
  dc group addmembers "${SLUG}_All_Company" "${SLUG}_testuser${i}" || true
done
for ((i=1; i<=COUNT && i<=5; i++)); do
  dc group addmembers "${SLUG}_Support_Team" "${SLUG}_testuser${i}" || true
done

echo "== Done. Verify with: =="
echo "   docker exec ${CONTAINER} samba-tool user list | grep '^${SLUG}_'"
echo "   ldapsearch -H ldap://localhost:\${LDAP_PORT:-389} -x \\"
echo "     -D \"cn=Administrator,cn=Users,${BASE_DN}\" -w 'Admin!Test1234' \\"
echo "     -b \"${OU_DN}\" \"(objectClass=user)\" sAMAccountName"
