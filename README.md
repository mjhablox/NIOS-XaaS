# NIOS-XaaS

Operational tooling for DDIaaS (DHCP-as-a-Service) — endpoint lifecycle, upgrade debugging, Kea 2.6→2.2 rollback, and lease count reporting.

## Prerequisites

- `kubectl` configured with access to DDIaaS clusters (e.g. `ddi-stg-use1`)
- `jq` installed
- Python 3 with `requests` (for `create_endpoint.py`)
- Teleport access for cloud cluster contexts (for lease count scripts)

## Scripts

### debug_endpoint.sh

Diagnoses DDIaaS DHCP endpoint installation and upgrade issues. Checks FFO targeting, priority conflicts, Application CRs, HelmReleases, pod status, container images per AZ, CNPG clusters, endpoint-manager state machine logs, and more.

```bash
./debug_endpoint.sh <endpoint_id>
```

### create_endpoint.py

End-to-end DDIaaS DHCP service creation and upgrade test. Creates a Universal Service, provisions DHCP resources, sets up IPsec, verifies DHCP lease, then triggers a Kea upgrade via FFO patch and re-verifies.

```bash
export CSP_URL=stage.csp.infoblox.com
export CSP_API_TOKEN=<token>
python3 create_endpoint.py --no-cleanup
```

### run.sh

Wrapper that activates the Python venv and runs `create_endpoint.py` with staging credentials.

## Rollback/

Manual Kea 2.6 → 2.2 rollback procedure. Run scripts in order per endpoint.

| Script | Purpose |
|---|---|
| `start_rollback.sh` | Orchestrates the full rollback for a list of endpoint IDs |
| `01_scale_down.sh <endpoint_id>` | Scales down Kea 2.6 deployments to 0 replicas (both AZs) |
| `02_fix_db.sh <endpoint_id> [reset\|restore]` | Rolls back DB schema from v22 → v13. `reset` drops all tables (Kea re-inits on startup); `restore` uses backup_premigration |
| `03_verify_db.sh <endpoint_id> [kea22\|kea26]` | Verifies DB schema version, table/index/trigger/FK counts match expected values |

```bash
# Single endpoint
./01_scale_down.sh tgbldq4oq22unr3fgm6nmauqdi446zol
./02_fix_db.sh tgbldq4oq22unr3fgm6nmauqdi446zol reset
./03_verify_db.sh tgbldq4oq22unr3fgm6nmauqdi446zol

# Batch (edit endpoint list in start_rollback.sh)
./start_rollback.sh
```

## CountInformation/

Lease count reporting across DDIaaS and cloud clusters.

| Script | Purpose |
|---|---|
| `ddiaas_lease4_count.sh` | Counts DHCPv4 leases per endpoint across DDIaaS clusters via CNPG pod queries |
| `lease4_count.sh` | Counts DHCPv4 leases from the cloud dhcp-leases DB; `--xaas` classifies leases as DDIaaS vs NIOS |
| `lease4_count.sql` | Raw SQL for lease4 count queries |

```bash
# Staging lease count with account mapping
bash ddiaas_lease4_count.sh --contexts ddi-stg-use1 \
  --cloud-context teleport.services.sdp.infoblox.com-us-stg-1

# Cloud lease count with DDIaaS classification
bash lease4_count.sh --context teleport.services.sdp.infoblox.com-us-stg-1 --xaas \
  --ddiaas-context ddi-stg-use1
```

Output files: `STG.txt`, `NA.txt`, `EU.txt` contain saved results per environment.
