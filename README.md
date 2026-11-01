# SmartDataDeployment

Docker Compose deployment of the **Smart\*** stack: SmartDataJobs, SmartUser,
SmartData, SWAC, SmartMonitoring and the SWAC documentation, running together
on Payara 6 with PostgreSQL.

This repository contains no application code. It coordinates the applications,
which live in their own repositories. The three Java applications are consumed
as artifact images; the static projects are mounted into Payara's docroot:

| Component | Repository | How it runs |
| --- | --- | --- |
| SmartDataJobs | `SmartDataJobs` | Deployed WAR (`smartdatajobs-war:local`) |
| SmartUser | `SmartUser` | Deployed WAR (`smartuser-war:local`) |
| SmartData | `SmartData` | Deployed WAR (`smartdata-war:local`) |
| SWAC | `SWAC` | Docroot mount (source -> Payara docroot) |
| SWACdoc | `SWACdoc` | Docroot mount (source -> Payara docroot) |
| SmartMonitoring | `SmartMonitoringFrontend` | Docroot mount (source -> Payara docroot) |

## Quick start

Prerequisites:

- Docker (with Compose v2)

The five application repositories and the `SWACdoc` documentation site are git
submodules of this repository:

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
./scripts/up.sh                 # builds the three Java WARs, the Payara image, starts the stack
```

Then open:

- SmartDataJobs: <http://localhost:8080/SmartDataJobs/>
- SmartMonitoring: <http://localhost:8080/SmartMonitoringFrontend/>
- SmartUser: <http://localhost:8080/SmartUser/>
- SmartData: <http://localhost:8080/SmartData/>
- SWAC: <http://localhost:8080/SWAC/>
- SWAC documentation: <http://localhost:8080/SWACdoc/>
- API overview (Swagger UI for all three REST applications):
  <http://localhost:8099/>
- Payara admin console: <http://localhost:4848> (`admin` / `admin`)

Default logins on the provided server: `admin` / `admin` and `AppUser` /
`SmartPassword1298!`.

## What the stack does

- `smartdatajobs` runs Payara with the three Java applications auto-deployed
  from `/opt/payara/deployments`, connected to the provided PostgreSQL server:
  `jdbc/SmartUser` -> db `smartuser` (schema `smartuser`), `jdbc/SmartData` ->
  db `smartmonitoring_test` (schema `smartmonitoring`).
- SWAC, SWACdoc and SmartMonitoringFrontend are **not** WARs. Their source
  directories are bind-mounted into Payara's domain docroot, so the default
  servlet serves them as static files at `/SWAC/`, `/SWACdoc/` and
  `/SmartMonitoringFrontend/`. Editing a file there is live on reload — no
  rebuild, no restart.
- Before deployment, `docker/payara/init_0_configure_databases.sh` creates the
  JTA data sources `jdbc/SmartUser` and `jdbc/SmartData`, and
  `docker/payara/init_1_configure_mimetypes.sh` adds the MIME types the static
  projects need (`woff`, `woff2`, `webmanifest`, `manifest`, `wasm`)
  server-wide, because their `WEB-INF/web.xml` is no longer deployed.
- `docker/payara/*_config.properties` are placed in `/opt/payara/`, where the
  applications read them as `<module-name>_config.properties`.
- Compose healthchecking requires the three Java applications to be deployed and
  the three docroot mounts to be present, so a missing artifact image or a
  missing mount shows up as `unhealthy`.
- `api-overview` serves a read-only Swagger UI for the OpenAPI document Payara
  generates at `/openapi`, and proxies the applications so that "Try it out"
  stays same-origin. It has no database access and no effect on the stack.

Only the master Payara image is rebuilt by Compose. After changing a Java
application, rebuild its artifact image first:

```bash
docker build -t smartuser-war:local SmartUser
docker compose up --build -d
```

Changes inside `SWAC/`, `SWACdoc/` or `SmartMonitoringFrontend/` need neither:
the directories are mounted, so a browser reload is enough. Two caches can still
serve something stale: Payara keeps an already served static file for a few
seconds, and the SmartMonitoring front end caches itself in a service worker
(clear the site data if it serves old assets).

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
