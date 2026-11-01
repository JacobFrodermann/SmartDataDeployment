# SmartDataDeployment

Docker Compose deployment of the **Smart\*** stack: SmartDataJobs, SmartUser,
SmartData and SWAC, running together on Payara 6 with PostgreSQL.

This repository contains no application code. It coordinates the applications,
which live in their own repositories and are consumed as artifact images:

| Component | Repository | Image |
| --- | --- | --- |
| SmartDataJobs | `SmartDataJobs` | `smartdatajobs-war:local` |
| SmartUser | `SmartUser` | `smartuser-war:local` |
| SmartData | `SmartData` | `smartdata-war:local` |
| SWAC | `SWAC` | `swac-war:local` |
| SmartMonitoring | `SmartMonitoringFrontend` | `smartmonitoringfrontend-war:local` |

## Quick start

Prerequisites:

- Docker (with Compose v2)

The five application repositories are git submodules of this repository:

```bash
git clone git@github.com:JacobFrodermann/SmartDataDeployment.git
cd SmartDataDeployment
git submodule update --init --recursive   # or ./scripts/submodules.sh
```

The stack runs against a **provided PostgreSQL server** (`frodermann.me`); the
connection is hardcoded in `compose.yaml`, only the password is read from `.env`.
Its database is provisioned already (users, `smartmonitoring` schema, presets),
so there is nothing to bootstrap and no database container in the stack:

```bash
./scripts/up.sh                 # builds all five artifact images, the Payara image, starts the stack
```

Then open:

- SmartDataJobs: <http://localhost:8080/SmartDataJobs/>
- SmartMonitoring: <http://localhost:8080/SmartMonitoringFrontend/>
- SmartUser: <http://localhost:8080/SmartUser/>
- SmartData: <http://localhost:8080/SmartData/>
- SWAC: <http://localhost:8080/SWAC/>
- API overview (Swagger UI for all three REST applications):
  <http://localhost:8099/>
- Payara admin console: <http://localhost:4848> (`admin` / `admin`)

Default logins on the provided server: `admin` / `admin` and `AppUser` /
`SmartPassword1298!`.

## What the stack does

- `smartdatajobs` runs Payara with all five applications auto-deployed from
  `/opt/payara/deployments`, connected to the provided PostgreSQL server:
  `jdbc/SmartUser` -> db `smartuser` (schema `smartuser`), `jdbc/SmartData` ->
  db `smartmonitoring_test` (schema `smartmonitoring`).
- Before deployment, `docker/payara/init_0_configure_databases.sh` creates the
  JTA data sources `jdbc/SmartUser` and `jdbc/SmartData`.
- `docker/payara/*_config.properties` are placed in `/opt/payara/`, where the
  applications read them as `<module-name>_config.properties`.
- Compose healthchecking requires all five applications to be deployed, so a
  missing artifact image shows up as `unhealthy`.
- `api-overview` serves a read-only Swagger UI for the OpenAPI document Payara
  generates at `/openapi`, and proxies the applications so that "Try it out"
  stays same-origin. It has no database access and no effect on the stack.

Only the master Payara image is rebuilt by Compose. After changing an
application, rebuild its artifact image first:

```bash
docker build -t smartuser-war:local SmartUser
docker compose up --build -d
```

## Configuration

The database connection (host, port, database names, user, `sslmode=require`) is
hardcoded in `compose.yaml` on purpose: the target must not be redirected by a
stray environment variable. Only `SMARTUSER_DB_PASSWORD` is read from `.env`
(use single quotes — Compose interpolates `$VAR` inside double quotes). Port
overrides are documented in `.env.example`.

## Documentation

`AGENTS.md` documents the architecture in detail: the integration contracts
between the components (context roots, JNDI names, configuration files, schema
ownership), the Payara startup sequence, known pitfalls and a verification
checklist. Read it before changing anything here.
