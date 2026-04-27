-- Rollback: R002__drop_subscriptions_table.sql
-- Reverts: V002__create_subscriptions_table.sql
-- Description: Drops the subscriptions table and all associated indexes
-- Author: NIOS-XaaS Team
-- Date: 2026-04-27
--
-- WARNING: This rollback is destructive and will permanently delete all
--          subscription data.  Ensure a backup exists before executing this
--          script.

DROP INDEX IF EXISTS idx_subscriptions_expires_at;
DROP INDEX IF EXISTS idx_subscriptions_status;
DROP INDEX IF EXISTS idx_subscriptions_tenant_id;
DROP TABLE IF EXISTS subscriptions;
