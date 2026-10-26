# AGENTS.md

Deployment and integration notes for the **Smart\*** stack: `SmartDataJobs`,
`SmartUser`, `SmartData` and `SWAC`.

This repository owns everything that ties the four applications together: the
Docker Compose deployment, the master Payara image, the Payara startup
configuration, the JDBC resource setup, the database bootstrap and the operator
scripts. The applications themselves live in their own repositories and are
consumed here as **artifact images**.

Read this file before changing `compose.yaml`, `Dockerfile.payara`, `docker/`
or `scripts/`. Application-internal decisions (Maven layout, CDI, persistence
units, NetBeans history) are documented in the `AGENTS.md` of the respective
repository.

---

## 1. Repositories and scope

Six repositories are involved: this deployment repository plus the five
applications. The applications are **git submodules** of this repository, not
Maven modules of one reactor.

| Submodule path | Upstream / fork | Purpose |
| --- | --- | --- |
| — (this repository) | `SmartEnviroSystem/SmartDataDeployment` | Compose stack, master Payara image, JDBC/config/bootstrap, scripts |
| `SmartDataJobs` | `SmartEnviroSystem` → `JacobFrodermann` | Jobs REST application and its admin front end |
| `SmartUser` | `SmartEnviroSystem` → `JacobFrodermann` | User management REST application, JPA user store |
| `SmartData` | `SmartEnviroSystem` → `JacobFrodermann` | TreeQL database access REST API (tables, records, storages) |
| `SWAC` | `SmartEnviroSystem` → `JacobFrodermann` | SmartWebApplicationComponents, static JavaScript UI library |
| `SmartMonitoringFrontend` | `SmartEnviroSystem` → `JacobFrodermann` | SmartMonitoring web front end (static JavaScript application) |

### Cloning

```bash
git clone git@github.com:JacobFrodermann/SmartDataDeployment.git
cd SmartDataDeployment
git submodule update --init --recursive     # or ./scripts/submodules.sh
```

### Submodule URLs and remotes

`.gitmodules` records the **fork** URL
(`git@github.com:JacobFrodermann/<name>.git`) for every submodule. That is
mandatory: the commits pinned as gitlinks in this repository exist only in the
forks, not upstream, so fetching from `SmartEnviroSystem` would fail.

Consequence for a fresh clone: each submodule has `origin` = fork, which is
what `git submodule update` uses and where pushes go. `scripts/submodules.sh`
adds the upstream repository as the second remote (`upstream`), so both
repositories are reachable:

```text
origin    -> git@github.com:JacobFrodermann/<name>.git   (fetch + push)
upstream  -> git@github.com:SmartEnviroSystem/<name>.git (pull, PR base)
```

Checking out this repository where the submodules already existed keeps their
original remotes (`origin` = `SmartEnviroSystem`, `fork` =
`JacobFrodermann`). Both layouts work; do not “fix“ them with a blind
`git submodule sync`, which rewrites `origin`.

Rules that follow from this split:

- **No application source in this repository.** The submodules are pinned
  commits; do not copy WARs, POMs, Java sources or front-end assets into the top
  level or vendor them. This repository only orchestrates.
- **No deployment files in the application repositories.** Each application
  repository keeps exactly one `Dockerfile` (its artifact image, built from its
  own sources) and a `.dockerignore`. Compose files, the master Payara image,
  `*_config.properties`, the JDBC init script, the PostgreSQL init SQL and the
  operator scripts live here.
- **Commit in the submodule first, then bump the gitlink here.** A change inside
  `SmartDataJobs/` is invisible to this repository until its commit is pushed
  to the fork and the new gitlink is committed here (`git add SmartDataJobs`).
- The submodule paths are configurable, so another directory layout works:
  `SMARTDATAJOBS_DIR`, `SMARTUSER_DIR`, `SMARTDATA_DIR`, `SWAC_DIR`,
  `SMARTMONITORINGFRONTEND_DIR` (see §9). Defaults are the submodule paths.
- `.dockerignore` excludes all submodule directories. The master Payara build
  context must never contain the application trees.

---

## 2. Runtime architecture

```text
PostGIS 16 (PostgreSQL 16 + PostGIS 3.4, database smartuser)
    |
    | jdbc/SmartUser  -> schema smartuser   (Hibernate/JPA, SmartUser tables)
    | jdbc/SmartData  -> schemas public, smartmonitoring (JDBC, TreeQL tables;
    |                    tbl_location.coordinates is geometry(PointZ,4326))
    v
Payara Server 6.2025.11 (Java 17, Jakarta EE 10)
    |
    +-- /SmartDataJobs   -> SmartDataJobs.war
    |       REST base:   /SmartDataJobs/smartdatajobs
    |
    +-- /SmartUser       -> SmartUser.war
    |       REST base:   /SmartUser/smartuser
    |
    +-- /SmartData       -> SmartData.war
    |       REST base:   /SmartData/smartdata
    |
    +-- /SWAC           -> SWAC.war
    |       static JavaScript UI library (no server-side code)
    |
    +-- /SmartMonitoringFrontend -> SmartMonitoringFrontend.war
            monitoring front end; reads /SmartData?storage=smartmonitoring,
            logs in against /SmartUser, loads /SWAC
```

URLs of a default deployment:

