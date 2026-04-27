-- ============================================================
-- lease4_count.sql
-- All SQL queries used by lease4_count.sh
-- ============================================================
-- Variables to substitute:
--   :acct_filter   → AND account_id IN ('123','456',...)  or empty
--   :limit_int     → integer limit (default 30)
--   :xaas_host_ids → comma-separated quoted host IDs for DDIaaS
--   :ophid_list    → comma-separated quoted ophids

-- ============================================================
-- XaaS pre-queries (run against separate DBs)
-- ============================================================

-- Step 1: DDIaaS endpoint-manager DB – get DHCP ophids
-- (run against ddiaas-endpoint-manager-db-dsn)
SELECT e.ophid
FROM endpoints e
WHERE e.endpoint_id IN (
    SELECT DISTINCT endpoint_id
    FROM endpoint_service_az_mapping
    WHERE service_type = 'dhcp'
);

-- Step 2: IPAM DB – map ophids to host IDs
-- (run against ipam-db-dsn)
-- Replace :ophid_list with results from Step 1
SELECT id
FROM hosts
WHERE ophid IN (:ophid_list);


-- ============================================================
-- STANDARD REPORT (no --xaas flag)
-- All queries below run against dhcp-leases DB
-- ============================================================

-- 1. Summary by provider_type and state (host_leases)
SELECT
    CASE WHEN provider_type = 'nios' THEN 'NIOS'
         WHEN provider_type IS NULL THEN 'BloxOne'
         WHEN provider_type = '' THEN 'BloxOne (legacy)'
         ELSE provider_type
    END AS source,
    state,
    COUNT(*) AS lease_count,
    COUNT(DISTINCT host) AS hosts,
    COUNT(DISTINCT ha_group) AS ha_groups,
    COUNT(DISTINCT account_id) AS accounts
FROM host_leases
WHERE type = 'DHCPv4'
  -- :acct_filter
GROUP BY provider_type, state
ORDER BY lease_count DESC;

-- 2. By account_id (BloxOne, state=used, host_leases)
SELECT account_id,
       COUNT(DISTINCT host) AS hosts,
       COUNT(DISTINCT ha_group) AS ha_groups,
       COUNT(*) AS lease_count
FROM host_leases
WHERE type = 'DHCPv4' AND state = 'used'
  AND (provider_type IS NULL OR provider_type = '')
  -- :acct_filter
GROUP BY account_id
ORDER BY lease_count DESC
LIMIT :limit_int;

-- 3. By host (BloxOne, state=used, host_leases)
SELECT host, account_id, ha_group, COUNT(*) AS lease_count
FROM host_leases
WHERE type = 'DHCPv4' AND state = 'used'
  AND (provider_type IS NULL OR provider_type = '')
  -- :acct_filter
GROUP BY host, account_id, ha_group
ORDER BY lease_count DESC
LIMIT :limit_int;

-- 4. By ha_group (BloxOne, state=used, host_leases)
SELECT ha_group, account_id,
       COUNT(DISTINCT host) AS hosts,
       COUNT(*) AS lease_count
FROM host_leases
WHERE type = 'DHCPv4' AND state = 'used'
  AND (provider_type IS NULL OR provider_type = '')
  -- :acct_filter
GROUP BY ha_group, account_id
ORDER BY lease_count DESC
LIMIT :limit_int;

-- 5. Summary by state (leases table)
SELECT state,
       type,
       COUNT(*) AS lease_count,
       COUNT(DISTINCT host) AS hosts,
       COUNT(DISTINCT ha_group) AS ha_groups,
       COUNT(DISTINCT account_id) AS accounts
FROM leases
WHERE type = 'DHCPv4'
  -- :acct_filter
GROUP BY state, type
ORDER BY lease_count DESC;

-- 6. By account_id (state=used, leases table)
SELECT account_id,
       COUNT(DISTINCT host) AS hosts,
       COUNT(DISTINCT ha_group) AS ha_groups,
       COUNT(*) AS lease_count
FROM leases
WHERE type = 'DHCPv4' AND state = 'used'
  -- :acct_filter
GROUP BY account_id
ORDER BY lease_count DESC
LIMIT :limit_int;

-- 7. full_updates by account_id
SELECT account_id,
       COUNT(DISTINCT host) AS hosts,
       COUNT(DISTINCT ha_group) AS ha_groups,
       COUNT(*) AS total_rows
FROM full_updates
WHERE 1=1
  -- :acct_filter
GROUP BY account_id
ORDER BY total_rows DESC
LIMIT :limit_int;

-- 8. nios_grids summary
SELECT account_id, grid_id, import_in_progress
FROM nios_grids
WHERE 1=1
  -- :acct_filter
ORDER BY account_id
LIMIT :limit_int;

-- 9. Row counts per table
SELECT relname AS table_name, n_live_tup AS approx_rows
FROM pg_stat_user_tables
ORDER BY n_live_tup DESC;


-- ============================================================
-- XAAS REPORT (--xaas flag)
-- Run against dhcp-leases DB after Steps 1 & 2
-- Replace :xaas_host_ids with host IDs from Step 2
-- ============================================================

-- X1. DDIaaS (XaaS) summary by state
SELECT state,
       COUNT(*) AS lease_count,
       COUNT(DISTINCT host) AS hosts,
       COUNT(DISTINCT ha_group) AS ha_groups,
       COUNT(DISTINCT account_id) AS accounts
FROM host_leases
WHERE type = 'DHCPv4'
  AND host IN (:xaas_host_ids)
  -- :acct_filter
GROUP BY state
ORDER BY lease_count DESC;

-- X2. DDIaaS (XaaS) leases by account_id (state=used)
SELECT account_id,
       COUNT(DISTINCT host) AS hosts,
       COUNT(DISTINCT ha_group) AS ha_groups,
       COUNT(*) AS lease_count
FROM host_leases
WHERE type = 'DHCPv4' AND state = 'used'
  AND host IN (:xaas_host_ids)
  -- :acct_filter
GROUP BY account_id
ORDER BY lease_count DESC
LIMIT :limit_int;

-- X3. DDIaaS (XaaS) leases by host (state=used)
SELECT host, account_id, ha_group, COUNT(*) AS lease_count
FROM host_leases
WHERE type = 'DHCPv4' AND state = 'used'
  AND host IN (:xaas_host_ids)
  -- :acct_filter
GROUP BY host, account_id, ha_group
ORDER BY lease_count DESC
LIMIT :limit_int;

-- X4. Row counts per table
SELECT relname AS table_name, n_live_tup AS approx_rows
FROM pg_stat_user_tables
ORDER BY n_live_tup DESC;
