-- Migration: V005__create_dns_zones_table.sql
-- Description: Creates the dns_zones table for DNS zone management
-- Author: NIOS-XaaS Team
-- Date: 2026-04-27

CREATE TABLE IF NOT EXISTS dns_zones (
    id              UUID          PRIMARY KEY DEFAULT gen_random_uuid(),
    tenant_id       UUID          NOT NULL REFERENCES tenants (id) ON DELETE CASCADE,
    fqdn            VARCHAR(255)  NOT NULL,
    zone_type       VARCHAR(50)   NOT NULL DEFAULT 'authoritative'
                                  CHECK (zone_type IN ('authoritative', 'forward', 'stub')),
    view            VARCHAR(100)  NOT NULL DEFAULT 'default',
    status          VARCHAR(50)   NOT NULL DEFAULT 'active'
                                  CHECK (status IN ('active', 'disabled')),
    created_at      TIMESTAMP     NOT NULL DEFAULT NOW(),
    updated_at      TIMESTAMP     NOT NULL DEFAULT NOW(),

    CONSTRAINT uq_dns_zones_tenant_fqdn_view UNIQUE (tenant_id, fqdn, view)
);

CREATE INDEX IF NOT EXISTS idx_dns_zones_tenant_id  ON dns_zones (tenant_id);
CREATE INDEX IF NOT EXISTS idx_dns_zones_fqdn       ON dns_zones (fqdn);
CREATE INDEX IF NOT EXISTS idx_dns_zones_status     ON dns_zones (status);

COMMENT ON TABLE  dns_zones             IS 'DNS zones delegated to or managed by NIOS-XaaS per tenant';
COMMENT ON COLUMN dns_zones.fqdn        IS 'Fully qualified domain name of the zone apex';
COMMENT ON COLUMN dns_zones.zone_type   IS 'DNS zone type (authoritative, forward, or stub)';
COMMENT ON COLUMN dns_zones.view        IS 'DNS view this zone belongs to';
