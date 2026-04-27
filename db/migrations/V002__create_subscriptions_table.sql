-- Migration: V002__create_subscriptions_table.sql
-- Description: Creates the subscriptions table linking tenants to service plans
-- Author: NIOS-XaaS Team
-- Date: 2026-04-27

CREATE TABLE IF NOT EXISTS subscriptions (
    id              UUID          PRIMARY KEY DEFAULT gen_random_uuid(),
    tenant_id       UUID          NOT NULL REFERENCES tenants (id) ON DELETE CASCADE,
    plan            VARCHAR(100)  NOT NULL
                                  CHECK (plan IN ('starter', 'standard', 'enterprise')),
    status          VARCHAR(50)   NOT NULL DEFAULT 'active'
                                  CHECK (status IN ('active', 'suspended', 'cancelled')),
    licensed_nodes  INTEGER       NOT NULL DEFAULT 1 CHECK (licensed_nodes > 0),
    starts_at       TIMESTAMP     NOT NULL DEFAULT NOW(),
    expires_at      TIMESTAMP,
    created_at      TIMESTAMP     NOT NULL DEFAULT NOW(),
    updated_at      TIMESTAMP     NOT NULL DEFAULT NOW()
);

CREATE INDEX IF NOT EXISTS idx_subscriptions_tenant_id  ON subscriptions (tenant_id);
CREATE INDEX IF NOT EXISTS idx_subscriptions_status     ON subscriptions (status);
CREATE INDEX IF NOT EXISTS idx_subscriptions_expires_at ON subscriptions (expires_at);

COMMENT ON TABLE  subscriptions                  IS 'Service plan subscriptions for each NIOS-XaaS tenant';
COMMENT ON COLUMN subscriptions.plan             IS 'Service tier selected by the tenant';
COMMENT ON COLUMN subscriptions.licensed_nodes   IS 'Maximum number of NIOS grid members allowed';
COMMENT ON COLUMN subscriptions.expires_at       IS 'NULL means the subscription never expires';
