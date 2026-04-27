-- Rollback: R003__drop_grid_members_table.sql
-- Reverts: V003__create_grid_members_table.sql
-- Description: Drops the grid_members table and all associated indexes
-- Author: NIOS-XaaS Team
-- Date: 2026-04-27
--
-- WARNING: This rollback is destructive and will permanently delete all grid
--          member records.  Ensure a backup exists before executing this script.

DROP INDEX IF EXISTS idx_grid_members_last_heartbeat;
DROP INDEX IF EXISTS idx_grid_members_status;
DROP INDEX IF EXISTS idx_grid_members_tenant_id;
DROP TABLE IF EXISTS grid_members;