- SmartDataJobs UI: `http://localhost:8080/SmartDataJobs/`
- SmartDataJobs REST info: `http://localhost:8080/SmartDataJobs/smartdatajobs/system/info`
- SmartUser UI: `http://localhost:8080/SmartUser/`
- SmartUser REST info: `http://localhost:8080/SmartUser/smartuser/system/info`
- SmartData UI: `http://localhost:8080/SmartData/`
- SmartData REST info: `http://localhost:8080/SmartData/smartdata/system/info`
- SWAC: `http://localhost:8080/SWAC/` (library entry point `…/SWAC/swac/swac.js`)
- SmartMonitoring front end: `http://localhost:8080/SmartMonitoringFrontend/`
- Payara admin: `http://localhost:4848` with the image defaults `admin` / `admin`

The context root comes from the WAR file name, which is also the Payara
application name (`SmartDataJobs`, `SmartUser`, `SmartData`, `SWAC`,
`SmartMonitoringFrontend`). The second URL segment of the Java applications
comes from the JAX-RS `@ApplicationPath` values inside them (`smartdatajobs`,
`smartuser`, `smartdata`).

---

## 3. Integration contract

This section is the reason this repository exists: it records what each
application expects from its environment and what the other components assume
about it. Changing one of these values in one place without changing it in the
others breaks the stack.

| # | Contract | Producer | Consumer | Failure if broken |
| --- | --- | --- | --- | --- |
| 1 | Artifact image tag (`*-war:local`) and WAR path `/opt/wars/<Name>.war` | application `Dockerfile` | `Dockerfile.payara` | image not found / empty `COPY` |
| 2 | WAR file name = context root = Payara application name | application `pom.xml` `finalName` | URLs, healthcheck, other apps | 404, or container stays `unhealthy` |
| 3 | JNDI name `jdbc/SmartUser` | `docker/payara/init_0_configure_databases.sh` | SmartUser `persistence.xml` | `databaseConnectivity:false`, login 500 |
| 4 | JNDI name `jdbc/SmartData` | same script | SmartData `postgres.jndi` default | `storage/getCollections` fails |
| 5 | PostgreSQL schema `smartuser` | `docker/postgres/init-smartuser.sql` | SmartUser JPA entities | Hibernate cannot create tables |
| 6 | Storages `public`, `smartmonitoring` (PostgreSQL schemas) | `scripts/init-smartmonitoring.sh` (creates + seeds `smartmonitoring`) | monitoring front end | empty menus, no login form, 404 responses |
| 6b | PostGIS (`geometry(PointZ,4326)`) | `postgis/postgis:16-3.4-alpine` image, `docker/postgres/init-smartuser.sql`, `init-smartmonitoring.sh` | `tbl_location.coordinates` | table creation fails, no locations/map |
| 7 | File `/opt/payara/<module-name>_config.properties` | `docker/payara/*_config.properties` | each application's `Configuration` loader | 412/500 on many endpoints, `propsloaded:false` |
| 8 | Context root `/SWAC` | SWAC WAR name + `glassfish-web.xml` | SmartDataJobs pages, SWAC components, SmartMonitoring front end | broken front end (absolute paths) |
| 9 | Shared PostgreSQL server, separate schemas | `compose.yaml` | SmartUser + SmartData | table clashes if schemas are mixed |
| 10 | `DEPLOY_PROPS=--force=true` | `compose.yaml` | Payara auto-deploy | restart logs "already registered" |
| 11 | Context root `/SmartMonitoringFrontend` | SmartMonitoringFrontend WAR name + its `glassfish-web.xml` | its own `configuration.js` data source `/SmartMonitoringFrontend/data/[fromName]` | data sources 404, no static JSON |
| 12 | Storage name `smartmonitoring` | hardcoded in the front end's `configuration.js` | `scripts/init-smartmonitoring.sh`, SmartData | front end reads an empty/absent schema |
| 13 | Absolute URLs `/SWAC`, `/SmartData/smartdata`, `/SmartUser/smartuser` | the four WARs above | SmartMonitoring front end | blank page, failing login, no data |

### 3.1 SmartDataJobs

- Artifact image: `smartdatajobs-war:local`, WAR at `/opt/wars/SmartDataJobs.war`.
- Context root `/SmartDataJobs`, REST base `/SmartDataJobs/smartdatajobs`.
- Config file `SmartDataJobs_config.properties`; all values optional.
- Does not use a database directly. It talks to SmartUser (login, user rights)
  and SmartData (data access) over HTTP and loads SWAC as a JavaScript library
  from the absolute path `/SWAC/swac/swac.js`.
- Front end therefore depends on contracts 2 (SmartDataJobs), 4/6 (SmartData)
  and 8 (SWAC) at the same time.

### 3.2 SmartUser

- Artifact image: `smartuser-war:local`, WAR at `/opt/wars/SmartUser.war`.
- Context root `/SmartUser`, REST base `/SmartUser/smartuser`.
- JPA persistence unit `SmartUserPU` on `jdbc/SmartUser`, schema `smartuser`,
  `hibernate.hbm2ddl.auto=update`.
- `beans.xml` uses `bean-discovery-mode="all"`, which is **required**: without
  CDI the `@PersistenceContext`/`@Resource` injections stay `null` and login
  and user management fail.
- Config file `SmartUser_config.properties`; `passwordsalt`,
  `authtokensalt`, `serviceorder` and `confirm_mail` are effectively mandatory
  (see §7).
- Bootstrap: a fresh database has no users. `scripts/init-smartuser.sh` calls
  `GET /SmartUser/smartuser/system/setup` exactly once.
- SmartDataJobs and SmartData authenticate against it; it is the only
  component that writes the `smartuser` schema.

