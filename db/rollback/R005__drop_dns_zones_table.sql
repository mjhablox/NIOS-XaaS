-- Rollback: R005__drop_dns_zones_table.sql
-- Reverts: V005__create_dns_zones_table.sql
-- Description: Drops the dns_zones table and all associated indexes
-- Author: NIOS-XaaS Team
-- Date: 2026-04-27
--
-- WARNING: This rollback is destructive and will permanently delete all DNS zone
--          records.  Ensure a backup exists before executing this script.

DROP INDEX IF EXISTS idx_dns_zones_status;
DROP INDEX IF EXISTS idx_dns_zones_fqdn;
DROP INDEX IF EXISTS idx_dns_zones_tenant_id;
DROP TABLE IF EXISTS dns_zones;
