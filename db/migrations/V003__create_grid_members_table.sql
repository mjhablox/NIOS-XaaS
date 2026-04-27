-- Migration: V003__create_grid_members_table.sql
-- Description: Creates the grid_members table for NIOS virtual appliance tracking
-- Author: NIOS-XaaS Team
-- Date: 2026-04-27

CREATE TABLE IF NOT EXISTS grid_members (
    id              UUID          PRIMARY KEY DEFAULT gen_random_uuid(),
    tenant_id       UUID          NOT NULL REFERENCES tenants (id) ON DELETE CASCADE,
    hostname        VARCHAR(255)  NOT NULL,
    ip_address      INET          NOT NULL,
    role            VARCHAR(50)   NOT NULL
                                  CHECK (role IN ('grid_master', 'grid_master_candidate', 'member')),
    status          VARCHAR(50)   NOT NULL DEFAULT 'provisioning'
                                  CHECK (status IN ('provisioning', 'active', 'degraded', 'offline', 'deprovisioned')),
    nios_version    VARCHAR(50),
    last_heartbeat  TIMESTAMP,
    created_at      TIMESTAMP     NOT NULL DEFAULT NOW(),
    updated_at      TIMESTAMP     NOT NULL DEFAULT NOW(),

    CONSTRAINT uq_grid_members_tenant_hostname UNIQUE (tenant_id, hostname)
);

CREATE INDEX IF NOT EXISTS idx_grid_members_tenant_id      ON grid_members (tenant_id);
CREATE INDEX IF NOT EXISTS idx_grid_members_status         ON grid_members (status);
CREATE INDEX IF NOT EXISTS idx_grid_members_last_heartbeat ON grid_members (last_heartbeat);

COMMENT ON TABLE  grid_members                  IS 'NIOS virtual appliances (grid members) managed per tenant';
COMMENT ON COLUMN grid_members.role             IS 'Role of this member within the NIOS grid';
COMMENT ON COLUMN grid_members.nios_version     IS 'NIOS software version running on this member';
COMMENT ON COLUMN grid_members.last_heartbeat   IS 'Timestamp of the most recent health-check ping';