### 3.3 SmartData

- Artifact image: `smartdata-war:local`, WAR at `/opt/wars/SmartData.war`.
- Context root `/SmartData`, REST base `/SmartData/smartdata`.
- Plain JDBC over `jdbc/SmartData`, no JPA. `mongo.url` would switch the whole
  storage layer to MongoDB; the deployment does **not** set it.
- A *storage* is a PostgreSQL schema: `public` is the default,
  `smartmonitoring` is what the monitoring front end uses. Schemas are created
  through `POST /SmartData/smartdata/storage/create?name=<name>`, so the
  database user must be allowed to create schemas.
- Shares the database with SmartUser by default (`SMARTDATA_DB_NAME` defaults
  to `SMARTUSER_DB_NAME`). Do not point SmartData at the `smartuser` schema.
- Authentication against SmartUser (`@SmartUserAuth`) is **not** active: the
  shipped config sets neither `smartuser.url`/`smartuser.apptoken` nor
  `smartuser.db_uri`/`smartuser.db_user`/`smartuser.db_pwd`, so SmartData
  endpoints are publicly accessible.

### 3.4 SWAC

- Artifact image: `swac-war:local`, WAR at `/opt/wars/SWAC.war`.
- No build step: the SWAC repository is a NetBeans HTML5 client project whose
  `Dockerfile` zips `index.html`, `swac/` and `docker/WEB-INF` into a static
  WAR.
- Deployed as a static WAR below `/SWAC`. That path is absolute in the
  consumers, e.g. `swac/components/Devhelper/sideboard.html` references
  `/SWAC/swac/components/Icon/imgs/error.svg` and SmartDataJobs pages load
  `/SWAC/swac/swac.js`. Renaming the WAR or changing the context root breaks
  the front end.
- `docker/WEB-INF/web.xml` (SWAC repo) adds MIME mappings for `svg`, `woff`,
  `woff2`, `json` and `wasm`; Payara's default table lacks `woff2`, which
  yields `application/octet-stream` and broken fonts.
- `configuration.js` is **not** part of SWAC. SWAC loads
  `<app_root>/configuration.js` from the embedding application, so pages under
  `/SmartDataJobs/` use `SmartDataJobs/web/configuration.js`.
- Licensing: most of SWAC is LGPL, but 13 directories below
  `swac/components/` carry their own `LICENSE.md` marking them proprietary
  ("not for redistribution or modification without permission"), e.g.
  `Booking`, `Communicator`, `Mediaplayer`, `Texteditor`, `Questions`. Pushing
  an image that contains them to a registry counts as redistribution. If that
  becomes a problem, exclude those directories in the SWAC `Dockerfile`; do not
  patch the files.

### 3.5 SmartMonitoringFrontend

- Artifact image: `smartmonitoringfrontend-war:local`, WAR at
  `/opt/wars/SmartMonitoringFrontend.war`.
- No build step: a NetBeans HTML5 client project whose `Dockerfile` zips the
  document root plus `docker/WEB-INF` into a static WAR.
- Context root **`/SmartMonitoringFrontend`** is part of the contract: its
  `configuration.js` declares the data source
  `/SmartMonitoringFrontend/data/[fromName]`, and it loads `/SWAC/...`,
  `/SmartData/...` and `/SmartUser/...` absolutely.
- All data comes from SmartData, storage (= PostgreSQL schema)
  `smartmonitoring` (hardcoded in `configuration.js`).
- The schema alone is not enough: the tables and the seed rows are the presets
  shipped in `data/admin/presets/base.json` and are applied by
  `scripts/init-smartmonitoring.sh` (§9). Without `tbl_systemconfiguration`
  (rows `func_userlogin`, `func_userfavs`) the login form and favourites stay
  inactive; without `tbl_observedobject` the device list is empty.
- `tbl_location.coordinates` is a `geometry(PointZ,4326)` column, so the
  database must provide PostGIS: the Compose service uses
  `postgis/postgis:16-3.4-alpine` and `init-smartmonitoring.sh` enables the
  extension (`CREATE EXTENSION IF NOT EXISTS postgis`) before creating tables.
  With plain PostgreSQL the `tbl_location` creation fails.
- `docker/WEB-INF/web.xml` adds `woff2`, `webmanifest`/`manifest`, `svg`,
  `woff`, `json`, `wasm` and `ico` MIME mappings; `glassfish-web.xml` pins the
  context root.
- Packaged without `test files/` and `docs/` (see its `.dockerignore`).
- PWA: `serviceworker.js` caches the app, so browsers may serve stale assets
  after a redeploy; clear the worker/site data or bump the cache version.
- Redirect options (`afterLoginLoc`, `afterLogoutLoc`, `loggedinRedirects`,
  `accountURL`) must be absolute application paths. SWAC joins them with the
  context root (`app_root` = `/SmartMonitoringFrontend`, no trailing slash), so
  a relative value produces `/SmartMonitoringFrontendsites/...`. See
  `SmartMonitoringFrontend/AGENTS.md`.
- `js/ai-config.js` targets `/SmartData/smartdata/proxy/ai`, which SmartData
  does not implement (only `proxy/get`); those features are inert.

---

## 4. Artifact images

Every application repository builds **one** artifact image. Its only job is to
carry a single deployable WAR:

```text
/opt/wars/<Name>.war
```

```bash
docker build -t smartdatajobs-war:local SmartDataJobs
docker build -t smartuser-war:local     SmartUser
docker build -t smartdata-war:local     SmartData
docker build -t swac-war:local          SWAC
docker build -t smartmonitoringfrontend-war:local SmartMonitoringFrontend
```

