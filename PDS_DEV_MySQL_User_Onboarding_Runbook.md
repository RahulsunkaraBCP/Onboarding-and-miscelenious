# PDS DEV MySQL User Onboarding Runbook

## Purpose

Use this process to create a personal MySQL account on the PDS Development Aurora cluster and mirror the approved permissions of an existing developer.

This runbook documents the Walesky Terrero onboarding performed for the `caller_cx` and `tracker50` schemas. It does not cover Linux/SSH accounts or VPN certificate creation.

## Environment

| Setting | Value |
|---|---|
| AWS account | `534725115372` (`PDS Development`) |
| Region | `us-east-1` |
| Aurora cluster | `pds-dev-cluster` |
| Database endpoint | `pds-dev-cluster.cluster-cwmwrw6dbsxc.us-east-1.rds.amazonaws.com` |
| Port | `3306` |
| Database engine | MySQL/Aurora MySQL |
| Required network access | Personal DEV VPN |

## Approved Walesky Access

| Item | Value |
|---|---|
| User | `wterrero` |
| Host pattern | `%` |
| Reference account | `udeleon` (Urico) |
| Schemas | `caller_cx`, `tracker50` |
| Permissions | `SELECT, INSERT, UPDATE, DELETE, CREATE, CREATE TEMPORARY TABLES, EXECUTE, SHOW VIEW` |

These are schema-level developer permissions matching Urico. They are not server-wide administrative permissions. They do not include `ALTER`, `DROP`, user administration, `GRANT OPTION`, or access to other application schemas.

## Prerequisites

- Personal DEV VPN connected.
- Current PDS Development admin credentials.
- Approval confirming:
  - New username.
  - Required schemas.
  - Reference developer to mirror.
  - Read-only versus read/write access.
- Approved password manager or one-time secret-sharing method.

## Procedure

### 1. Connect as the DEV database administrator

Run from a terminal while connected to the DEV VPN:

```bash
mysql \
  -h pds-dev-cluster.cluster-cwmwrw6dbsxc.us-east-1.rds.amazonaws.com \
  -P 3306 \
  -u admin \
  -p
```

Enter the admin password only when prompted. Do not put the password directly in the command.

### 2. Verify the target is the writable DEV database

```sql
SELECT
    CURRENT_USER(),
    USER(),
    @@hostname,
    @@port,
    @@read_only;
```

Confirm:

- `CURRENT_USER()` is the expected admin account.
- `@@port` is `3306`.
- `@@read_only` is `0`.

Stop if `@@read_only` is `1` or if the environment is not PDS Development.

### 3. Review existing human accounts

```sql
SELECT User, Host
FROM mysql.user
ORDER BY User, Host;
```

Choose an approved same-role developer. Do not mirror `admin`, `root`, `rdsadmin`, AWS service accounts, application accounts, or monitoring accounts.

### 4. Inspect the approved reference account

For this onboarding, the approved reference was Urico:

```sql
SHOW GRANTS FOR 'udeleon'@'%';
```

The reference grants were:

```sql
GRANT USAGE ON *.* TO `udeleon`@`%`;
GRANT SELECT, INSERT, UPDATE, DELETE, CREATE, CREATE TEMPORARY TABLES, EXECUTE, SHOW VIEW
ON `tracker50`.* TO `udeleon`@`%`;
GRANT SELECT, INSERT, UPDATE, DELETE, CREATE, CREATE TEMPORARY TABLES, EXECUTE, SHOW VIEW
ON `caller_cx`.* TO `udeleon`@`%`;
```

### 5. Confirm the new username is unused

```sql
SELECT User, Host
FROM mysql.user
WHERE User = 'wterrero';
```

Continue only if no rows are returned.

### 6. Generate and store a temporary password

Run on the administrator's workstation, not inside MySQL:

```bash
openssl rand -base64 24
```

Store the generated value in the approved password manager.

Important: `TEMPORARY_PASSWORD` in the next command is a placeholder. Replace it with the actual generated password. Never use the literal text `TEMPORARY_PASSWORD`.

### 7. Create the MySQL account

```sql
CREATE USER 'wterrero'@'%'
IDENTIFIED BY 'TEMPORARY_PASSWORD';
```

`CREATE USER` automatically adds the `USAGE` entry. `FLUSH PRIVILEGES` is not required when using `CREATE USER` and `GRANT`.

### 8. Grant the approved schema permissions

