#!/usr/bin/env bash
# -----------------------------------------------------------------------------
# db_rollback.sh – Execute NIOS-XaaS database rollback scripts
#
# Usage:
#   ./scripts/db_rollback.sh [OPTIONS] <target_version>
#
# Arguments:
#   target_version   Roll back TO this version (inclusive).
#                    Use 0 to roll back everything.
#                    Example: "3" rolls back V005 and V004 (down to V003).
#
# Options:
#   -h, --host       Database host          (default: $PGHOST or localhost)
#   -p, --port       Database port          (default: $PGPORT or 5432)
#   -d, --dbname     Database name          (default: $PGDATABASE or nios_xaas)
#   -U, --username   Database user          (default: $PGUSER or nios_xaas)
#   --dry-run        Print SQL without executing
#   --help           Show this help message
#
# Environment variables (all optional – CLI flags take precedence):
#   PGHOST, PGPORT, PGDATABASE, PGUSER, PGPASSWORD
#
# Examples:
#   # Roll back to version 3 (removes migrations V004 and V005)
#   ./scripts/db_rollback.sh 3
#
#   # Full rollback (removes all migrations)
#   ./scripts/db_rollback.sh 0
#
#   # Dry run against a remote host
#   ./scripts/db_rollback.sh --host db.example.com --dry-run 3
# -----------------------------------------------------------------------------
set -euo pipefail

# ---------------------------------------------------------------------------
# Defaults
# ---------------------------------------------------------------------------
DB_HOST="${PGHOST:-localhost}"
DB_PORT="${PGPORT:-5432}"
DB_NAME="${PGDATABASE:-nios_xaas}"
DB_USER="${PGUSER:-nios_xaas}"
DRY_RUN=false
TARGET_VERSION=""

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROLLBACK_DIR="${SCRIPT_DIR}/../db/rollback"

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------
usage() {
    sed -n '/^# Usage:/,/^# -----------/p' "$0" | sed 's/^# \?//'
    exit 0
}

log()  { echo "[$(date -u +%H:%M:%SZ)] $*"; }
err()  { echo "[$(date -u +%H:%M:%SZ)] ERROR: $*" >&2; }
die()  { err "$*"; exit 1; }

# ---------------------------------------------------------------------------
# Argument parsing
# ---------------------------------------------------------------------------
while [[ $# -gt 0 ]]; do
    case "$1" in
        -h|--host)     DB_HOST="$2";      shift 2 ;;
        -p|--port)     DB_PORT="$2";      shift 2 ;;
        -d|--dbname)   DB_NAME="$2";      shift 2 ;;
        -U|--username) DB_USER="$2";      shift 2 ;;
        --dry-run)     DRY_RUN=true;      shift   ;;
        --help)        usage                       ;;
        [0-9]*)
            TARGET_VERSION="$1"
            shift
            ;;
        *)
            die "Unknown argument: $1.  Run with --help for usage."
            ;;
    esac
done

[[ -z "$TARGET_VERSION" ]] && die "Missing required argument <target_version>.  Run with --help."

# Validate target version is a non-negative integer
if ! [[ "$TARGET_VERSION" =~ ^[0-9]+$ ]]; then
    die "<target_version> must be a non-negative integer (got: '$TARGET_VERSION')."
fi

# ---------------------------------------------------------------------------
# Collect rollback scripts
# ---------------------------------------------------------------------------
[[ -d "$ROLLBACK_DIR" ]] || die "Rollback directory not found: $ROLLBACK_DIR"

# Rollback scripts are named R<NNN>__<description>.sql
# Collect them sorted in DESCENDING order (highest version rolled back first)
mapfile -t ROLLBACK_SCRIPTS < <(
    find "$ROLLBACK_DIR" -maxdepth 1 -name 'R[0-9]*.sql' |
    sort --reverse
)

if [[ ${#ROLLBACK_SCRIPTS[@]} -eq 0 ]]; then
    die "No rollback scripts found in $ROLLBACK_DIR"
fi

# ---------------------------------------------------------------------------
# Filter: only roll back scripts whose version number > TARGET_VERSION
# ---------------------------------------------------------------------------
to_execute=()
for script in "${ROLLBACK_SCRIPTS[@]}"; do
    filename="$(basename "$script")"
    # Extract leading digits after 'R'
    version_str="${filename#R}"          # strip leading 'R'
    version_str="${version_str%%__*}"    # strip everything from __ onwards
    version_num=$((10#$version_str))     # convert to base-10 integer

    if (( version_num > TARGET_VERSION )); then
        to_execute+=("$script")
    fi
done

if [[ ${#to_execute[@]} -eq 0 ]]; then
    log "Nothing to roll back – database is already at version $TARGET_VERSION or below."
    exit 0
fi

# ---------------------------------------------------------------------------
# Execute
# ---------------------------------------------------------------------------
log "Rolling back to version $TARGET_VERSION"
log "Scripts to execute (in order):"
for script in "${to_execute[@]}"; do
    log "  $(basename "$script")"
done

if $DRY_RUN; then
    log "DRY RUN – SQL content follows, no changes will be made:"
    echo "------------------------------------------------------------"
    for script in "${to_execute[@]}"; do
        echo "-- ==== $(basename "$script") ===="
        cat "$script"
        echo
    done
    echo "------------------------------------------------------------"
    exit 0
fi

# Build psql connection string
PSQL_CMD=(
    psql
    --host="$DB_HOST"
    --port="$DB_PORT"
    --dbname="$DB_NAME"
    --username="$DB_USER"
    --no-password
    --set ON_ERROR_STOP=1
    --single-transaction
)

for script in "${to_execute[@]}"; do
    filename="$(basename "$script")"
    log "Applying rollback: $filename"
    "${PSQL_CMD[@]}" --file="$script" || die "Failed to execute $filename – rollback aborted."
    log "  ✓ $filename applied successfully"
done

log "Rollback to version $TARGET_VERSION completed successfully."