Properties of these images:

- They never run Payara; they end in an `alpine` stage that only copies the
  WAR.
- Java projects build the WAR inside Docker with Maven. The Smart\* helper jars
  come from the project-local Maven repository (each application's
  `libs/maven-repo`), so no sibling checkout is needed for the Maven build.
- SWAC has no compilation stage; it is zipped.
- The SmartMonitoring front end has no compilation stage either; it is zipped
  from its document root (without `test files/` and `docs/`).
- `target/` is excluded by each repository's `.dockerignore`, so the WAR is
  never taken from the host.

Consequence for this repository: `Dockerfile.payara` **cannot** build the
applications and must not try to. It references the artifact images by tag.
Compose cannot rebuild them either — `compose up --build` only rebuilds the
master image. `scripts/up.sh` builds all artifact images first, and every
component change requires rebuilding its artifact image (§10.2).

---

## 5. Master Payara image

`Dockerfile.payara` builds the runnable container:

1. `FROM ${SMARTDATAJOBS_IMAGE} AS smartdatajobs-war` (default
   `smartdatajobs-war:local`).
2. `FROM ${SMARTUSER_IMAGE} AS smartuser-war` (default `smartuser-war:local`).
3. `FROM ${SMARTDATA_IMAGE} AS smartdata-war` (default `smartdata-war:local`).
4. `FROM ${SWAC_IMAGE} AS swac-war` (default `swac-war:local`).
5. `FROM ${SMARTMONITORINGFRONTEND_IMAGE} AS smartmonitoringfrontend-war`
   (default `smartmonitoringfrontend-war:local`).
6. Maven stage downloads the PostgreSQL JDBC driver
   (`org.postgresql:postgresql:42.7.4`).
7. `FROM payara/server-full:6.2025.11-jdk17`.
8. Copies the driver into
   `/opt/payara/appserver/glassfish/domains/domain1/lib/`.
9. Copies `docker/payara/init_0_configure_databases.sh` to
   `/opt/payara/scripts/`.
10. Copies the three `*_config.properties` into `/opt/payara/`.
11. Copies the five WARs into `/opt/payara/deployments`.
12. Switches back to the `payara` runtime user.

Important details:

- The Payara base image runs as user `payara`. `USER root` is only used for the
  `chmod` of the init script; `USER payara` restores the runtime user.
- The build uses the classic Docker builder on the current machine, so avoid
  BuildKit-only features such as `COPY --chmod`.
- The build context is this repository only (`.dockerignore` drops `.git`,
  `scripts`, `.env` and Markdown), so a build never touches application
  sources.
- `SMARTDATAJOBS_IMAGE`, `SMARTUSER_IMAGE`, `SMARTDATA_IMAGE`, `SWAC_IMAGE` and
  `SMARTMONITORINGFRONTEND_IMAGE` are build args, so Compose (or a CI job) can
  point at other tags/registries without editing the Dockerfile.

---

## 6. Payara startup and JDBC resources

Payara auto-deploys everything in `/opt/payara/deployments`.
`init_0_configure_databases.sh` runs before
`init_1_generate_deploy_commands.sh` and appends one pool/resource pair per
application to `$POSTBOOT_COMMANDS`:

```text
create-jdbc-connection-pool ... SmartUserPool
create-jdbc-resource --connectionpoolid SmartUserPool jdbc/SmartUser
create-jdbc-connection-pool ... SmartDataPool
create-jdbc-resource --connectionpoolid SmartDataPool jdbc/SmartData
```

Payara then appends its automatic deploy commands, so both resources exist
before the applications are deployed.

Implementation notes — keep them when editing the script:

- The script is **sourced** by the Payara entrypoint. Use `return 0`, not
  `exit 0`, when skipping work.
- It **truncates `$POSTBOOT_COMMANDS` first**. That file lives in the container
  filesystem and survives a restart, while `init_1_generate_deploy_commands.sh`
  only appends. Without truncation the resource commands of the previous start
  are replayed and log `A resource named SmartUserPool already exists`.
- It checks `domain.xml` for `jdbc/SmartUser` and `jdbc/SmartData` separately,
  so resources are only added when they are really missing.
- JDBC URLs contain colons, which must be escaped in the asadmin `--property`
  string:

```text
url=jdbc\:postgresql\://host\:5432/database
```

- Database connection values come from:

```text
SMARTUSER_DB_HOST
SMARTUSER_DB_PORT
SMARTUSER_DB_NAME
SMARTUSER_DB_USER
SMARTUSER_DB_PASSWORD
SMARTDATA_DB_NAME      default: value of SMARTUSER_DB_NAME
```

- SmartData shares the PostgreSQL server and, by default, the database with
  SmartUser. Different schemas (`smartuser` vs `public`/`smartmonitoring`)
  mean no extra database or volume is needed.

---

## 7. Configuration properties

Each application looks for a configuration file in the Payara working
directory, named `<module-name>_config.properties`:

```text
/opt/payara/SmartDataJobs_config.properties
/opt/payara/SmartUser_config.properties
/opt/payara/SmartData_config.properties
```

All three are shipped by `Dockerfile.payara` from
`docker/payara/*_config.properties`. They exist because without them the
applications log a load error and several endpoints fail:

