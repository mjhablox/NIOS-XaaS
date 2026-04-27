# NIOS-XaaS

Database migration and rollback scripts for the NIOS-XaaS service.

## Repository layout

```
db/
  migrations/   Forward migration SQL scripts (Flyway-style versioning)
  rollback/     Corresponding rollback SQL scripts
scripts/
  db_rollback.sh   CLI tool for executing rollback scripts
```

## Migration naming conventions

| Type     | Pattern                          | Example                                  |
|----------|----------------------------------|------------------------------------------|
| Forward  | `V<NNN>__<description>.sql`      | `V001__create_tenants_table.sql`         |
| Rollback | `R<NNN>__<description>.sql`      | `R001__drop_tenants_table.sql`           |

Each rollback script exactly reverts its matching forward migration.

## Current migrations

| Version | Forward migration                         | Description                         |
|---------|-------------------------------------------|-------------------------------------|
| V001    | `V001__create_tenants_table.sql`          | Tenants table                       |
| V002    | `V002__create_subscriptions_table.sql`    | Subscriptions table                 |
| V003    | `V003__create_grid_members_table.sql`     | Grid members table                  |
| V004    | `V004__create_networks_table.sql`         | Networks / IPAM table               |
| V005    | `V005__create_dns_zones_table.sql`        | DNS zones table                     |

## Executing a rollback

### Prerequisites

- `psql` (PostgreSQL client) must be on your `$PATH`.
- The user running the script requires `DROP TABLE` privileges on the target database.
- **Take a database backup before executing any rollback.**

### Usage

```bash
./scripts/db_rollback.sh [OPTIONS] <target_version>
```

`<target_version>` is the version number you want to roll **back to**.  
Scripts whose version is *greater than* `<target_version>` are executed in
descending order so the newest changes are removed first.

| `target_version` | Effect                                                  |
|------------------|---------------------------------------------------------|
| `0`              | Roll back all migrations (full rollback)                |
| `3`              | Remove V005 and V004, leaving V003 and below in place   |

### Options

| Flag              | Description                                      | Default             |
|-------------------|--------------------------------------------------|---------------------|
| `-h`, `--host`    | Database host                                    | `$PGHOST` / localhost |
| `-p`, `--port`    | Database port                                    | `$PGPORT` / 5432    |
| `-d`, `--dbname`  | Database name                                    | `$PGDATABASE` / nios_xaas |
| `-U`, `--username`| Database user                                    | `$PGUSER` / nios_xaas |
| `--dry-run`       | Print SQL without executing                      | –                   |
| `--help`          | Show help                                        | –                   |

### Examples

```bash
# Roll back to version 3 (removes V005 and V004)
./scripts/db_rollback.sh 3

# Full rollback using environment variables for connection details
PGHOST=db.prod.example.com PGDATABASE=nios_xaas PGUSER=admin \
    ./scripts/db_rollback.sh 0

# Preview what would be executed without touching the database
./scripts/db_rollback.sh --host db.example.com --dry-run 3
```

## Adding a new migration / rollback pair

1. Create `db/migrations/V<NNN>__<description>.sql` with the forward DDL.
2. Create `db/rollback/R<NNN>__<description>.sql` that exactly reverts step 1.
3. Update the **Current migrations** table in this README.
