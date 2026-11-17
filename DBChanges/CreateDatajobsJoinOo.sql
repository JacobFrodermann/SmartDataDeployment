-- Creates the table linking datajobs to the observed objects (observedobject) they belong to.
-- Mirrors the datajobs_join_oo collection in
-- SmartDataJobs/web/data/admin/presets/base.json (preset "SmartDataJobs Base tables").
--
-- Constraint names follow the naming SmartData derives when creating the
-- table from the preset JSON (<table>_<refCollection>_<refAttribute>_<column>),
-- so this SQL and the preset install produce the same schema.
--
-- NOTE: the role webengineering_group originally had neither CREATE on
-- schema smartmonitoring nor REFERENCES on the parent tables (see
-- AGENTS.md §10.6). Both grants were issued by the schema owner on
-- 2026-11-17; the file was then applied as webengineering_group.
-- If run as the schema owner instead, no grants are needed.

CREATE TABLE IF NOT EXISTS smartmonitoring.datajobs_join_oo (
    id          bigserial   PRIMARY KEY,
    datajob_id  int8        NOT NULL,
    oo_id       int8        NOT NULL,
    CONSTRAINT datajobs_join_oo_datajobs_id_datajob_id
        FOREIGN KEY (datajob_id)
        REFERENCES smartmonitoring.datajobs(id)
        ON UPDATE CASCADE ON DELETE CASCADE,
    CONSTRAINT datajobs_join_oo_tbl_observedobject_id_oo_id
        FOREIGN KEY (oo_id)
        REFERENCES smartmonitoring.tbl_observedobject(id)
        ON UPDATE CASCADE ON DELETE CASCADE
);
