-- Migration: V001__create_tenants_table.sql
-- Description: Creates the tenants table for NIOS-XaaS multi-tenancy support
-- Author: NIOS-XaaS Team
-- Date: 2026-04-27

CREATE TABLE IF NOT EXISTS tenants (
    id            UUID          PRIMARY KEY DEFAULT gen_random_uuid(),
    name          VARCHAR(255)  NOT NULL,
    slug          VARCHAR(100)  NOT NULL UNIQUE,
    status        VARCHAR(50)   NOT NULL DEFAULT 'active'
                                CHECK (status IN ('active', 'suspended', 'deprovisioned')),
    created_at    TIMESTAMP     NOT NULL DEFAULT NOW(),
    updated_at    TIMESTAMP     NOT NULL DEFAULT NOW()
);

CREATE INDEX IF NOT EXISTS idx_tenants_slug   ON tenants (slug);
CREATE INDEX IF NOT EXISTS idx_tenants_status ON tenants (status);

COMMENT ON TABLE  tenants            IS 'Top-level organizational units served by NIOS-XaaS';
COMMENT ON COLUMN tenants.slug       IS 'URL-safe unique identifier for the tenant';
COMMENT ON COLUMN tenants.status     IS 'Lifecycle state of the tenant';
