# Database schemas of the Smart\* stack

This document collects every JSON file in the projects' web directories that
describes database objects, explains the format they share, and gives an
overview of the tables and seed data they define — plus how each definition
reaches the database and where the live database has drifted from the files.

Where the JSONs are the source of truth, the tables below were generated from
them with `scripts/gen_schema_doc.py` (§6) — do not hand-edit the generated
sections; fix the JSON and regenerate.

## Contents

- [1. Where schemas are defined](#1-where-schemas-are-defined)
- [2. The shared JSON format](#2-the-shared-json-format)
- [3. Table catalogue](#3-table-catalogue)
  - [3.1 SmartMonitoringFrontend — base schema](#31-smartmonitoringfrontend--base-schema)
  - [3.2 SmartMonitoringFrontend — function-owned tables](#32-smartmonitoringfrontend--function-owned-tables)
  - [3.3 SmartDataJobs / SmartUser — datajobs schema](#33-smartdatajobs--smartuser--datajobs-schema)
  - [3.4 SmartMonitoringFrontend — legacy presets](#34-smartmonitoringfrontend--legacy-presets)
  - [3.5 SmartUser — JPA schema (not JSON)](#35-smartuser--jpa-schema-not-json)
- [4. Seed data](#4-seed-data)
- [5. How the JSONs reach the database](#5-how-the-jsons-reach-the-database)
- [6. Keeping this document in sync](#6-keeping-this-document-in-sync)
- [7. Drift between files and the live database](#7-drift-between-files-and-the-live-database)

---

## 1. Where schemas are defined

The stack has **no central schema definition**. Instead, each web application
ships JSON "presets" that its admin setup page can push into a SmartData
storage (= PostgreSQL schema). SmartUser is the exception: its tables come
from JPA annotations (`hibernate.hbm2ddl.auto=update`), not from JSON.

| Project | File | Defines | Consumer |
| --- | --- | --- | --- |
| `SmartMonitoringFrontend` | `data/admin/presets/base.json` | `smartmonitoring` base tables + nav/function seed rows | `sites/admin/setup.html` via SWAC `PresetManager` |
| `SmartMonitoringFrontend` | `data/admin/functions/functions.json` | 69 function entries; 13 carry table definitions across 10 functions | `sites/admin/functions.html` via SWAC `Present` |
| `SmartMonitoringFrontend` | `data/admin/presets/ootypes.json` | seed rows for dataset/object types (OpenWeatherMap) | `sites/admin/objecttypes.html` via `PresetManager`; **install is broken** (§7.9) |
| `SmartMonitoringFrontend` | `data/admin/presets/papendorf_pv.json` | seed rows for a PV device type (513 join rows) | not referenced by any page; **install is broken** (§7.9) |
| `SmartMonitoringFrontend` | `data/admin/presets/legacy/*/` | 10 folders, 97 JSON files, 8 tables + 3510 seed rows | **not referenced anywhere** — see its own `legacy/readme.md` |
| `SmartMonitoringFrontend` | `data/routes_device.json` | UI routes (device context menus), **not** a DB schema | `sites/device/*.html` |
| `SmartDataJobs` | `web/data/admin/presets/base.json` | `datajobs*` + `sensordata`/`label_timed` tables, job seed rows | `web/sites/admin/setup.html` |
| `SmartUser` | `web/data/admin/presets/base.json` | same as SmartDataJobs (older copy, §7) | `web/sites/admin/setup.html` |
| `SmartData` | `web/data/admin/presets/base.json` | **empty file (0 bytes)** | `web/sites/admin/setup.html` shows no presets |
| `SmartUser` | `src/.../persistence/jpa/*.java` | `smartuser` schema via JPA | Hibernate at deploy time |

All preset tables land in the PostgreSQL schema `smartmonitoring` (database
`smartmonitoring_test` on the provided server) — the admin pages hardcode
`?storage=smartmonitoring`. The `datajobs*` tables therefore live in the *same*
schema as the monitoring tables, not in a separate one.

SWAC and SWACdoc contribute **no** database schemas (SWACdoc is fully static
and file-based; its `configuration.js` SmartData source is commented out).

## 2. The shared JSON format

All preset files use the same shape, understood by SWAC's
`PresetManager` component (`SWAC/swac/components/PresetManager/`):

```json
{
  "list": [
    {
      "name": "Preset title",
      "desc": "Description",
      "version": "3.0 Alpha",
      "state":  [ { "name": "tbl_x", "type": "rest", "method": "defs", "fromName": "tbl_x" } ],
      "collections": [ { "name": "tbl_x", "fromName": "tbl_x", "method": "cdefs",
                         "body": { "name": "tbl_x", "attributes": [ ... ] } } ],
      "data": [ { "name": "tbl_x", "fromName": "tbl_x", "method": "create",
                  "checkfor": "ckey", "body": [ { ... row ... } ] } ]
    }
  ]
}
```

- **`state`** — how PresetManager decides whether a preset is installed: one
  REST call per entry (`defs` → `GET /collection/{fromName}`); if the response
  is not ok, the part is missing. Optional `check` / `filter` compare a record
  attribute (`check: "active=true"`, `filter: "id,eq,104"`).
- **`collections`** — table definitions, installed with `cdefs` →
  `POST /collection/{fromName}`. Each attribute has `name`, `type` (a
  PostgreSQL type string, passed through verbatim — `bigserial`, `varchar(255)`,
  `geometry(PointZ,4326)`, …), `isNullable`, `isIdentity`, `isAutoIncrement`,
  optional `default`, and optional reference fields `refCollection`,
  `refAttribute`, `refStorage`, `refOnDelete`, `refOnUpdate` which SmartData
  turns into a real `FOREIGN KEY ... REFERENCES` clause.
- **`data`** — seed rows, installed with `create` → `POST /records/{fromName}`.
  `checkfor` names the columns used to detect "row already exists" (e.g.
  `ckey`), which drives the *update* button instead of re-inserting.

Uninstall is `DELETE` against the same URL the part's `method` maps to,
with `?cascade=true` appended: for `collections` parts that is
`DELETE /collection/{fromName}` (drops the table), for `data` parts
`DELETE /records/{fromName}` — which deletes **every row** of the table
(`DELETE FROM ... CASCADE`, no filter), not just the seeded ones.

`functions.json` is a variant used by `sites/admin/functions.html`: its list
entries add `id`, `parent` (function tree), `state`/`activate`/`deactivate`
(each an array of REST calls against `tbl_navigationroute` and
`tbl_systemconfiguration`) and optionally `collections` — tables the function
needs, created on first activation by `js/admin/functions.js`. Its `desc`
records the historical ID ranges (100–199 object functions, 200–299 object
map, 300–399 data, 400–499 datamap, 500–599 labeling, 600–699 media).

## 3. Table catalogue

Types are PostgreSQL type strings as written in the JSONs. "Reference" is the
`refCollection`/`refAttribute` pair SmartData converts into a `FOREIGN KEY`.

### 3.1 SmartMonitoringFrontend — base schema

From `data/admin/presets/base.json` (three presets: *Base tables*,
*Navigationsmenü*, *Admin Funktionsverwaltung*).

#### `tbl_ootype` — observed-object types

| Attribute | Type | Constraints |
| --- | --- | --- |
| `id` | bigserial | identity, auto-increment, NOT NULL |
| `name` | varchar(255) | |
| `description` | varchar(255) | |
| `icon` | varchar(255) | |
| `flattendsets` | bool | |

#### `tbl_metatype` — measurement types (metadata)

| Attribute | Type | Constraints |
| --- | --- | --- |
| `id` | bigserial | identity, auto-increment, NOT NULL |
| `name` | varchar(255) | |
| `description` | varchar(255) | |
| `icon` | varchar(255) | |
| `type` | varchar(45) | |
| `unit` | varchar(45) | |
| `possiblevalues` | varchar(255) | |
| `isidentity` | boolean | |
| `isnullable` | boolean | |
| `isautoincrement` | boolean | |
| `refcollection` | varchar | |
| `refattribute` | varchar | |
| `refstorage` | varchar | |
| `refondelete` | varchar | |
| `refonupdate` | varchar | |
| `ootype_id` | int8 | |
| `editable` | bool | |

#### `tbl_datatype` — dataset types (metadata)

Same layout as `tbl_metatype` minus `editable`:

| Attribute | Type | Constraints |
| --- | --- | --- |
| `id` | bigserial | identity, auto-increment, NOT NULL |
| `name` | varchar(255) | |
| `description` | varchar(255) | |
| `icon` | varchar(255) | |
| `type` | varchar(45) | |
| `unit` | varchar(45) | |
| `possiblevalues` | varchar(255) | |
| `isidentity` | boolean | |
| `isnullable` | boolean | |
| `isautoincrement` | boolean | |
| `refcollection` | varchar | |
| `refattribute` | varchar | |
| `refstorage` | varchar | |
| `refondelete` | varchar | |
| `refonupdate` | varchar | |
| `ootype_id` | int8 | |

#### `tbl_observedobject` — devices / objects being monitored

| Attribute | Type | Constraints |
| --- | --- | --- |
| `id` | bigserial | identity, auto-increment, NOT NULL |
| `name` | varchar(255) | |
| `description` | varchar(255) | |
| `mac` | varchar(64) | |
| `ip` | varchar(64) | |
| `icon` | varchar(255) | |
| `manualcapture` | boolean | |
| `datacapture` | boolean | |
| `data_collection` | varchar(64) | name of the table holding this object's data |
| `measurerate` | int4 | |
| `meta_collection` | varchar(64) | |
| `ootype_id` | int8 | → `tbl_ootype.id` |
| `parent_id` | int8 | → `tbl_observedobject.id` (object hierarchy) |

#### `tbl_location` — locations (needs PostGIS)

| Attribute | Type | Constraints |
| --- | --- | --- |
| `id` | bigserial | identity, auto-increment, NOT NULL |
| `name` | varchar(255) | |
| `description` | varchar(255) | |
| `street` | varchar(64) | |
| `houseno` | varchar(64) | |
| `postcode` | varchar(10) | |
| `city` | varchar(64) | |
| `country` | varchar(64) | |
| `floor` | varchar(64) | |
| `apartment` | varchar(64) | |
| `room` | varchar(64) | |
| `coordinates` | geometry(PointZ,4326) | why the database needs PostGIS |
| `parent_id` | int8 | → `tbl_location.id` (location hierarchy) |

#### `tbl_location_join_oo` — object ↔ location assignment over time

| Attribute | Type | Constraints |
| --- | --- | --- |
| `id` | bigserial | identity, auto-increment, NOT NULL |
| `valid_from` | timestamp | |
| `valid_until` | timestamp | |
| `loc_id` | int8 | → `tbl_location.id` |
| `oo_id` | int8 | → `tbl_observedobject.id` |

#### `tbl_navigationroute` — front-end menu (seeded, 51 rows)

| Attribute | Type | Constraints |
| --- | --- | --- |
| `id` | bigserial | identity, auto-increment, NOT NULL |
| `name` | varchar(255) | menu entry key, e.g. `menu_object_list` |
| `icon` | varchar(255) | |
| `rfrom` | varchar(255) | route source (`*` = everywhere) |
| `rto` | varchar(255) | route target, relative page path |
| `parent` | int8 | → parent menu entry id |
| `active` | bool | |

#### `tbl_systemconfiguration` — feature switches (seeded, 51 rows)

| Attribute | Type | Constraints |
| --- | --- | --- |
| `id` | bigserial | identity, auto-increment, NOT NULL |
| `ckey` | varchar(255) | feature name, e.g. `func_userlogin` |
| `ctype` | varchar(255) | |
| `cvalue` | varchar(255) | |
| `active` | bool | |

### 3.2 SmartMonitoringFrontend — function-owned tables

From `data/admin/functions/functions.json`: 69 function entries, of which 10
own tables (13 tables in total). These tables are **not** created
by `base.json`; `js/admin/functions.js` creates them (`POST /collection/{name}`)
the first time the owning function is activated on
`sites/admin/functions.html`.

| Table | Owning function (id) | Purpose |
| --- | --- | --- |
| `schemes` | `func_object_scheme` (104) | named object scheme diagrams |
| `schemes_visuals` | `func_object_scheme` (104) | visual parts placed in a scheme |
| `tbl_datasource` | `func_data_manage_sources` (406) | data source registry (contact/licence/API metadata) |
| `tbl_datasource_join_oo` | `func_data_manage_sources` (406) | data source ↔ observed object |
| `datapipelines` | `func_datapipelines` (407) | input→worker→output object pipelines |
| `label_labels` | `func_labeling` (901) | label catalogue |
| `label_observedobject` | `func_labeling_object` (902) | label ↔ observed object |
| `label_datasets` | `func_labeling_data` (903) | label ↔ dataset |
| `label_media` | `func_labeling_media` (904) | label ↔ media (with polygons) |
| `media` | `func_media_galery` (1001) | media files |
| `media_reference` | `func_media_references` (1003) | media ↔ media references |
| `dashboard_cards` | `func_userdashboard` (1102) | dashboard card catalogue |
| `dashboard_cards_usersettings` | `func_userdashboard` (1102) | per-user card settings |

Attribute details (generated — regenerate with §6, do not hand-edit):

#### `schemes`

| Attribute | Type | Constraints |
| --- | --- | --- |
| `id` | bigserial | identity, auto-increment, NOT NULL |
| `name` | varchar | NOT NULL |

#### `schemes_visuals`

| Attribute | Type | Constraints | Reference |
| --- | --- | --- | --- |
| `id` | bigserial | identity, auto-increment, NOT NULL | |
| `schemes_id` | bigint | NOT NULL | → `schemes.id` (CASCADE/CASCADE) |
| `observedobject_id` | bigint | NOT NULL | → `tbl_observedobject.id` (CASCADE/CASCADE) |
| `name` | varchar | NOT NULL | |
| `x` | int | NOT NULL | |
| `y` | int | NOT NULL | |
| `width` | int | | |
| `height` | int | | |
| `parent_id` | bigint | | → `schemes_visuals.id` (CASCADE/CASCADE) |
| `image` | varchar | | |
| `fillcolor` | varchar | | |
| `bordercolor` | varchar | | |
| `desc` | varchar | | |
| `type` | varchar | | |
| `kind` | varchar | | |
| `linecalc` | varchar | | |
| `part1` | bigint | | → `schemes_visuals.id` (CASCADE/CASCADE) |
| `part2` | bigint | | → `schemes_visuals.id` (CASCADE/CASCADE) |
| `strokecolor` | varchar | | |
| `storkewidth` | int | | (typo is in the original) |
| `stroketension` | int | | |

#### `tbl_datasource`

| Attribute | Type | Constraints |
| --- | --- | --- |
| `id` | bigserial | identity, auto-increment, NOT NULL |
| `name` | varchar | NOT NULL |
| `description` | varchar | |
| `contact_name` | varchar | |
| `contact_email` | varchar | |
| `contact_url` | varchar | |
| `contact_telephone` | varchar | |
| `responsible_name` | varchar | |
| `responsible_url` | varchar | |
| `data_actual_api` | varchar | |
| `data_actual_url` | varchar | |
| `data_actual_interval_sec` | int4 | |
| `data_actual_import_ts` | timestamp | |
| `data_actual_img_url` | varchar | |
| `data_hist_api` | varchar | |
| `data_hist_url` | varchar | |
| `data_hist_interval_sec` | int4 | |
| `data_hist_import_ts` | timestamp | |
| `data_hist_img_url` | varchar | |
| `data_license` | varchar | |
| `data_license_url` | varchar | |
| `icon` | varchar | |
| `citation` | varchar | |
| `data_actual_api_guide` | text | |
| `data_actual_url_guide` | text | |
| `data_hist_api_guide` | text | |
| `data_hist_url_guide` | text | |
| `data_class` | varchar | |

#### `tbl_datasource_join_oo`

| Attribute | Type | Constraints | Reference |
| --- | --- | --- | --- |
| `id` | bigserial | identity, auto-increment, NOT NULL | |
| `datasource_id` | bigint | NOT NULL | → `tbl_datasource.id` (CASCADE/CASCADE) |
| `oo_id` | bigint | NOT NULL | → `tbl_observedobject.id` (CASCADE/CASCADE) |

#### `datapipelines`

| Attribute | Type | Constraints | Reference |
| --- | --- | --- | --- |
| `id` | bigserial | identity, auto-increment, NOT NULL | |
| `name` | varchar | NOT NULL | |
| `desc` | varchar | NOT NULL | |
| `input_ooid` | bigint | NOT NULL | → `tbl_observedobject.id` (CASCADE/CASCADE) |
| `input_filter` | varchar | NOT NULL | |
| `worker_ooid` | bigint | NOT NULL | → `tbl_observedobject.id` (CASCADE/CASCADE) |
| `worker_confset` | bigint | NOT NULL | |
| `output_ooid` | bigint | NOT NULL | → `tbl_observedobject.id` (CASCADE/CASCADE) |

#### `label_labels`

| Attribute | Type | Constraints |
| --- | --- | --- |
| `id` | bigserial | identity, auto-increment, NOT NULL |
| `name` | varchar | NOT NULL |
| `parent_id` | int8 | |
| `icon` | varchar | |
| `color` | varchar | |
| `description` | varchar | |
| `link_title` | varchar | |
| `link_url` | varchar | |
| `isavailforobjects` | boolean | |
| `isavailfordatasets` | boolean | |
| `isavailformediasets` | boolean | |

#### `label_observedobject`

| Attribute | Type | Constraints | Reference |
| --- | --- | --- | --- |
| `id` | bigserial | identity, auto-increment, NOT NULL | |
| `label_id` | bigint | NOT NULL | → `label_labels.id` |
| `oo_id` | bigint | NOT NULL | → `tbl_observedobject.id` |

#### `label_datasets`

| Attribute | Type | Constraints | Reference |
| --- | --- | --- | --- |
| `id` | bigserial | identity, auto-increment, NOT NULL | |
| `label_id` | bigint | NOT NULL | → `label_labels.id` |
| `collection` | varchar | NOT NULL | |
| `set_id` | bigint | NOT NULL | |

#### `label_media`

| Attribute | Type | Constraints | Reference |
| --- | --- | --- | --- |
| `id` | bigserial | identity, auto-increment, NOT NULL | |
| `label_id` | bigint | NOT NULL | → `label_labels.id` |
| `collection` | varchar | NOT NULL | |
| `set_id` | bigint | NOT NULL | |
| `polygons` | varchar | NOT NULL | |
| `title` | varchar | NOT NULL | |
| `description` | varchar | | |

#### `media`

| Attribute | Type | Constraints |
| --- | --- | --- |
| `id` | bigserial | identity, auto-increment, NOT NULL |
| `ts` | timestamp | NOT NULL |
| `name` | varchar | NOT NULL |
| `description` | text | |
| `path` | varchar | NOT NULL |
| `size` | int4 | |
| `mimetype` | varchar | |
| `oo_id` | int8 | |

#### `media_reference`

| Attribute | Type | Constraints |
| --- | --- | --- |
| `id` | bigserial | identity, auto-increment, NOT NULL |
| `media_id1` | bigint | NOT NULL |
| `collection1` | integer | NOT NULL |
| `media_id2` | bigint | NOT NULL |
| `collection2` | integer | NOT NULL |
| `description` | string | (type `string` is not valid PostgreSQL — see §7) |

#### `dashboard_cards`

| Attribute | Type | Constraints |
| --- | --- | --- |
| `id` | bigserial | identity, auto-increment, NOT NULL |
| `title` | varchar | NOT NULL |
| `desc` | varchar | |
| `type` | varchar | |
| `ecocard` | boolean | NOT NULL |
| `avail` | boolean | NOT NULL |
| `card_visible_default` | boolean | NOT NULL |
| `data_source` | varchar | |
| `data_ts_col` | varchar | |
| `data_from_selectable` | boolean | |
| `data_from_default` | timestamp | |
| `data_until_selectable` | boolean | |
| `data_until_default` | timestamp | |
| `data_comp` | varchar | |
| `data_comp_opts` | varchar | |
| `data_comp_tpl` | varchar | |
| `content` | varchar | |
| `data_from_min` | timestamp | |
| `data_until_max` | timestamp | |

#### `dashboard_cards_usersettings`

| Attribute | Type | Constraints |
| --- | --- | --- |
| `id` | bigserial | identity, auto-increment, NOT NULL |
| `card_id` | integer | NOT NULL |
| `user_id` | integer | NOT NULL |
| `next_card` | integer | |
| `prev_card` | integer | |
| `visible` | boolean | NOT NULL |
| `data_from` | timestamp | |
| `data_until` | timestamp | |

### 3.3 SmartDataJobs / SmartUser — datajobs schema

From `SmartDataJobs/web/data/admin/presets/base.json` (two presets: *SmartData
Base tables*, *SmartDataJobs Airquality*). SmartUser ships an older copy of
the same file (§7). Installed through each application's
`sites/admin/setup.html`, targeting the `smartmonitoring` storage.

#### `datajobs` — job definitions (seeded with 16 example jobs)

| Attribute | Type | Constraints |
| --- | --- | --- |
| `id` | bigserial | identity, auto-increment, NOT NULL |
| `name` | varchar(255) | |
| `desc` | varchar(255) | |
| `action` | varchar(255) | action class name, see below |
| `active` | bool | |
| `start` | timestamp | |
| `stop` | timestamp | |
| `repeatsecs` | int4 | repetition interval in seconds |
| `priority` | int4 | |

`action` values are resolved by `ActionFactory` against the classes in
`SmartDataJobs/src/java/de/smartdata/jobs/actions/` (class name minus
`Action`): `CommandExecution`, `ReadData`, `WriteData`, `DeleteData`,
`CheckNet`, `CheckEventTriggers`, `CreateFlagFile`, `Mail`, `SendNotification`.

#### `datajobs_log` — job results (consumed by the Airquality job chain)

| Attribute | Type | Constraints |
| --- | --- | --- |
| `id` | bigserial | identity, auto-increment, NOT NULL |
| `datajob_id` | int8 | NOT NULL, → `datajobs.id` |
| `result` | text | |
| `ts` | timestamp | NOT NULL, default `now()` |
| `iserror` | bool | |
| `wastimeout` | bool | |
| `processed` | bool | |

#### `datajobs_params` — job parameters (seeded with 51 rows)

| Attribute | Type | Constraints |
| --- | --- | --- |
| `id` | bigserial | identity, auto-increment, NOT NULL |
| `key` | varchar(255) | NOT NULL |
| `value` | text | NOT NULL |
| `datajob_id` | int8 | NOT NULL, → `datajobs.id` |
| `type` | varchar(255) | NOT NULL |

#### `datajobs_chain` — job chaining rules (seeded with 4 rows)

| Attribute | Type | Constraints |
| --- | --- | --- |
| `id` | bigserial | identity, auto-increment, NOT NULL |
| `pre_job_id` | int8 | NOT NULL, → `datajobs.id` |
| `post_job_id` | int8 | NOT NULL, → `datajobs.id` |
| `checkkey` | varchar(255) | |
| `checkvalue` | varchar(255) | |
| `checkchanged` | varchar(255) | |
| `active` | bool | |

#### `datajobs_join_oo` — job ↔ observed object assignment

Links a job to the `tbl_observedobject` it belongs to (e.g. a sensor-reading
job and the device it reads). Defined in the *SmartDataJobs Base tables*
preset; the equivalent SQL for the provided server is
`DBChanges/CreateDatajobsJoinOo.sql` (§5). Not yet consumed by backend or
frontend code — the link is data, to be edited through the SmartData API.

| Attribute | Type | Constraints | Reference |
| --- | --- | --- | --- |
| `id` | bigserial | identity, auto-increment, NOT NULL | |
| `datajob_id` | int8 | NOT NULL | → `datajobs.id` (CASCADE/CASCADE) |
| `oo_id` | int8 | NOT NULL | → `tbl_observedobject.id` (CASCADE/CASCADE) |

#### `sensordata` — airquality sensor readings (Airquality preset)

| Attribute | Type | Constraints |
| --- | --- | --- |
| `id` | bigserial | identity, auto-increment, NOT NULL |
| `ts` | timestamptz | NOT NULL, default `now()` |
| `temp1` | float8 | |
| `temp2` | float8 | |
| `temp3` | float8 | |
| `pm2_5` | float8 | |
| `pm10_0` | float8 | |
| `pos` | geometry | |
| `pos_accuracy` | float8 | |
| `pos_altitude` | float8 | |
| `pos_altitude_accuracy` | float8 | |
| `pos_heading` | float8 | |
| `pos_speed` | float8 | |
| `inn_temp` | float8 | |
| `inn_pres` | float8 | |
| `inn_hum` | float8 | |
| `co2` | float8 | |
| `measurement_process` | timestamp | (SmartDataJobs file; `varchar` in the SmartUser copy) |
| `measurement_name` | varchar(30) | (only in the SmartDataJobs file) |
| `synced` | bool | NOT NULL |

#### `label_timed` — timed labels (Airquality preset, only in SmartDataJobs file)

| Attribute | Type | Constraints |
| --- | --- | --- |
| `id` | bigserial | identity, auto-increment, NOT NULL |
| `ts` | timestamptz | NOT NULL, default `now()` |
| `label` | int4 | NOT NULL |

### 3.4 SmartMonitoringFrontend — legacy presets

`data/admin/presets/legacy/` holds 10 device-type presets (Dunkelkennlinie,
EnvironHomeDeviceTypes, EnvironNeighborComparison, FeelingsDeviceType,
Hellkennlinie, LaborDunkelkennlinien, LaborHellkennlinien, PVModulDatenblatt,
PVPMHellkennlinien, PVServeDunkelkennlinien) from a former application
version. Per its own `readme.md`: *"None of this files was tested."* Nothing
in the stack references them; they document the old
`tbl_observedobject_type`/`tbl_measurement_type` model. Distinct tables
defined across the 10 folders (97 JSON files, 3510 seed rows):

| Table | Folders | Purpose |
| --- | --- | --- |
| `tbl_observedobject_type` | 10 | object types (old model, note the spelled `flatendsets`) |
| `tbl_measurement_type` | 10 | measurement types |
| `tbl_ootype_join_mtype` | 10 | object type ↔ measurement type |
| `tbl_observedobject_metadata_type` | 3 | metadata types |
| `tbl_ootype_join_oometadatatype` | 3 | object type ↔ metadata type |
| `tbl_tag_type` | 5 | tag types |
| `tbl_importerrule` | 5 | import rules |
| `tbl_value_definition` | 2 | value definitions |

All use `int8` ids with
`default nextval('smartmonitoring.<table>_id_seq'::regclass)` and the same
attribute pattern (`name` NOT NULL, `description` nullable). The file
`legacy/Hellkennlinie/tbl_observedobject_type _records.json` (with a space)
is a stray duplicate of `tbl_observedobject_type_records.json` in the same
folder.

### 3.5 SmartUser — JPA schema (not JSON)

For completeness: SmartUser's `smartuser` schema (database `smartuser`) is
created by Hibernate from the JPA entities
(`SmartUser/src/java/de/fhbielefeld/smartuser/persistence/jpa/`,
`hibernate.hbm2ddl.auto=update`), not from any JSON:

| Table | Entity | Key columns |
| --- | --- | --- |
| `users` | `User` | `id`, `username` (unique, NOT NULL), `password`, `authtoken`, name/address/email fields, `lastlogin` |
| `groups` | `Group` | `id`, `name` NOT NULL, `creationdate`, `description` |
| `groupusers` | `GroupUser` | `id`, `group_id` NOT NULL → `groups`, `user_id` NOT NULL → `users`, `membersince`, `status` |
| `resources` | `Resource` | `id`, `path` |
| `userrights` | `UserRight` | `id`, `user` → `users`, `resource` → `resources`, `action` |
| `accessfail` | `AccessFail` | `id`, `resource`, `action`, `user` → `users` |

On the provided server `smartuser.groups` is missing (no `CREATE` grant —
see AGENTS.md §10.6).

## 4. Seed data

| File | Preset | Table | Rows | Content |
| --- | --- | --- | --- | --- |
| SMF `base.json` | Navigationsmenü | `tbl_navigationroute` | 51 | menu tree, ids 100–9103 (`menu_object` … `menu_about_system`), mostly `active:true` |
| SMF `base.json` | Admin Funktionsverwaltung | `tbl_systemconfiguration` | 51 | feature switches keyed by `ckey` (`func_object_list` … `func_userfavs`), all `active:false`; **contains a duplicate id 1003** (§7) |
| SDJ `base.json` | SmartDataJobs Airquality | `datajobs` | 16 | example jobs (`getBME280Data`, `writeSensorData`, …), all `active:false` |
| SDJ `base.json` | SmartDataJobs Airquality | `datajobs_chain` | 4 | job chaining rules |
| SDJ `base.json` | SmartDataJobs Airquality | `datajobs_params` | 51 | job parameters (commands, URLs, the Airquality JSON-mapping config) |
| SMF `ootypes.json` | OpenWeatherMap | `tbl_datatype`, `tbl_ootype` (+ join rows) | 8 | one weather device type with its measurement types (old-model names; install broken, §7.9) |
| SMF `papendorf_pv.json` | PapendorfPVKennlinien | `tbl_observedobject_type`, `tbl_measurement_type`, `tbl_ootype_join_mtype` (513) | 517 | PV module characteristic curves; unreferenced and install broken (§7.9) |
| SMF `legacy/*/` | 10 folders | 8 tables | 3510 | old device type model, untested, unreferenced |

The `datajobs_params` seed includes the Airquality aggregation job's JSON
configuration (`mapping`, `datasources`), which encodes how
`datajobs_log.result` JSON is mapped into `sensordata` columns — effectively
part of the schema contract between the jobs and the monitoring front end.

## 5. How the JSONs reach the database

Nothing in the deployment applies these files automatically. They are
**admin-page tooling**: a person opens the setup page and clicks install.

```text
SmartMonitoringFrontend /sites/admin/setup.html
    └─ SWAC PresetManager FROM data/admin/presets/base.json
        └─ targetSource: /SmartData/smartdata/[iface]/[fromName]?storage=smartmonitoring
SmartDataJobs /SmartUser /SmartData (web/sites/admin/setup.html)
    └─ Select FROM {app}/smartdatajobs/system/apps WHERE filter=type,eq,SmartData
        └─ PresetManager FROM web/data/admin/presets/base.json
            └─ targetSource: /SmartData/smartdata/[iface]/[fromName]?storage=smartmonitoring
SmartMonitoringFrontend /sites/admin/objecttypes.html
    └─ PresetManager FROM data/admin/presets/ootypes.json
SmartMonitoringFrontend /sites/admin/functions.html
    └─ Present FROM data/admin/functions/functions.json
        └─ js/admin/functions.js creates `collections` on activation
```

Interface mapping (same in every `configuration.js` that has a SmartData
source): `defs` → `GET collection`, `cdefs` → `POST collection`, `create` →
`POST records`, `update` → `PUT records`, `delete` → `DELETE records`.

On the provided server the base schema (`tbl_*`, `datajobs*`, `sensordata`,
`label_timed`, `media`, `label_labels`, `schemes*`, `tbl_datasource*`,
`datapipelines`, `exampledata_*`, `view_oo_hierarchy`) is already
provisioned; AGENTS.md §11 notes that `storage/create?name=smartmonitoring`
returns non-201 for the existing schema.

Two SQL files complement the JSONs (not applied automatically either):

- `SmartMonitoringFrontend/docs/setup/view_oo_hierarchy.sql` — recursive view
  over `tbl_observedobject`, used by `sites/object/list.html`. Present on the
  provided server.
- `DBChanges/CreateJobsNav.sql` (this repo) — one `INSERT` adding menu entry
  2000 `menu_jobs` → `datajobs/index.html` (the front end's `sites/datajobs/`
  pages). Already applied on the provided server; the JSON seed still says
  `jobs/index.html` (§7).

A third pairs with a JSON definition instead of standing alone:

- `DBChanges/CreateDatajobsJoinOo.sql` (this repo) — creates
  `smartmonitoring.datajobs_join_oo` (§3.3), the SQL counterpart of the
  `datajobs_join_oo` collection in `SmartDataJobs/web/data/admin/presets/base.json`.
  Both produce the same schema: the constraint names in the SQL follow
  SmartData's generator naming (`<table>_<refCollection>_<refAttribute>_<column>`),
  verified against the live `datajobs_chain`/`datajobs_params` constraints.
  Applied to the provided server on 2026-11-17 as `webengineering_group`,
  after the schema owner granted `CREATE` on the schema and `REFERENCES`
  on the parent tables (previously the deployment role had neither —
  AGENTS.md §10.6). With those grants the admin-page preset install works
  on a fresh database as well.

## 6. Keeping this document in sync

The attribute tables were generated from the JSONs with:

```bash
python3 scripts/gen_schema_doc.py
```

It prints the catalogue sections (§3.1–3.4 tables with types, constraints and
references) to stdout. After changing any preset JSON, run it and paste the
affected sections back here. The script reads the submodules read-only; it
never writes.

## 7. Drift between files and the live database

Verified against the provided server (`storage=smartmonitoring`, via
`GET /SmartData/smartdata/collection/{name}` and `/records/{name}`):

1. **`tbl_systemconfiguration` seed has a duplicate id 1003** in
   `SmartMonitoringFrontend/data/admin/presets/base.json`: both
   `func_media_references` and `func_userfavs` use it, and no row 1103 exists.
   `functions.json` expects `func_userfavs` at id **1103** (its
   state/activate/deactivate calls filter on `id,eq,1103`). The live server
   has 1103/`func_userfavs` — i.e. the server was provisioned from a fixed
   variant. Re-running the seed against a fresh database would violate the
   primary key or lose `func_userfavs`. Upstream fix needed in
   `SmartMonitoringFrontend`.
2. **Menu entry 2000**: seed says `rto: jobs/index.html`, live server and
   `DBChanges/CreateJobsNav.sql` say `datajobs/index.html` (the existing
   `sites/datajobs/` folder). The JSON is stale.
3. **SmartUser's `base.json` is an outdated copy** of SmartDataJobs': older
   version tag (06.02.26 vs 06.03.26), `measurement_process` typed `varchar`
   instead of `timestamp`, no `measurement_name` column, no `label_timed`
   table, and `datajobs` seed rows differ (job 7 has `start`/`repeatsecs`
   values). SmartUser has no reason to ship these tables at all — its own
   schema is JPA (§3.5).
4. **`media_reference` uses type `string`**, which is not a PostgreSQL type;
   SmartData passes types through verbatim, so activating
   `func_media_references` on a fresh database fails. The live server does
   not have the table.
5. **Live-only objects with no JSON definition**: `exampledata_timeseries`,
   `exampledata_timeseries_1week`, `exampledata_geotimeseries`,
   `exampledata_geotimeseries_1week`, `exampledata_pictures`,
   `exampledata_rasterdata` (referenced only via
   `tbl_observedobject.data_collection` rows on the server), the view
   `view_oo_hierarchy` (SQL file in `SmartMonitoringFrontend/docs/setup/`,
   used by `sites/object/list.html`) and its companion
   `view_oo_without_locations` (SQL file exists, view not installed on the
   server). None of the repositories contains a JSON defining the
   `exampledata_*` tables.
6. **`sensordata` is defined in the SmartDataJobs preset but does not exist
   on the live server** — the Airquality preset was never installed there
   (all 16 seeded `datajobs` are `active:false` and `datajobs_log` is empty).
   `label_timed` however *does* exist on the server, although only the
   SmartDataJobs file defines it (and the SmartUser copy lacks it).
7. **`tbl_observedobject` live has extra columns** the JSON does not define:
   `isworker`, `data_hasgeopos`, `completed`, `ordnungs_zahl`,
   `measuredaylystart`, `measuredaylyend` — the server was provisioned from
   a newer/other variant of the schema. Conversely the live table lacks
   nothing from the JSON.
8. **`datajobs_log.ts` default `now()`** is in the JSON but not in the live
   table (no default) — harmless, but a fresh install would differ from the
   provided server.
9. **`ootypes.json` and `papendorf_pv.json` cannot install** with the current
   SWAC `PresetManager`: their `data` entries use `method: "POST"`/`"post"`,
   which is not a key of the interfaces map (`get`, `list`, `defs`, `cdefs`,
   `create`, `update`, `delete`) — the component shows an *interfaceerr* and
   aborts. The `papendorf_pv.json` data entries additionally lack `fromName`
   (its `state` entries carry a `url` field the PresetManager ignores), so
   even a matching method would build a broken URL. Both files are
   effectively dead data; their row bodies also target the legacy model
   (`tbl_observedobject_type`, `tbl_measurement_type`), not the current
   `tbl_ootype`/`tbl_metatype`/`tbl_datatype` tables.

Consequences for operators:

- The provided server is the effective source of truth for
  `smartmonitoring`; the JSONs are a partial, partly stale description.
  Treat differences as "server wins" unless intentionally re-provisioning.
- A fresh database provisioned *only* from the JSONs would be missing the
  `exampledata_*` tables, `view_oo_hierarchy`, the extra
  `tbl_observedobject` columns, and would break on the duplicate id 1003 and
  the `string` type.
- **`datajobs_join_oo`** was added to the JSON and applied to the live
  server on 2026-11-17 via `DBChanges/CreateDatajobsJoinOo.sql` (run as
  `webengineering_group`, after the schema owner granted `CREATE` on schema
  `smartmonitoring` and `REFERENCES` on `datajobs`/
  `tbl_observedobject`). The table exists on both sides now; it is not yet
  consumed by backend or frontend code. The SmartUser copy of `base.json`
  does not contain it (§7.3).
