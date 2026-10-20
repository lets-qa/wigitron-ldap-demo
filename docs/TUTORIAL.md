# Tutorial: Single-Port Directory, End to End

This walks you from a fresh deploy through verifying it, adding and querying
data, logging into the web GUI, and creating new "domains" two ways — all on the
**single-port** model: one Samba DC on `389`/`636`, and every new org is an
Organizational Unit (OU) inside it. No extra containers, no extra ports.

> zsh note: the admin password `Admin!Test1234` contains a `!`. In zsh, wrap any
> value containing `!` in **single quotes** — double quotes trigger history
> expansion (`event not found`). All examples below already do this.

---

## Step 1 — Deploy, and verify it was set up right

Bring up the DC (and the LAM web GUI, used in Step 4):

```bash
docker compose up -d --build samba-dc lam
# give the DC ~10-15s to provision
```

Now confirm the setup four ways:

```bash
# 1. The domain provisioned (expect Domain: wigitron.com):
docker exec samba-dc samba-tool domain info 127.0.0.1

# 2. The admin can bind over LDAP (expect: u:WIGITRON\Administrator):
docker exec samba-dc ldapwhoami -H ldap://localhost -x \
  -D 'Administrator@wigitron.com' -w 'Admin!Test1234'

# 3. LDAPS (port 636) answers (expect: defaultNamingContext: DC=wigitron,DC=com):
docker exec samba-dc bash -c \
  "LDAPTLS_REQCERT=never ldapsearch -x -H ldaps://localhost:636 -s base -b '' -LLL defaultNamingContext"

# 4. Password-expiry hardening is applied (expect: Maximum password age (days): 0):
docker exec samba-dc samba-tool domain passwordsettings show | grep -i 'maximum password age'
```

If all four look right, the directory is up and correctly configured.

**Connection summary:**

| | |
|---|---|
| LDAP | `ldap://localhost:389` |
| LDAPS | `ldaps://localhost:636` (self-signed) |
| Base DN | `dc=wigitron,dc=com` |
| Admin | `Administrator` / `Admin!Test1234` |

---

## Step 2 — Add groups and users, then query them

Seed the base directory (20 users + nested groups), then the mail-enabled
distribution lists:

```bash
./seed_directory.sh      # testuser1..20 (Password!1..20), All_Engineering/Dev_Team/QA_Team
./add_email_groups.sh    # All_Company, Support_Team, Marketing_Team (with mail)
```

**Query the users:**

```bash
# All users (includes built-ins like Administrator, Guest, krbtgt):
docker exec samba-dc samba-tool user list

# Just the seeded test users:
docker exec samba-dc samba-tool user list | grep '^testuser'
```

**Query the groups over LDAP with curl.** Querying from the domain root returns
AD's built-in groups too, so filter to mail-enabled groups to see just the
seeded distribution lists:

```bash
curl -u 'cn=Administrator,cn=Users,dc=wigitron,dc=com:Admin!Test1234' \
  "ldap://localhost:389/dc=wigitron,dc=com?cn,mail?sub?(&(objectClass=group)(mail=*))"
```

Expect `All_Company` (`all@wigitron.com`), `Support_Team` (`support@…`), and
`Marketing_Team` (`marketing@…`).

**Verify authentication** with the bundled script (5 good logins + 2 deliberate
failures):

```bash
./test_binds.sh
```

---

## Step 3 — Access and log into the web GUI (LAM)

LAM came up in Step 1. Open it in a browser:

**http://localhost:7080**

Log in with the directory admin:

- **Username:** `Administrator`
- **Password:** `Admin!Test1234`

