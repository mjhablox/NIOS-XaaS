-- Rollback: R004__drop_networks_table.sql
-- Reverts: V004__create_networks_table.sql
-- Description: Drops the networks table and all associated indexes
-- Author: NIOS-XaaS Team
-- Date: 2026-04-27
--
-- WARNING: This rollback is destructive and will permanently delete all network
--          (IPAM) records.  Ensure a backup exists before executing this script.

DROP INDEX IF EXISTS idx_networks_status;
DROP INDEX IF EXISTS idx_networks_cidr;
DROP INDEX IF EXISTS idx_networks_tenant_id;
DROP TABLE IF EXISTS networks;
