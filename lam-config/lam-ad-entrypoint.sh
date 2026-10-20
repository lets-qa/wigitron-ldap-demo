#!/bin/bash
# Wrapper entrypoint for the LAM container.
#
# The stock image's start.sh always generates its server profile from
# unix.sample.conf, which uses OpenLDAP account modules (posixAccount /
# inetOrgPerson). Those do not match Active Directory objects, so the Users and
# Groups lists come up EMPTY against a Samba AD DC even though the accounts
# exist (confirmed in a browser: "User count: 0").
#
# LAM ships an AD profile (windows_samba4.sample.conf -> windowsUser /
# windowsGroup) that lists AD accounts correctly. This wrapper swaps that AD
# sample in as the one start.sh copies, then hands off to the original start.sh
# unchanged — so LAM's normal password injection (LAM_PASSWORD) and
# server/suffix substitution still run, but the resulting profile actually
# shows AD users and groups.
set -eu

CONFIG_DIR=/var/lib/ldap-account-manager/config
AD_SAMPLE="$CONFIG_DIR/windows_samba4.sample.conf"
LAM_CONF="$CONFIG_DIR/lam.conf"

# The image ships a default lam.conf, and start.sh only copies a sample when
# lam.conf is ABSENT — otherwise it just patches the existing (Unix) profile in
# place. So lay down LAM's Active Directory sample AS lam.conf ourselves; start.sh
# then substitutes the server URL, suffixes, and password into it exactly as it
# would have for the Unix default. Result: the Users/Groups lists use AD modules
# (windowsUser/windowsGroup) and actually show the directory's accounts.
if [ -f "$AD_SAMPLE" ]; then
  cp "$AD_SAMPLE" "$LAM_CONF"
  chown www-data "$LAM_CONF" 2>/dev/null || true
fi

exec /usr/local/bin/start.sh
