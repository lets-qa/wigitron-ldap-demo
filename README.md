# Wigitron Active Directory LDAP Mock Environment

This repository provides a fully functional, containerized Active Directory LDAP simulator based on Samba. It is designed for testing legacy applications that rely on Microsoft AD specific schemas (like `sAMAccountName`, `userPrincipalName`, and nested groups).

## Included Files

- `docker-compose.yml`: Defines the Samba container, port mappings, and persistent volumes.
- `docker-compose.international.yml`: Defines a second Samba container for the `intl.wigitron.com` office domain on separate ports and volumes.
- `Dockerfile`: Builds the Ubuntu-based image and installs necessary Samba and LDAP utilities.
- `entrypoint.sh`: Provisions the `WIGITRON.COM` domain upon first boot and starts the Samba daemon.
- `seed_directory.sh`: A helper script that executes inside the running container to create nested organizational groups (`All_Engineering`, `Dev_Team`, `QA_Team`) and populates them with 20 mock users.
- `add_email_groups.sh`: An add-on script to create shared distribution lists (e.g., `all@wigitron.com`, `support@wigitron.com`) and map them to mock users.
- `test_binds.sh`: A host-side script to verify that LDAP authentication (binds) is functioning correctly using `ldapwhoami`.
- `seed_international_directory.sh`, `add_international_email_groups.sh`, `test_international_binds.sh`: Companion scripts for the `intl.wigitron.com` office domain.

## Prerequisites

- Docker and Docker Compose installed on your host machine.
- Optional: `ldap-utils` installed on your host if you wish to run the `test_binds.sh` and email queries locally.

## Deployment Instructions

Follow these steps to build the image, provision the domain, and inject the mock data.

### 1. Make Scripts Executable
Before building the container, ensure the helper scripts have execution permissions.
    
    chmod +x entrypoint.sh seed_directory.sh add_email_groups.sh test_binds.sh

### 2. Build and Start the Environment
Launch the environment in detached mode. The initial build will take a moment as it downloads Ubuntu and installs the packages. Once running, the `entrypoint.sh` script will automatically provision the domain structure.
    
    docker compose up -d --build

*Note: Give the container about 10-15 seconds after starting for the Samba daemon to fully initialize.*

### International Office Domain
To stand up a separate office domain for `intl.wigitron.com`, run the parallel compose stack and its companion scripts:

    docker compose -f docker-compose.international.yml up -d --build
    ./seed_international_directory.sh
    ./add_international_email_groups.sh
    ./test_international_binds.sh

This stack uses `ldap://localhost:1389`, `ldaps://localhost:1636`, and provisions its data in separate Docker volumes so it stays isolated from the default environment.

#### Query Groups from the International Domain

To retrieve all groups from the `intl.wigitron.com` directory, run this `curl` command from your host. The LDAP URL encodes the base DN, the attributes to return (`cn` and `mail`), the search scope (`sub` for the full subtree), and the filter (`objectClass=group`):

    curl -u 'cn=Administrator,cn=Users,dc=intl,dc=wigitron,dc=com:Admin!Test1234' \
      "ldap://localhost:1389/dc=intl,dc=wigitron,dc=com?cn,mail?sub?(objectClass=group)"

*The output will list all six groups seeded by the companion scripts: `All_Engineering`, `Dev_Team`, `QA_Team`, `All_Company`, `Support_Team`, and `Marketing_Team`, along with their `mail` attributes where set.*

### Running Both Domains at the Same Time

Docker Compose can merge multiple files in a single command. Pass both compose files with `-f` flags and both containers will build and start in parallel:

    docker compose -f docker-compose.yml -f docker-compose.international.yml up -d --build

Once both containers are running, seed and verify each domain independently:

    # Default domain (wigitron.com)
    ./seed_directory.sh
    ./add_email_groups.sh
    ./test_binds.sh

    # International office domain (intl.wigitron.com)
    ./seed_international_directory.sh
    ./add_international_email_groups.sh
    ./test_international_binds.sh

