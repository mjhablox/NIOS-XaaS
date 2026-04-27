-- Rollback: R001__drop_tenants_table.sql
-- Reverts: V001__create_tenants_table.sql
-- Description: Drops the tenants table and all associated indexes
-- Author: NIOS-XaaS Team
-- Date: 2026-04-27
--
-- WARNING: This rollback is destructive and will permanently delete all tenant
--          data.  Ensure a backup exists before executing this script.
--          Dependent objects (subscriptions, grid_members, networks, dns_zones)
--          must be removed first (see R005 → R002).

DROP INDEX IF EXISTS idx_tenants_status;
DROP INDEX IF EXISTS idx_tenants_slug;
DROP TABLE IF EXISTS tenants;