(LAM is pre-configured to point at the DC internally — `ldap://samba-dc:389`,
base `dc=wigitron,dc=com` — with Active Directory account modules so the lists
actually show AD users. If you ever need the LAM *configuration* profile
password, it's `lam`, overridable with `LAM_PASSWORD=…`.)

On the very first login LAM may show a one-time "create suffix" prompt
(`initsuff.php`) because the configured suffix has no matching OU object — it's
harmless; click through it or just go straight to **Users**.

Once in, the **Users** and **Groups** tabs let you browse, create, edit, disable,
and reset accounts — your `testuser*` accounts and the distribution groups all
appear here (you'll see a non-zero "User count"). LAM is how you *manage*
accounts; the API in Step 5 only *creates*.

> Note: the stock LAM Docker image auto-configures itself for *OpenLDAP*
> (posixAccount), which lists **nothing** against Active Directory. This repo
> fixes that with `lam-config/lam-ad-entrypoint.sh` (wired in `docker-compose.yml`),
> which swaps in LAM's Active Directory profile at startup. You don't need to do
> anything — it just works.

Override the port with `LAM_PORT=9090 docker compose up -d lam`.

---

## Step 4 — Make a new "domain" on the command line

A new org is an OU inside the single DC. `seed_ou.sh` takes a **full FQDN** and
seeds the standard structure under it:

```bash
./seed_ou.sh acme.test 5        # OU=acme, 5 users, mail/UPN @acme.test
```

A multi-label FQDN nests (one OU per label except the TLD):

```bash
./seed_ou.sh orange.rmorse.com  # OU=orange,OU=rmorse ; 20 users (default)
```

Verify — list that OU's users, and log in as one:

```bash
# Users in the acme OU:
curl -u 'cn=Administrator,cn=Users,dc=wigitron,dc=com:Admin!Test1234' \
  "ldap://localhost:389/OU=acme,dc=wigitron,dc=com?sAMAccountName,mail?sub?(objectClass=user)"

# Bind as a seeded user (clean UPN; the account name itself is hash-suffixed):
docker exec samba-dc ldapwhoami -H ldap://localhost -x \
  -D 'testuser1@acme.test' -w 'Password!1'
# -> u:WIGITRON\testuser1_<hash>
```

Accounts get mail and UPN of `testuser<i>@acme.test`; the `sAMAccountName` is
`testuser<i>_<hash4>` (a short hash of the FQDN) to stay unique domain-wide.

---

## Step 5 — Make a new "domain" with the API

Same result as Step 4, driven over HTTP. One-time setup of the API's Python env:

```bash
python3 -m venv .venv
.venv/bin/pip install -r staff-portal/backend/requirements.txt
```

Launch it (binds `127.0.0.1:8099` with no auth):

```bash
PYTHON=$PWD/.venv/bin/python UVICORN=$PWD/.venv/bin/uvicorn ./staff-portal/run.sh
```

Drive it via **Swagger** at **http://localhost:8099/docs** (click `POST /domains`
→ "Try it out"), or with curl:

```bash
# Preview first — shows the exact samba-tool plan, touches nothing:
curl -X POST http://localhost:8099/domains \
  -H 'Content-Type: application/json' \
  -d '{"fqdn":"globex.io","user_count":4,"dry_run":true}'

# Seed for real (omit dry_run or set it false):
curl -X POST http://localhost:8099/domains \
  -H 'Content-Type: application/json' \
  -d '{"fqdn":"globex.io","user_count":4}'
```

Verify the same way:

```bash
docker exec samba-dc ldapwhoami -H ldap://localhost -x \
  -D 'testuser1@globex.io' -w 'Password!1'
# -> u:WIGITRON\testuser1_<hash>
```

**The API and `seed_ou.sh` produce byte-identical directories** for the same
FQDN — same OU mapping, naming, mail/UPN, groups, and allocation. Use whichever
fits: the CLI for scripting, the API/Swagger for a UI or remote callers.

To expose the API on the network, set credentials — it then binds all interfaces
and requires HTTP Basic (and refuses to bind non-loopback without auth):

```bash
STAFF_PORTAL_USER=staff STAFF_PORTAL_PASS=secret \
PYTHON=$PWD/.venv/bin/python UVICORN=$PWD/.venv/bin/uvicorn ./staff-portal/run.sh
# then: curl -u staff:secret -X POST http://<host>:8099/domains ...
```

---

## Teardown

```bash
docker compose down        # stop, keep data
docker compose down -v     # wipe everything (fresh provision next start)
```
