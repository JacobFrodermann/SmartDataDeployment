# SmartDataDeployment

Docker Compose deployment of the **Smart\*** stack: SmartDataJobs, SmartUser,
SmartData and SWAC, running together on Payara 6 with PostgreSQL.

This repository contains no application code. It coordinates the applications,
which live in their own repositories and are consumed as artifact images:

| Component | Repository | Image |
| --- | --- | --- |
| SmartDataJobs | `../SmartDataJobs` | `smartdatajobs-war:local` |
| SmartUser | `../SmartUser` | `smartuser-war:local` |
| SmartData | `../SmartData` | `smartdata-war:local` |
| SWAC | `../SWAC` | `swac-war:local` |
| SmartMonitoring | `../SmartMonitoringFrontend` | `smartmonitoringfrontend-war:local` |

## Quick start

Prerequisites:

- Docker (with Compose v2)
- Sibling checkouts of `SmartDataJobs`, `SmartUser`, `SmartData`, `SWAC` and
  `SmartMonitoringFrontend` next to this repository

```bash
./scripts/up.sh                 # builds all five artifact images, the Payara image, starts the stack
./scripts/init-smartuser.sh     # once, on a fresh database
./scripts/init-smartmonitoring.sh   # once: creates the smartmonitoring storage, tables and seed data
```

Then open:

- SmartDataJobs: <http://localhost:8080/SmartDataJobs/>
- SmartMonitoring: <http://localhost:8080/SmartMonitoringFrontend/>
- SmartUser: <http://localhost:8080/SmartUser/>
- SmartData: <http://localhost:8080/SmartData/>
- SWAC: <http://localhost:8080/SWAC/>
- Payara admin console: <http://localhost:4848> (`admin` / `admin`)

Default logins after the bootstrap: `admin` / `admin` and `AppUser` /
`SmartPassword1298!`.

## What the stack does

- `smartuser-db` runs PostGIS 16 (PostgreSQL 16 + PostGIS 3.4) and creates the
  `smartuser` schema on first start. PostGIS is required by the monitoring
  front end's `tbl_location.coordinates` geometry column.
- `smartdatajobs` runs Payara with all five applications auto-deployed from
  `/opt/payara/deployments`.
- Before deployment, `docker/payara/init_0_configure_databases.sh` creates the
  JTA data sources `jdbc/SmartUser` and `jdbc/SmartData`.
- `docker/payara/*_config.properties` are placed in `/opt/payara/`, where the
  applications read them as `<module-name>_config.properties`.
- `init-smartmonitoring.sh` creates the SmartData storage `smartmonitoring` and
  applies the presets shipped by the front end (tables, menu, feature
  switches), so the monitoring UI has data on a fresh database.
- Compose healthchecking requires all five applications to be deployed, so a
  missing artifact image shows up as `unhealthy`.

Only the master Payara image is rebuilt by Compose. After changing an
application, rebuild its artifact image first:

```bash
docker build -t smartuser-war:local ../SmartUser
docker compose up --build -d
```

## Configuration

Copy `.env.example` to `.env` to change ports or database credentials. The
Compose project name is part of the database volume name, so changing it
starts an empty database.

## Documentation

`AGENTS.md` documents the architecture in detail: the integration contracts
between the components (context roots, JNDI names, configuration files, schema
ownership), the Payara startup sequence, known pitfalls and a verification
checklist. Read it before changing anything here.
