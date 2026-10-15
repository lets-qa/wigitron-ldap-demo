#!/bin/bash

NETBIOS_DOMAIN="${AD_NETBIOS_DOMAIN:-WIGITRON}"
AD_REALM="${AD_REALM:-WIGITRON.com}"
AD_ADMIN_PASSWORD="${AD_ADMIN_PASSWORD:-Admin!Test1234}"
LDAP_STRONG_AUTH="${LDAP_STRONG_AUTH:-no}"

if [ ! -f /var/lib/samba/private/sam.ldb ]; then
    echo "Provisioning new AD domain..."
    samba-tool domain provision \
        --domain="${NETBIOS_DOMAIN}" \
        --realm="${AD_REALM}" \
        --server-role=dc \
        --dns-backend=SAMBA_INTERNAL \
        --adminpass="${AD_ADMIN_PASSWORD}" \
        --use-rfc2307
    
    cp /var/lib/samba/private/krb5.conf /etc/krb5.conf

    # Allow legacy applications to perform plaintext simple binds over port 389
    sed -i "/\\[global\\]/a \\        ldap server require strong auth = ${LDAP_STRONG_AUTH}" /etc/samba/smb.conf

    # Disable password aging for this test directory so the admin (and seeded
    # users) never expire out from under you. Without this, the stock 42-day
    # max-password-age silently expires every account and no admin can bind to
    # fix it over LDAP (data 532 PASSWORD_EXPIRED).
    samba-tool domain passwordsettings set --max-pwd-age=0

    # Belt-and-suspenders: pin the built-in Administrator to never expire.
    samba-tool user setexpiry Administrator --noexpiry
fi

echo "Starting Samba AD DC..."
exec samba -i --debug-stdout