- SmartUser builds no Usermanager without `passwordsalt` and `authtokensalt`
  (HTTP 412 on `user/list`, `user/performLogin`, …), throws a
  `NullPointerException` without `serviceorder` (HTTP 500), and dereferences
  `confirm_mail` without a null check in `UsermanagerLocal.createUser()`
  (HTTP 500 on user creation). The shipped file therefore sets
  `serviceorder=local` and `confirm_mail=false`. Set `confirm_mail=true` only
  together with the `email_smtp_*` settings.
- SmartData falls back to `jdbc/SmartData` + PostgreSQL when `postgres.jndi`
  is absent. Setting `mongo.url` switches it to MongoDB, and
  `smartuser.url` + `smartuser.apptoken` (or `smartuser.db_uri`,
  `smartuser.db_user`, `smartuser.db_pwd`) activates authentication against
  SmartUser for `@SmartUserAuth` endpoints. Authentication is **not**
  activated in the current setup.
- SmartDataJobs works without any value; the file only exists so that
  `propsloaded` is true.

Verify with:

```bash
curl -s http://localhost:8080/SmartUser/smartuser/system/config
curl -s http://localhost:8080/SmartData/smartdata/system/config
curl -s http://localhost:8080/SmartDataJobs/smartdatajobs/system/config
```

All three must report `"propsloaded":true`.

The salts in `SmartUser_config.properties` are development defaults. Changing
them invalidates all stored password hashes and auth tokens.

---

## 8. Compose deployment

`compose.yaml` contains two services:

- `smartuser-db`: `postgis/postgis:16-3.4-alpine` (PostgreSQL 16 + PostGIS, the
  latter is needed for `tbl_location.coordinates`), persistent volume
  `smartuser-db-data`, the init SQL from `docker/postgres/init-smartuser.sql`,
  `pg_isready` healthcheck.
- `smartdatajobs`: master Payara image, `depends_on` the database being
  healthy, exposes `8080` (HTTP) and `4848` (admin).

Project name and volume:

- `name: ${COMPOSE_PROJECT_NAME:-smartdatajobs}`. The project name is part of
  the volume name (`smartdatajobs_smartuser-db-data`), so changing it creates a
  **new empty database** and orphans the old data. Only change it together with
  a migration.
- Container names are pinned (`smartuser-db`, `smartdatajobs`), so the
  commands in §11 are stable.

Compose healthcheck:

```yaml
apps=$(asadmin ... list-applications); echo "$apps" | grep -q SmartDataJobs
  && echo "$apps" | grep -qw SmartData
  && echo "$apps" | grep -q SmartUser
  && echo "$apps" | grep -q SWAC
  && echo "$apps" | grep -q SmartMonitoringFrontend
```

All five applications must be listed, so a missing or broken artifact image
makes the container report `unhealthy` instead of silently serving a broken
front end. `grep -qw SmartData` is used because `SmartData` is a prefix of
`SmartDataJobs`.

`DEPLOY_PROPS=--force=true` is required. Without it, a Payara restart replays
the generated deploy commands against the persisted domain and logs:

```text
Application with name SmartUser is already registered
```

Environment variables:

```text
COMPOSE_PROJECT_NAME             default smartdatajobs
SMARTDATAJOBS_HTTP_PORT          default 8080
SMARTDATAJOBS_ADMIN_PORT         default 4848
SMARTUSER_DB_NAME                default smartuser
SMARTUSER_DB_USER                default smartuser
SMARTUSER_DB_PASSWORD            default smartuser
SMARTDATA_DB_NAME                default value of SMARTUSER_DB_NAME
```

Copy `.env.example` to `.env` to change them persistently.

PostgreSQL init scripts only run when the data volume is first initialized. If
an old volume exists without the `smartuser` schema, reset it with
`docker compose down -v`.

---

## 9. Scripts

### `scripts/up.sh`

1. Verifies that the five submodules are checked out (or that the `*_DIR`
   overrides point at existing checkouts).
2. Builds `smartuser-war:local`, `smartdata-war:local`, `swac-war:local`,
   `smartdatajobs-war:local` and `smartmonitoringfrontend-war:local`.
3. Runs `docker compose up --build -d` to build the master Payara image.
4. Reminds about the two bootstraps when the database is still empty, and
   prints the URLs.

Submodule paths are overridable:

```bash
SMARTUSER_DIR=SmartUser SMARTDATA_DIR=SmartData \
SWAC_DIR=SWAC SMARTDATAJOBS_DIR=SmartDataJobs \
SMARTMONITORINGFRONTEND_DIR=SmartMonitoringFrontend ./scripts/up.sh
```

### `scripts/submodules.sh`

Initialises/updates the five submodules and adds the upstream remote inside
each of them (`origin` is the fork from `.gitmodules`, see §1). It never
rewrites existing remotes; when an older checkout still has
`origin` = `SmartEnviroSystem` and a `fork` remote, it reports that instead.

### `scripts/init-smartuser.sh`

One-shot bootstrap for a fresh database, run **once** after the stack is
healthy:

- Fails with a hint if `smartuser.users` does not exist yet (stack not
  started).
- Exits successfully if users already exist.
- Otherwise calls `GET /SmartUser/smartuser/system/setup`, which creates the
  default users, resources and user rights, and prints the logins:
  `admin`/`admin` and `AppUser`/`SmartPassword1298!`.

The endpoint is one-shot; calling it twice returns HTTP 500 from a unique
constraint violation. That is why the script checks the table first.

### `scripts/init-smartmonitoring.sh`

Data bootstrap for the monitoring front end, run **once** after the stack is
healthy (and after `init-smartuser.sh`):