```sql
GRANT SELECT, INSERT, UPDATE, DELETE,
      CREATE, CREATE TEMPORARY TABLES,
      EXECUTE, SHOW VIEW
ON `tracker50`.*
TO 'wterrero'@'%';

GRANT SELECT, INSERT, UPDATE, DELETE,
      CREATE, CREATE TEMPORARY TABLES,
      EXECUTE, SHOW VIEW
ON `caller_cx`.*
TO 'wterrero'@'%';
```

The `schema_name` followed by `.*` applies the listed permissions to all current and future applicable objects in that schema. It does not grant access to other schemas.

Never use either of the following unless explicitly approved:

```sql
GRANT ALL PRIVILEGES ON *.* TO 'username'@'%';
```

```sql
WITH GRANT OPTION
```

### 9. Verify the account and grants

```sql
SELECT User, Host, account_locked, password_expired
FROM mysql.user
WHERE User = 'wterrero';

SHOW GRANTS FOR 'wterrero'@'%';
```

Expected grants:

```sql
GRANT USAGE ON *.* TO `wterrero`@`%`;
GRANT SELECT, INSERT, UPDATE, DELETE, CREATE, CREATE TEMPORARY TABLES, EXECUTE, SHOW VIEW
ON `tracker50`.* TO `wterrero`@`%`;
GRANT SELECT, INSERT, UPDATE, DELETE, CREATE, CREATE TEMPORARY TABLES, EXECUTE, SHOW VIEW
ON `caller_cx`.* TO `wterrero`@`%`;
```

### 10. Test the new login

Keep the administrator session open. In a second terminal, with the administrator's own DEV VPN connected, run:

```bash
mysql \
  -h pds-dev-cluster.cluster-cwmwrw6dbsxc.us-east-1.rds.amazonaws.com \
  -P 3306 \
  -u wterrero \
  -p
```

Enter Walesky's temporary password when prompted. The terminal does not display characters while a password is typed.

After login:

```sql
SELECT CURRENT_USER();
SHOW DATABASES;

USE caller_cx;
SHOW TABLES;

USE tracker50;
SHOW TABLES;
```

Expected result: the account can see and use `caller_cx` and `tracker50`, plus standard informational schemas. Do not create or modify permanent data merely to test the login.

### 11. Securely hand off the credentials

Share these non-secret connection details through the normal onboarding channel:

```text
Host: pds-dev-cluster.cluster-cwmwrw6dbsxc.us-east-1.rds.amazonaws.com
Port: 3306
Username: wterrero
Schemas: caller_cx and tracker50
VPN: Connect using your personal DEV VPN profile first
```

Share the temporary password only through the approved password manager or an expiring one-time secret link. Do not paste it into Jira, Confluence, email, ordinary Slack messages, or documentation.

Ask the user to confirm:

1. Their personal DEV VPN connects.
2. The MySQL login works.
3. `caller_cx` and `tracker50` are visible.

Revoke or delete the password-sharing link after it is opened. Follow the company's process for changing the temporary password.

## Completion Checklist

- [x] Confirmed PDS Development cluster and endpoint.
- [x] Confirmed schemas: `caller_cx` and `tracker50`.
- [x] Confirmed reference offshore developer: `udeleon`.
- [x] Created MySQL account `wterrero`.
- [x] Mirrored the approved schema grants.
- [ ] Verified `SHOW GRANTS` output.
- [ ] Tested the `wterrero` login.
- [ ] Shared password through an approved secure method.
- [ ] Received confirmation from Walesky that VPN and DB access work.
- [ ] Marked the DEV DB onboarding items complete.

## Reusable Template for Another User

Replace every value in angle brackets before execution:

```sql
-- Confirm that the username is unused.
SELECT User, Host
FROM mysql.user
WHERE User = '<NEW_USERNAME>';

-- Review the approved reference account.
SHOW GRANTS FOR '<REFERENCE_USERNAME>'@'<REFERENCE_HOST>';

-- Create the account with the real securely generated password.
CREATE USER '<NEW_USERNAME>'@'<APPROVED_HOST>'
IDENTIFIED BY '<REAL_TEMPORARY_PASSWORD>';

-- Mirror only the approved schema-level permissions.
GRANT <APPROVED_PRIVILEGES>
ON `<APPROVED_SCHEMA>`.*
TO '<NEW_USERNAME>'@'<APPROVED_HOST>';

-- Verify.
SHOW GRANTS FOR '<NEW_USERNAME>'@'<APPROVED_HOST>';
```

Do not copy passwords, password hashes, global administrative grants, or permissions from unrelated service accounts.
