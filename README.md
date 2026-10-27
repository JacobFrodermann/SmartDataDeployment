# SmartDataDeployment

Docker Compose deployment of the **Smart\*** stack: SmartDataJobs, SmartUser,
SmartData, SWAC, SmartMonitoringFrontend and the SWACdoc documentation site,
running together on Payara 6 with PostgreSQL.

This repository contains no application code. It coordinates the applications,
which live in their own repositories:

| Component | Repository | How it runs |
| --- | --- | --- |
| SmartDataJobs | `SmartDataJobs` | Deployed WAR (`smartdatajobs-war:local`) |
| SmartUser | `SmartUser` | Deployed WAR (`smartuser-war:local`) |
| SmartData | `SmartData` | Deployed WAR (`smartdata-war:local`) |
| SWAC | `SWAC` | Docroot mount (source → Payara docroot) |
| SWACdoc | `SWACdoc` | Docroot mount (source → Payara docroot) |
| SmartMonitoring | `SmartMonitoringFrontend` | Docroot mount (source → Payara docroot) |

## Quick start

Prerequisites:

- Docker (with Compose v2)

The five application repositories and `SWACdoc` are git submodules of this
repository:

```bash
git clone git@github.com:JacobFrodermann/SmartDataDeployment.git
cd SmartDataDeployment
git submodule update --init --recursive   # or ./scripts/submodules.sh
```

```bash
./scripts/up.sh                 # builds the three Java WARs, the Payara image, starts the stack
./scripts/init-smartuser.sh     # once, on a fresh database
./scripts/init-smartmonitoring.sh   # once: creates the smartmonitoring storage, tables and seed data
```

Then open:

- SmartDataJobs: <http://localhost:8080/SmartDataJobs/>
- SmartMonitoring: <http://localhost:8080/SmartMonitoringFrontend/>
- SmartUser: <http://localhost:8080/SmartUser/>
- SmartData: <http://localhost:8080/SmartData/>
- SWAC: <http://localhost:8080/SWAC/>
- SWAC documentation: <http://localhost:8080/SWACdoc/>
- Payara admin console: <http://localhost:4848> (`admin` / `admin`)

Default logins after the bootstrap: `admin` / `admin` and `AppUser` /
`SmartPassword1298!`.

## What the stack does

- `smartuser-db` runs PostGIS 16 (PostgreSQL 16 + PostGIS 3.4) and creates the
  `smartuser` schema on first start. PostGIS is required by the monitoring
  front end's `tbl_location.coordinates` geometry column.
- `smartdatajobs` runs Payara with three applications deployed as WARs:
  SmartDataJobs, SmartUser and SmartData.
- SWAC, SWACdoc and SmartMonitoringFrontend are **not** WARs. Their source
  directories are bind-mounted into Payara's domain docroot, so Payara's default
  servlet serves them as static files at `/SWAC/`, `/SWACdoc/` and
  `/SmartMonitoringFrontend/`. Editing a file in any of them is immediately
  visible on reload — no rebuild or restart needed.
- Before deployment, `docker/payara/init_0_configure_databases.sh` creates the
  JTA data sources `jdbc/SmartUser` and `jdbc/SmartData`.
- `docker/payara/init_1_configure_mimetypes.sh` adds the MIME type mappings
  Payara lacks (`woff`, `woff2`, `webmanifest`) server-wide, so the static
  files served from the docroot have correct content types.
- `docker/payara/*_config.properties` are placed in `/opt/payara/`, where the
  applications read them as `<module-name>_config.properties`.
- `init-smartmonitoring.sh` creates the SmartData storage `smartmonitoring` and
  applies the presets shipped by the front end (tables, menu, feature
  switches), so the monitoring UI has data on a fresh database.

Only the master Payara image is rebuilt by Compose. After changing a Java
application, rebuild its artifact image first:

```bash
docker build -t smartuser-war:local SmartUser
docker compose up --build -d
```

## Configuration

Copy `.env.example` to `.env` to change ports or database credentials. The
Compose project name is part of the database volume name, so changing it
starts an empty database.

## Documentation

- [AGENTS.md](AGENTS.md) — full integration contract, architecture, known
  pitfalls and maintenance tasks.