1. Waits until `/SmartData/smartdata/system/info` answers.
2. Creates the SmartData storage (= PostgreSQL schema) `smartmonitoring` if the
   schema is missing (`POST /SmartData/smartdata/storage/create?name=...`).
3. Reads the presets from the **running application**
   (`/SmartMonitoringFrontend/data/admin/presets/base.json`), so the schema
   always matches the deployed WAR, and applies them:
   - every `collections[]` entry with `cdefs` → `POST
     /SmartData/smartdata/collection/<name>?storage=smartmonitoring`
   - every `data[]` entry → per record `POST
     /SmartData/smartdata/records/<name>?storage=smartmonitoring`, after an
     existence check on the table's identity attribute

Tables: `tbl_ootype`, `tbl_metatype`, `tbl_datatype`, `tbl_observedobject`,
`tbl_location`, `tbl_location_join_oo`, `tbl_navigationroute` (50 menu rows),
`tbl_systemconfiguration` (50 feature rows such as `func_userlogin`,
`func_userfavs`).

The seed data ships 51 `tbl_systemconfiguration` records but only 50 distinct
ids (`id` 1003 appears twice in the preset file), so 50 rows are created. The
script inserts record by record instead of POSTing the whole array, so such a
duplicate cannot abort the seed and leave a half-filled table; existing rows
are recognised by the identity attribute and skipped.

Idempotent: existing tables are skipped via `to_regclass`, seed rows via an
existence check on the table's identity attribute, so it is safe to re-run.
Requirements: `curl`, `jq`, `docker compose` on the host, and a running stack
with the front end deployed (the preset file is served by the application).

Finally it activates the `func_userlogin` switch, because the start page gates
its login form on that row and every preset row ships with `active=false`.
That is a deliberate deployment decision for this stack; set
`SMARTMONITORING_ENABLE_USERLOGIN=false` to keep the shipped defaults and
activate features manually in `SmartMonitoringFrontend/sites/admin/functions.html`
(all other switches stay inactive either way).

`SMARTMONITORING_STORAGE` and `SMARTMONITORINGFRONTEND_CONTEXT` override the
defaults, but the storage name is also hardcoded in the front end's
`configuration.js` — changing it requires editing that file too.

---

## 10. Known pitfalls

### 10.1 `restart` and `compose --build` do not rebuild artifact images

`docker compose restart` only restarts the existing container.
`docker compose up --build` rebuilds the master Payara image but reuses the
existing `*-war:local` artifact images. A code change without rebuilding its
artifact image is silently ignored — the old WAR is copied again.

### 10.2 Rebuild matrix

| Changed | Commands |
| --- | --- |
| everything | `./scripts/up.sh` |
| `SmartDataJobs` | `docker build -t smartdatajobs-war:local SmartDataJobs && docker compose up --build -d` |
| `SmartUser` | `docker build -t smartuser-war:local SmartUser && docker compose up --build -d` |
| `SmartData` | `docker build -t smartdata-war:local SmartData && docker compose up --build -d` |
| `SWAC` | `docker build -t swac-war:local SWAC && docker compose up --build -d` |
| `SmartMonitoringFrontend` | `docker build -t smartmonitoringfrontend-war:local SmartMonitoringFrontend && docker compose up --build -d` |
| this repo (`compose.yaml`, `Dockerfile.payara`, `docker/`, `scripts/`) | `docker compose up --build -d` |

### 10.3 Payara admin password

The Payara image ships `/opt/payara/passwordFile` containing
`AS_ADMIN_PASSWORD=admin`. Setting only the `ADMIN_PASSWORD` environment
variable does not rewrite that file. The stack therefore uses the image
defaults (`admin`/`admin`). If the password is changed, update the password
file, otherwise `asadmin` healthchecks and administration commands fail.

### 10.4 Database volume initialization

`docker/postgres/init-smartuser.sql` (`CREATE SCHEMA IF NOT EXISTS smartuser
AUTHORIZATION CURRENT_USER;` plus `CREATE EXTENSION IF NOT EXISTS postgis;`)
runs only on the first initialization of the volume. Removing or editing it has
no effect on an existing volume. The bootstrap scripts cover that case
(`init-smartmonitoring.sh` enables PostGIS itself); for anything else reset the
volume (`docker compose down -v`).

A volume created with the old `postgres:16-alpine` image keeps working after
switching to `postgis/postgis:16-3.4-alpine` (same PostgreSQL major version);
the PostGIS extension files come from the image, not the data directory. Only
the extension itself has to be created once.

### 10.5 Two `Configuration` classes per application

`SmartUserAuth` and `NGI_RestUtils` contain classes whose names collide with
application classes (`de.fhbielefeld.smartuser.config.Configuration`,
`de.fhbielefeld.smartdata.config.Configuration`). The web class loader prefers
`WEB-INF/classes` over `WEB-INF/lib`, so the application's own class wins. This
is expected; do not "fix" it by changing the artifact image contents. See the
`AGENTS.md` of SmartUser and SmartData.

### 10.6 Missing artifact image looks like a broken deployment

If one artifact image is missing, `Dockerfile.payara` fails at the `FROM`
stage — or, when an old image is still present, the container deploys an older
WAR. Check `docker images | grep -- -war:local` first when behaviour disagrees
with the checkout.

### 10.7 Restarting the database container breaks pooled connections