To stop both domains at once, pass both files again:

    docker compose -f docker-compose.yml -f docker-compose.international.yml down

To wipe both environments completely (destroying all test data and volumes):

    docker compose -f docker-compose.yml -f docker-compose.international.yml down -v

> **Future option:** A single `docker-compose.all.yml` that defines both services and all four volumes in one file could replace the two-file `-f` approach above. This would allow a plain `docker compose -f docker-compose.all.yml up -d --build` with no flags needed. This is not yet implemented but is a straightforward next step if the number of domains grows.

### 3. Inject the Test Data
Once the container is healthy, run the seeding scripts from your host machine. 

First, rapidly build the organizational nested groups and populate the 20 test users (`testuser1` to `testuser20` with passwords `Password!1` to `Password!20`):
    
    ./seed_directory.sh

Next, create the shared email distribution lists and map the existing users to them:

    ./add_email_groups.sh

### 4. Verify Authentication
Run the bind testing script to confirm the directory is accepting credentials. This script will attempt 5 successful logins and 2 deliberate failures to ensure the directory is enforcing authentication properly.
    
    ./test_binds.sh

If `ldapwhoami` is not installed on the host, the bind scripts will automatically execute the validation from inside the running Samba container.

### 5. Verify Email Group Routing
If you are testing mail servers or applications that need to resolve distribution lists, you can verify the LDAP mapping by querying the directory for the members of a shared email address. 

Run this command to ask the directory for everyone assigned to the support email:

    ldapsearch -H ldap://localhost:389 \
      -D "cn=Administrator,cn=Users,dc=wigitron,dc=com" \
      -w 'Admin!Test1234' \
      -b "dc=wigitron,dc=com" \
      "(mail=support@wigitron.com)" \
      member

*The output should cleanly list the distinguished names (DN) of test users 1 through 5.*

#### Query Groups from the Local Domain

The local domain is `wigitron.com` on port `389`, so the base DN is
`dc=wigitron,dc=com`. This is the local equivalent of the international
`curl` query above:

    curl -u 'cn=Administrator,cn=Users,dc=wigitron,dc=com:Admin!Test1234' \
      "ldap://localhost:389/dc=wigitron,dc=com?cn,mail?sub?(objectClass=group)"

Querying from the domain root returns AD's built-in groups (`Domain Admins`,
`Schema Admins`, etc.) alongside the seeded ones. To list **only** the seeded
distribution lists, filter for mail-enabled groups:

    curl -u 'cn=Administrator,cn=Users,dc=wigitron,dc=com:Admin!Test1234' \
      "ldap://localhost:389/dc=wigitron,dc=com?cn,mail?sub?(&(objectClass=group)(mail=*))"

*That returns just `All_Company`, `Support_Team`, and `Marketing_Team` with their
`mail` addresses.*

## Stopping and Resetting

**To stop the environment (while keeping your data):**
    
    docker compose down

**To completely wipe the environment (destroying all test users and the domain):**
    
    docker compose down -v

*Running `docker compose up -d` after wiping the volumes will trigger a fresh domain provision.*

## Connection Details

Legacy applications can connect to this environment using the following parameters:

