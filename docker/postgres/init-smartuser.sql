-- SmartUser maps its entities to the PostgreSQL schema "smartuser".
-- This script runs once when the PostgreSQL data volume is initialized.
CREATE SCHEMA IF NOT EXISTS smartuser AUTHORIZATION CURRENT_USER;

-- The monitoring front end stores coordinates as geometry(PointZ,4326), so the
-- database needs PostGIS. The image is postgis/postgis:16-3.4-alpine; plain
-- PostgreSQL would fail to create tbl_location.
-- On an existing volume the extension is created by
-- scripts/init-smartmonitoring.sh instead, because this file only runs once.
CREATE EXTENSION IF NOT EXISTS postgis;