After `smartuser-db` is recreated or restarted (for example because the image
changed from `postgres` to `postgis`), the Payara JTA pools still hold dead
connections. The first request that touches the database then fails with HTTP
500 and a `java.lang.reflect.UndeclaredThrowableException` at
`com.sun.gjc.spi.base.ConnectionHolder.getWarnings`, typically in
`performLogin`.

Fix: restart the application container after the database restarted:

```bash
docker compose restart smartdatajobs
```

`/SmartUser/smartuser/system/info` may still report
`"databaseConnectivity":true` in that state, because it opens a fresh
connection — the health endpoint is not a reliable indicator here.

---

## 11. Common maintenance tasks

### Start from scratch

```bash
./scripts/up.sh
./scripts/init-smartuser.sh          # only on a fresh database volume
./scripts/init-smartmonitoring.sh    # storage smartmonitoring, tables, menu
```

### Update a submodule / bump a gitlink

```bash
cd SmartDataJobs                   # the submodule
git fetch upstream && git merge upstream/master   # or commit locally
git push origin master             # origin = JacobFrodermann fork

cd ..                              # this repository
git add SmartDataJobs              # record the new commit
git commit -m "chore(submodules): bump SmartDataJobs"
```

The gitlink must point at a commit that exists in the fork, otherwise
`git submodule update` fails on a fresh clone (§1).

### Check deployment

```bash
docker compose ps
docker exec smartdatajobs asadmin --user=admin \
  --passwordfile=/opt/payara/passwordFile list-applications
docker exec smartdatajobs asadmin --user=admin \
  --passwordfile=/opt/payara/passwordFile list-jdbc-resources
```

Expected applications: `SWAC`, `SmartData`, `SmartDataJobs`, `SmartUser`.
Expected resources: `jdbc/SmartUser`, `jdbc/SmartData`.

### Check the database

```bash
docker exec smartuser-db psql -U smartuser -d smartuser -c '\dn'
docker exec smartuser-db psql -U smartuser -d smartuser -c '\dt smartuser.*'
docker exec smartuser-db psql -U smartuser -d smartuser -c '\dt smartmonitoring.*'
```

Expected schemas: `public`, `smartmonitoring`, `smartuser`.
Expected tables in `smartuser`: `accessfail`, `groups`, `groupusers`,
`resources`, `userrights`, `users`.

`smartmonitoring` is created and seeded by `scripts/init-smartmonitoring.sh`
(§9). After it ran, the schema contains `tbl_ootype`, `tbl_metatype`,
`tbl_datatype`, `tbl_observedobject`, `tbl_location`,
`tbl_location_join_oo`, `tbl_navigationroute` (50 rows) and
`tbl_systemconfiguration` (50 rows). Further `tbl_*` tables are created
through the SmartData API or the admin setup pages of the front ends.

The `public` schema stays empty unless something uses the default storage.
`storage/create?name=smartmonitoring` is idempotent in the script only — calling
the API directly for an existing schema does not return 201.

### Check the endpoints

```bash
for p in SmartDataJobs/ SmartDataJobs/smartdatajobs/system/info \
         SmartUser/ SmartUser/smartuser/system/info \
         SmartData/ SmartData/smartdata/system/info \
         SWAC/ SWAC/swac/swac.js \
         SmartMonitoringFrontend/ \
         SmartMonitoringFrontend/configuration.js \
         SmartMonitoringFrontend/data/admin/presets/base.json; do
    curl -s -o /dev/null -w "%{http_code} $p\n" "http://localhost:8080/$p"
done
```

All eleven must return 200.

```bash
# SmartData storage access through jdbc/SmartData
curl -s "http://localhost:8080/SmartData/smartdata/storage/getCollections?name=public"
# -> {"list":[]}

# a storage is a PostgreSQL schema
curl -s -X POST "http://localhost:8080/SmartData/smartdata/storage/create?name=smartmonitoring"
# -> HTTP 201 (scripts/init-smartmonitoring.sh does this only if missing)

# the front end's data source: tables + the feature switches it needs
curl -s "http://localhost:8080/SmartData/smartdata/records/tbl_systemconfiguration?storage=smartmonitoring&filter=ckey,eq,func_userlogin"
# -> one row with "active":true
curl -s "http://localhost:8080/SmartData/smartdata/records/tbl_navigationroute?storage=smartmonitoring&size=1"
# -> one menu row

# SmartUser CDI + JPA
curl -s http://localhost:8080/SmartUser/smartuser/system/info
# -> "databaseConnectivity":true

# login round trip
curl -s -c /tmp/cookies -X POST -H 'Content-Type: application/json' \
  -d '{"username":"admin","password":"admin"}' \
  http://localhost:8080/SmartUser/smartuser/user/performLogin
curl -s -b /tmp/cookies http://localhost:8080/SmartUser/smartuser/user       # 200
curl -s -o /dev/null -w '%{http_code}\n' http://localhost:8080/SmartUser/smartuser/user  # 401

# SWAC MIME types
curl -sI http://localhost:8080/SWAC/swac/libs/mathlive/fonts/KaTeX_AMS-Regular.woff2
# -> Content-Type: font/woff2
curl -sI http://localhost:8080/SWAC/swac/components/Icon/imgs/error.svg
# -> Content-Type: image/svg+xml
```

### Logs

```bash
docker compose logs -f smartdatajobs
docker compose logs -f smartuser-db
```

### Clean rebuild