- **LDAP URI:** `ldap://localhost:389` (or the Docker host's IP)
- **LDAPS URI:** `ldaps://localhost:636` *(Self-signed certificate)*
- **Domain:** `wigitron.com`
- **Base DN:** `dc=wigitron,dc=com`
- **Bind Credentials (UPN):** `testuser1@wigitron.com`
- **Bind Credentials (DN):** `cn=Administrator,cn=Users,dc=wigitron,dc=com`
- **Administrator Password:** `Admin!Test1234`

### Test User Credentials

All 20 test users follow the same naming and password pattern:

| Username | Password |
|---|---|
| `testuser1` | `Password!1` |
| `testuser2` | `Password!2` |
| `testuser3` | `Password!3` |
| ... | ... |
| `testuser20` | `Password!20` |

Users 1–10 belong to `Dev_Team`, and users 11–20 belong to `QA_Team`. Both child groups are nested inside `All_Engineering`. The same credentials apply to both the default (`wigitron.com`) and international (`intl.wigitron.com`) domains.

---

## Consolidating a Separate-Port Domain into an OU

A domain running as its own container on its own ports (for example the
international DC on `1389`/`1636`) can be migrated into an **Organizational Unit**
inside the single main DC — one container, no extra ports — with two scripts.
Passwords are re-set on import (Active Directory cannot export plaintext
secrets); for test users the known `Password!<N>` convention is reapplied
automatically, and all other accounts get `DEFAULT_PASSWORD` (default
`Admin!Test1234`).

### Step 1 — Export the live directory (read-only)

    ./export_directory.sh samba-dc-international intl.json

This captures users (name, mail, enabled/disabled) and groups (mail, members
including nesting) into `intl.json`. It never modifies the source, so it is safe
against a live DC. Built-in `Administrator`, `Guest`, and `krbtgt` are excluded.

### Step 2 — Preview the import (dry run)

    ./import_as_ou.sh international intl.json --prefix intl --dry-run

Every object gets a hash suffix derived from `intl.<mail-domain>` (`testuser1_<hash4>`, `Dev_Team_<hash4>`, identical to the staff-portal API naming) to satisfy AD's
domain-wide uniqueness rule. `--dry-run` prints the exact `samba-tool` commands
without executing them — review it before committing.

### Step 3 — Import for real

    ./import_as_ou.sh international intl.json --prefix intl

Verify:

    docker exec samba-dc samba-tool user list | grep '_<hash4>$'

#### Query Groups from an Imported OU

To retrieve all groups from an org seeded into an OU, run this `curl` command from
your host. Unlike the separate-port international domain, an OU lives inside the
**main** DC on port `389`, so the base DN is the OU under the main domain. The
LDAP URL encodes the base DN, the attributes to return (`cn` and `mail`), the
search scope (`sub`), and the filter (`objectClass=group`):

    curl -u 'cn=Administrator,cn=Users,dc=wigitron,dc=com:Admin!Test1234' \
      "ldap://localhost:389/OU=international,dc=wigitron,dc=com?cn,mail?sub?(objectClass=group)"

The base DN depends on how the OU was created:

- `./import_as_ou.sh international intl.json` creates a **flat** OU →
  `OU=international,dc=wigitron,dc=com` (as above).
- The staff-portal API (`POST /domains {"fqdn": "intl.wigitron.com"}`) maps each
  FQDN label to a **nested** OU (dropping the TLD) →
  `OU=intl,OU=wigitron,dc=wigitron,dc=com`. Adjust the base DN accordingly.

*The output lists the six hash-suffixed groups seeded into that OU —
`All_Engineering_<hash4>`, `Dev_Team_<hash4>`, `QA_Team_<hash4>`,
`All_Company_<hash4>`, `Support_Team_<hash4>`, and `Marketing_Team_<hash4>` — with
their `mail` attributes where set.*

**Not round-tripped by design:** passwords (reset to known values) and the name
suffix. Everything else — structure, attributes, memberships, nesting, disabled
state — carries across. Once verified, the separate `docker-compose.international.yml`
stack and its ports can be retired.

---

## Adding a New Domain

The scripts in this repository are fully parameterized, so adding a new office domain is a repeatable, four-step process.

### Step 1 — Create a compose file for the new domain

Copy `docker-compose.international.yml` to a new file, e.g. `docker-compose.apac.yml`, and update the three values that must be unique per domain:

| Field | Must be unique | Example value |
|---|---|---|
| `services` key | yes | `samba-dc-apac` |
| `container_name` | yes | `samba-dc-apac` |
| `AD_NETBIOS_DOMAIN` | yes (max 15 chars, uppercase) | `WIGITRONAPAC` |
| `AD_REALM` | yes (FQDN, uppercase) | `APAC.WIGITRON.COM` |
| `AD_ADMIN_PASSWORD` | recommended | `Admin!Apac1234` |
| Host ports | yes (must not clash with existing stacks) | `"2389:389"` and `"2636:636"` |
| Volume names | yes | `samba-data-apac` and `samba-config-apac` |

### Step 2 — Create wrapper scripts for the new domain

Create three thin wrapper scripts that set the container name, mail domain, and LDAP URI, then delegate to the shared scripts:

**`seed_apac_directory.sh`**
```bash
#!/bin/bash
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SAMBA_CONTAINER="samba-dc-apac" \
MAIL_DOMAIN="apac.wigitron.com" \
"${SCRIPT_DIR}/seed_directory.sh"
```

**`add_apac_email_groups.sh`**
```bash
#!/bin/bash
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SAMBA_CONTAINER="samba-dc-apac" \
MAIL_DOMAIN="apac.wigitron.com" \
"${SCRIPT_DIR}/add_email_groups.sh"
```

**`test_apac_binds.sh`**
```bash
#!/bin/bash
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SAMBA_CONTAINER="samba-dc-apac" \
LDAP_URI="ldap://localhost:2389" \
DOCKER_INTERNAL_LDAP_URI="ldap://127.0.0.1:389" \
UPN_DOMAIN="apac.wigitron.com" \
"${SCRIPT_DIR}/test_binds.sh"
```

Make all three executable:

    chmod +x seed_apac_directory.sh add_apac_email_groups.sh test_apac_binds.sh

### Step 3 — Start the new domain

Start only the new domain:

    docker compose -f docker-compose.apac.yml up -d --build

Or start all domains together by adding the new file to the `-f` chain:

    docker compose -f docker-compose.yml \
                   -f docker-compose.international.yml \
                   -f docker-compose.apac.yml \
                   up -d --build

*Give each new container about 10-15 seconds to finish provisioning before running the seed scripts.*

### Step 4 — Seed and verify

    ./seed_apac_directory.sh
    ./add_apac_email_groups.sh
    ./test_apac_binds.sh

### Environment variable reference

The shared scripts read the following variables. All have sensible defaults so existing behaviour is unchanged when they are not set.

| Variable | Default | Description |
|---|---|---|
| `SAMBA_CONTAINER` | `samba-dc` | Docker container name to exec commands against |
| `MAIL_DOMAIN` | `wigitron.com` | Email domain suffix used when creating users and groups |
| `LDAP_URI` | `ldap://localhost:389` | LDAP URI used by the host-side bind test |
| `DOCKER_INTERNAL_LDAP_URI` | `ldap://127.0.0.1:389` | LDAP URI used when running the bind test inside the container |
| `UPN_DOMAIN` | `wigitron.com` | UPN suffix (`user@domain`) used in bind tests |
| `AD_NETBIOS_DOMAIN` | `WIGITRON` | NetBIOS/short domain name (max 15 chars) passed to `samba-tool domain provision` |
| `AD_REALM` | `WIGITRON.com` | Full DNS realm passed to `samba-tool domain provision` |
| `AD_ADMIN_PASSWORD` | `Admin!Test1234` | Administrator password set during domain provisioning |

---

### Overriding Host Ports

The container always listens on `389`/`636` internally; only the published **host**
ports are configurable, so a single deployment that already has those ports taken
(for example a second DC on the same host) doesn't need file edits. Copy
`.env.example` to `.env` and set the ports:

    LDAP_PORT=1389
    LDAPS_PORT=1636

`docker compose up -d` then publishes those ports. `test_binds.sh` also reads
`LDAP_HOST` and `LDAPS_PORT`, so you can point it at a remote DC without editing it:

    LDAP_HOST=ci.bcasqa.com LDAPS_PORT=1636 ./test_binds.sh

### Password Expiry

On first provision the entrypoint disables domain password aging
(`--max-pwd-age=0`) and pins the `Administrator` account to never expire. Without
this, Samba's stock 42-day policy silently expires every account — including the
admin — after which no account can bind over LDAP to fix it (`data 532`,
`PASSWORD_EXPIRED`). The reset must then be done locally with `samba-tool` inside
the container.
