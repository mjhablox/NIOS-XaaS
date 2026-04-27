-- Migration: V004__create_networks_table.sql
-- Description: Creates the networks table for IP address management (IPAM)
-- Author: NIOS-XaaS Team
-- Date: 2026-04-27

CREATE TABLE IF NOT EXISTS networks (
    id              UUID          PRIMARY KEY DEFAULT gen_random_uuid(),
    tenant_id       UUID          NOT NULL REFERENCES tenants (id) ON DELETE CASCADE,
    cidr            CIDR          NOT NULL,
    name            VARCHAR(255),
    description     TEXT,
    vlan_id         INTEGER       CHECK (vlan_id BETWEEN 1 AND 4094),
    status          VARCHAR(50)   NOT NULL DEFAULT 'active'
                                  CHECK (status IN ('active', 'reserved', 'deprecated')),
    created_at      TIMESTAMP     NOT NULL DEFAULT NOW(),
    updated_at      TIMESTAMP     NOT NULL DEFAULT NOW(),

    CONSTRAINT uq_networks_tenant_cidr UNIQUE (tenant_id, cidr)
);

CREATE INDEX IF NOT EXISTS idx_networks_tenant_id ON networks (tenant_id);
CREATE INDEX IF NOT EXISTS idx_networks_cidr      ON networks USING GIST (cidr inet_ops);
CREATE INDEX IF NOT EXISTS idx_networks_status    ON networks (status);

COMMENT ON TABLE  networks             IS 'IP networks managed by IPAM for each tenant';
COMMENT ON COLUMN networks.cidr        IS 'Network address with prefix length (e.g. 10.0.0.0/24)';
COMMENT ON COLUMN networks.vlan_id     IS 'Optional 802.1Q VLAN tag associated with this network';