```bash
docker build --no-cache -t smartuser-war:local     SmartUser
docker build --no-cache -t smartdata-war:local     SmartData
docker build --no-cache -t swac-war:local          SWAC
docker build --no-cache -t smartdatajobs-war:local SmartDataJobs
docker build --no-cache -t smartmonitoringfrontend-war:local SmartMonitoringFrontend
docker compose build --no-cache
docker compose up -d
```

### After the database container was recreated

```bash
docker compose restart smartdatajobs    # stale pooled connections (§10.7)
```

### Stop / reset

```bash
docker compose down          # stop, keep the database volume
docker compose down -v       # stop and drop the database (re-run init-smartuser.sh)
docker compose up -d
```

---

## 12. Verification checklist

- [ ] `docker build -t smartdatajobs-war:local SmartDataJobs` succeeds.
- [ ] `docker build -t smartuser-war:local SmartUser` succeeds.
- [ ] `docker build -t smartdata-war:local SmartData` succeeds.
- [ ] `docker build -t swac-war:local SWAC` succeeds.
- [ ] `docker build -t smartmonitoringfrontend-war:local SmartMonitoringFrontend`
      succeeds.
- [ ] `docker compose build` succeeds.
- [ ] `docker compose up -d` starts both services.
- [ ] `docker compose ps` reports both services healthy.
- [ ] `asadmin list-applications` lists all five applications.
- [ ] `asadmin list-jdbc-resources` lists `jdbc/SmartUser` and `jdbc/SmartData`.
- [ ] All eleven HTTP endpoints return 200, including `/SWAC/`,
      `/SWAC/swac/swac.js`, `/SmartMonitoringFrontend/` and its
      `configuration.js`.
- [ ] The three `*/system/config` endpoints report `"propsloaded":true`.
- [ ] `/SmartData/smartdata/storage/getCollections?name=public` returns
      `{"list":[]}`.
- [ ] `/SmartUser/smartuser/system/info` reports
      `"databaseConnectivity":true`.
- [ ] `./scripts/init-smartuser.sh` reports either "already initialised" or
      runs setup successfully.
- [ ] `./scripts/init-smartmonitoring.sh` creates the storage, the eight
      tables and the seed rows, and reports nothing to do when re-run.
- [ ] `tbl_systemconfiguration` has 50 rows and contains `func_userlogin` with
      `active=true`; `tbl_navigationroute` has 50 rows.
- [ ] `user/performLogin` with `admin`/`admin` returns 200 and an `authtoken`
      cookie; `/user` without the cookie returns 401.
- [ ] SWAC serves `woff2` as `font/woff2` and `svg` as `image/svg+xml`.
- [ ] `/SmartDataJobs/` and `/SmartData/` load `/SWAC/swac/swac.js` without 404.
- [ ] The `smartuser` schema contains the six expected tables.
- [ ] `docker compose restart smartdatajobs` becomes healthy again, logs no
      `Application with name ... is already registered` and no
      `A resource named ...Pool already exists`.

---

## 13. Key files

```text
.gitmodules                         # submodule paths + fork URLs (see §1)
compose.yaml                        # PostgreSQL + master Payara service
Dockerfile.payara                   # master Payara image (all five WARs)
.dockerignore                       # build context = this repo, submodules excluded
.env.example                        # documented environment variables
docker/payara/init_0_configure_databases.sh   # jdbc/SmartUser, jdbc/SmartData
docker/payara/SmartDataJobs_config.properties
docker/payara/SmartUser_config.properties     # salts, serviceorder, confirm_mail
docker/payara/SmartData_config.properties     # postgres.jndi / mongo / smartuser auth
docker/postgres/init-smartuser.sql  # creates schema smartuser (first init only)
scripts/submodules.sh               # submodule init/update + upstream remote
scripts/up.sh                       # build all artifact images + start stack
scripts/init-smartuser.sh           # one-shot GET system/setup
scripts/init-smartmonitoring.sh     # storage smartmonitoring + presets from the app
```

In the application repositories, this stack depends on:

```text
SmartDataJobs/Dockerfile   # -> /opt/wars/SmartDataJobs.war
SmartUser/Dockerfile       # -> /opt/wars/SmartUser.war
SmartData/Dockerfile       # -> /opt/wars/SmartData.war
SWAC/Dockerfile            # -> /opt/wars/SWAC.war
SWAC/docker/WEB-INF/       # web.xml (MIME types) + glassfish-web.xml (/SWAC)
SmartMonitoringFrontend/Dockerfile         # -> /opt/wars/SmartMonitoringFrontend.war
SmartMonitoringFrontend/docker/WEB-INF/    # MIME types + context root
SmartMonitoringFrontend/data/admin/presets/base.json   # schema + seed data
```

---

## 14. History

The Docker setup grew inside `SmartDataJobs`: the WAR artifact `Dockerfile`,
the master `Dockerfile.payara`, `compose.yaml`, the Payara init script, the
`*_config.properties` and the operator scripts all lived there next to the
application sources. That mixed two lifecycles — a single application release
and the deployment of four applications plus infrastructure.

The deployment concern was therefore extracted into this repository. The
application repositories keep exactly their own artifact `Dockerfile`; every
cross-component fact (context roots, JNDI names, config file names, schema
ownership, build order, startup ordering, healthcheck) lives here, in §3 and in
the sections that follow it.

The SmartMonitoring front end was added afterwards, and it is the first
component whose data does not come from a database it owns: it lives entirely
in SmartData's `smartmonitoring` storage. That is why the deployment grew a
second bootstrap script (`init-smartmonitoring.sh`), which derives the schema
and seed rows from the presets shipped by the deployed application instead of
duplicating them here.
