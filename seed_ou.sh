#!/bin/bash
#
# Seed a self-contained "directory" as an Organizational Unit inside the single
# existing Samba DC — no new container, no new ports. Each OU gets the same
# standard structure (nested groups, test users, email distribution lists) that
# seed_directory.sh + add_email_groups.sh create at the root.
#
# Takes a full FQDN, exactly like the staff-portal API (POST /domains {fqdn}),
# so the two produce byte-identical directories.
#
# Usage:
#   ./seed_ou.sh <fqdn> [user-count]
#
# Examples:
#   ./seed_ou.sh acme.test            # OU=acme, mail/UPN @acme.test, 20 users
#   ./seed_ou.sh orange.rmorse.com 10 # OU=orange,OU=rmorse (nested), 10 users
#
# The FQDN maps to a nested OU (every label except the TLD, right-to-left) via
# the shared lib/naming.sh — identical to the API. AD requires sAMAccountName
# and group names unique DOMAIN-WIDE, so each object is suffixed with a stable
# hash of the FQDN: testuser1_<hash4>, Dev_Team_<hash4>. mail and UPN are the
# clean testuser<i>@<fqdn> (hash only in the sAMAccountName).
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

FQDN="${1:-}"
COUNT="${2:-20}"

if [ -z "$FQDN" ]; then
  echo "Usage: $0 <fqdn> [user-count]   (e.g. $0 acme.test)" >&2
  exit 1
fi
# Normalize + validate the FQDN (needs at least two labels).
FQDN="$(normalize_fqdn "$FQDN")" || { echo "Error: '${1}' is not a valid FQDN." >&2; exit 1; }

# OU DNs derived from the FQDN, identical to the API's app/naming.py.
OU_DN="$(ou_path_leaf "$FQDN" "$BASE_DN")"        # full leaf DN for `ou create`
OU_REL="$(ou_path_relative "$FQDN" "$BASE_DN")"   # relative path for --userou/--groupou
G_ALL_ENG=$(group_name All_Engineering "$FQDN")
G_DEV=$(group_name Dev_Team "$FQDN")
G_QA=$(group_name QA_Team "$FQDN")
G_ALL=$(group_name All_Company "$FQDN")
G_SUP=$(group_name Support_Team "$FQDN")
G_MKT=$(group_name Marketing_Team "$FQDN")

dc() { docker exec "$CONTAINER" samba-tool "$@"; }

echo "== Seeding directory '${FQDN}' (${COUNT} users) as ${OU_DN} =="

echo "-- Creating the OU path (parent-first): ${OU_DN}"
# Create each OU from the top down so nested parents exist first. Walk the
# leaf DN, peeling the leftmost OU=... component each pass.
ou_create_chain() {
  local leaf="$1" parts="" comp rest="$1"
  # Collect OU components left-to-right into an array via positional building.
  local -a chain=()
  while [ -n "$rest" ]; do
    case "$rest" in
      OU=*) comp="${rest%%,*}"; rest="${rest#*,}"; chain+=("$comp") ;;
      *) break ;;   # reached the dc=... base
    esac
  done
  # Build DNs from the base up (rightmost OU first).
  local suffix="$BASE_DN" i dn
  for ((i=${#chain[@]}-1; i>=0; i--)); do
    dn="${chain[i]},${suffix}"
    dc ou create "$dn" >/dev/null 2>&1 || true
    suffix="$dn"
  done
}
ou_create_chain "$OU_DN"

# Register the org's UPN suffix once, so the clean testuser@FQDN UPN is accepted
# (AD rejects a UPN whose suffix is not a registered namespace). samba-tool has
# no --user-principal-name on `user create`; the UPN is set with `user rename`.
dc domain trust namespaces --add-upn-suffix="$FQDN" >/dev/null 2>&1 || true

echo "-- Creating nested groups inside the OU"
for g in "$G_ALL_ENG" "$G_DEV" "$G_QA"; do
  dc group add "$g" --groupou="$OU_REL" \
    || echo "   (${g} may already exist)"
done
dc group addmembers "$G_ALL_ENG" "$G_DEV" || true
dc group addmembers "$G_ALL_ENG" "$G_QA"  || true

echo "-- Creating ${COUNT} test users"
for ((i=1; i<=COUNT; i++)); do
  user=$(sam "testuser${i}" "$FQDN")
  pass="Password!${i}"
  dc user create "$user" "$pass" \
    --userou="$OU_REL" \
    --given-name="Test" --surname="User${i}" \
    --mail-address="testuser${i}@${FQDN}" \
    || echo "   (${user} may already exist)"
  # Set the clean UPN (hash stays only in the sAMAccountName).
  dc user rename "$user" --upn="testuser${i}@${FQDN}" >/dev/null 2>&1 || true
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
dc group add "$G_ALL" --groupou="$OU_REL" \
  --mail-address="all@${FQDN}"     || true
dc group add "$G_SUP" --groupou="$OU_REL" \
  --mail-address="support@${FQDN}" || true
dc group add "$G_MKT" --groupou="$OU_REL" \
  --mail-address="marketing@${FQDN}" || true

for i in $(alloc_group All_Company "$COUNT"); do
  dc group addmembers "$G_ALL" "$(sam "testuser${i}" "$FQDN")" || true
done
for i in $(alloc_group Support_Team "$COUNT"); do
  dc group addmembers "$G_SUP" "$(sam "testuser${i}" "$FQDN")" || true
done
for i in $(alloc_group Marketing_Team "$COUNT"); do
  dc group addmembers "$G_MKT" "$(sam "testuser${i}" "$FQDN")" || true
done

echo "== Done. Verify with: =="
echo "   docker exec ${CONTAINER} samba-tool user list | grep '_$(hash4 "$FQDN")$'"
echo "   ldapsearch -H ldap://localhost:\${LDAP_PORT:-389} -x \\"
echo "     -D \"cn=Administrator,cn=Users,${BASE_DN}\" -w 'Admin!Test1234' \\"
echo "     -b \"${OU_DN}\" \"(objectClass=user)\" sAMAccountName"
