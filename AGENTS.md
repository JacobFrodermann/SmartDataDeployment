# AGENTS.md

Deployment and integration notes for the **Smart\*** stack: `SmartDataJobs`,
`SmartUser`, `SmartData`, `SWAC`, `SmartMonitoringFrontend` and the `SWACdoc`
documentation site.

This repository owns everything that ties the five applications and the
`SWACdoc` documentation site together: the Docker Compose deployment, the master
Payara image, the Payara startup configuration, the JDBC resource setup and the
operator scripts. There is no database of its own: the stack connects to a
provided PostgreSQL server. The three Java applications (`SmartDataJobs`,
`SmartUser`, `SmartData`) are consumed here as **artifact images**; `SWAC`,
`SWACdoc` and `SmartMonitoringFrontend` are bind-mounted into Payara's domain
docroot from their source directories.

Read this file before changing `compose.yaml`, `Dockerfile.payara`, `docker/`
or `scripts/`. Application-internal decisions (Maven layout, CDI, persistence
units, NetBeans history) are documented in the `AGENTS.md` of the respective
repository.

---

## 1. Repositories and scope

Seven repositories are involved: this deployment repository, the five
applications and the `SWACdoc` documentation site. All six submodules are **git
submodules** of this repository, not Maven modules of one reactor.

| Submodule path | Upstream / fork | Purpose |
| --- | --- | --- |
| — (this repository) | `SmartEnviroSystem/SmartDataDeployment` | Compose stack, master Payara image, JDBC/config, scripts |
| `SmartDataJobs` | `SmartEnviroSystem` → `JacobFrodermann` | Jobs REST application and its admin front end |
| `SmartUser` | `SmartEnviroSystem` → `JacobFrodermann` | User management REST application, JPA user store |
| `SmartData` | `SmartEnviroSystem` → `JacobFrodermann` | TreeQL database access REST API (tables, records, storages) |
| `SWAC` | `SmartEnviroSystem` only (no fork) | SmartWebApplicationComponents, static JavaScript UI library |
| `SWACdoc` | `SmartEnviroSystem` only (no fork) | SWAC documentation site: static pages with live component examples |
| `SmartMonitoringFrontend` | `SmartEnviroSystem` only (no fork) | SmartMonitoring web front end (static JavaScript application) |

### Cloning

```bash
git clone git@github.com:JacobFrodermann/SmartDataDeployment.git
cd SmartDataDeployment
git submodule update --init --recursive     # or ./scripts/submodules.sh
```

### Submodule URLs and remotes

`.gitmodules` records two kinds of URL, and the split matters for a fresh clone.

**The three Java applications** point at the **fork**
(`git@github.com:JacobFrodermann/<name>.git`). That is mandatory: the commits
pinned as gitlinks for them exist only in the forks, not upstream, so fetching
from `SmartEnviroSystem` would fail. `scripts/submodules.sh` adds upstream as
the second remote (`upstream`), so both are reachable:

```text
origin    -> git@github.com:JacobFrodermann/<name>.git   (fetch + push)
upstream  -> git@github.com:SmartEnviroSystem/<name>.git (pull, PR base)
```

**`SWAC`, `SWACdoc` and `SmartMonitoringFrontend`** point at **upstream**
(`git@github.com:SmartEnviroSystem/<name>.git`). They have no fork any more: the
fixes this stack needed (`SWAC` app_root handling, the front end's absolute
redirect targets) are upstream now, so `origin` *is* upstream — fetch, push and
PR base in one remote, and the script adds no second one. Their gitlinks must
point at commits that exist upstream.

Checking out this repository where the submodules already existed keeps their
original remotes (`origin` = `SmartEnviroSystem`, `fork` =
`JacobFrodermann`). Both layouts work; do not “fix“ them with a blind
`git submodule sync`, which rewrites `origin`. An old `fork` remote in the
upstream-only submodules is unused and can be deleted.

Rules that follow from this split:

- **No application source in this repository.** The submodules are pinned
  commits; do not copy WARs, POMs, Java sources or front-end assets into the top
  level or vendor them. This repository only orchestrates.
- **No deployment files in the application repositories.** Each *Java*
  application repository keeps exactly one `Dockerfile` (its artifact image,
  built from its own sources) and a `.dockerignore`; the static ones
  (`SWAC`, `SWACdoc`, `SmartMonitoringFrontend`) have no packaging step at all
  and are mounted from source. Compose files, the master Payara image, the
  `*_config.properties`, the JDBC init script and the operator scripts live
  here.
- **Commit in the submodule first, then bump the gitlink here.** A change inside
  `SmartDataJobs/` is invisible to this repository until its commit is pushed
  to the fork and the new gitlink is committed here (`git add SmartDataJobs`).
- The submodule paths are configurable, so another directory layout works:
  `SMARTDATAJOBS_DIR`, `SMARTUSER_DIR`, `SMARTDATA_DIR`, `SWAC_DIR`,
  `SWACDOC_DIR`, `SMARTMONITORINGFRONTEND_DIR` (see §9). Defaults are the
  submodule paths.
- `.dockerignore` excludes all submodule directories. The master Payara build
  context must never contain the application trees.

---

## 2. Runtime architecture

```text
Provided PostgreSQL 16 + PostGIS (frodermann.me, TLS)
    |
    | jdbc/SmartUser  -> db smartuser, schema smartuser (Hibernate/JPA)
    | jdbc/SmartData  -> db smartmonitoring_test, schema smartmonitoring
    |                    (JDBC, TreeQL tables; tbl_location.coordinates is
    |                     geometry(PointZ,4326))
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
    +-- /SWAC             (docroot mount from host SWAC/)
    |       static JavaScript UI library
    |
    +-- /SWACdoc          (docroot mount from host SWACdoc/)
    |       SWAC documentation; loads /SWAC, file data sources only
    |
    +-- /SmartMonitoringFrontend  (docroot mount from host
            SmartMonitoringFrontend/)
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
- SWACdoc: `http://localhost:8080/SWACdoc/` (documentation site, linked from
  the SWAC landing page)
- SmartMonitoring front end: `http://localhost:8080/SmartMonitoringFrontend/`
- Payara admin: `http://localhost:4848` with the image defaults `admin` / `admin`

The context root for deployed WARs comes from the WAR file name (`SmartDataJobs`,
`SmartUser`, `SmartData`). For SWAC, SWACdoc and SmartMonitoringFrontend the
context root is the directory name under the domain docroot (for SWACdoc it
must equal `app_root` in its `configuration.js`). The second URL segment of the
Java applications comes from the JAX-RS `@ApplicationPath` values inside them
(`smartdatajobs`, `smartuser`, `smartdata`).

---

## 3. Integration contract

This section is the reason this repository exists: it records what each
application expects from its environment and what the other components assume
about it. Changing one of these values in one place without changing it in the
others breaks the stack.

| # | Contract | Producer | Consumer | Failure if broken |
| --- | --- | --- | --- | --- |
| 1 | Artifact image tag (`*-war:local`) and WAR path `/opt/wars/<Name>.war` | application `Dockerfile` | `Dockerfile.payara` | image not found / empty `COPY` |
| 2 | WAR file name = context root = Payara application name (applies to `SmartDataJobs`, `SmartUser`, `SmartData`) | application `pom.xml` `finalName` | URLs, healthcheck, other apps | 404, or container stays `unhealthy` |
| 3 | JNDI name `jdbc/SmartUser` | `docker/payara/init_0_configure_databases.sh` | SmartUser `persistence.xml` | `databaseConnectivity:false`, login 500 |
| 4 | JNDI name `jdbc/SmartData` | same script | SmartData `postgres.jndi` default | `storage/getCollections` fails |
| 5 | PostgreSQL schema `smartuser` | provided server (provisioned) | SmartUser JPA entities | Hibernate cannot create tables |
| 6 | Storages `public`, `smartmonitoring` (PostgreSQL schemas) | provided server (provisioned: tables + seed rows) | monitoring front end | empty menus, no login form, 404 responses |
| 6b | PostGIS (`geometry(PointZ,4326)`) | provided server (PostGIS enabled) | `tbl_location.coordinates` | table creation fails, no locations/map |
| 7 | File `/opt/payara/<module-name>_config.properties` | `docker/payara/*_config.properties` | each application's `Configuration` loader | 412/500 on many endpoints, `propsloaded:false` |
| 8 | Context root `/SWAC` | docroot directory name in `compose.yaml` volume mount | SmartDataJobs pages, SWAC components, SmartMonitoring front end, SWACdoc pages | broken front end (absolute paths) |
| 9 | Shared PostgreSQL server, separate schemas | `compose.yaml` | SmartUser + SmartData | table clashes if schemas are mixed |
| 10 | `DEPLOY_PROPS=--force=true` | `compose.yaml` | Payara auto-deploy | restart logs "already registered" |
| 11 | Context root `/SmartMonitoringFrontend` | docroot directory name in `compose.yaml` volume mount | its own `configuration.js` data source `/SmartMonitoringFrontend/data/[fromName]` | data sources 404, no static JSON |
| 12 | Storage name `smartmonitoring` | hardcoded in the front end's `configuration.js` | SmartData, provided server | front end reads an empty/absent schema |
| 13 | Absolute URLs `/SWAC`, `/SmartData/smartdata`, `/SmartUser/smartuser` | the three deployed WARs plus the three docroot-mounted static applications | SmartMonitoring front end | blank page, failing login, no data |
| 14 | Context root `/SWACdoc` = `app_root` in `SWACdoc/configuration.js`, and the file data source `/SWACdoc/data/[fromName]` | `compose.yaml` volume mount name, `SWACdoc/configuration.js` | every SWACdoc page | example data 404s, blank documentation pages |
| 15 | MIME types `woff`, `woff2`, `webmanifest`, `manifest`, `wasm` in the domain's `config/default-web.xml` | `docker/payara/init_1_configure_mimetypes.sh` | the three docroot-mounted static applications | fonts and manifest served as `application/octet-stream`, broken icons/PWA |

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
- Users: the provided database has them already, so
  `GET /SmartUser/smartuser/system/setup` must not be called: it is one-shot and
  returns HTTP 500 from a unique constraint violation.
- Verified state of `smartuser.users` on the provided server: three rows —
  `*` (id 1, the anonymous user), `AppUser` (3) and `ffehring2` (4). There is
  **no** `admin` user.
- Login is `MD5(passwordsalt + password)`
  (`UsermanagerLocal.performLogin`). The stored hashes were created with a
  **different `passwordsalt`** than the development default shipped in
  `docker/payara/SmartUser_config.properties`: the documented
  `admin`/`admin` and `AppUser`/`SmartPassword1298!` both fail with
  `404 {"errors":["User not found or credentials are wrong."]}`. A login works
  only once either the salt matches the one the hashes were built with or the
  passwords are reset through SmartUser (contract 7, §7). This is data, not
  deployment: nothing here can repair it.
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

- No artifact image or WAR deployment. The SWAC source directory is mounted
  directly into Payara's domain docroot at `/SWAC` (see compose.yaml).
- No build step: the SWAC repository is a NetBeans HTML5 client project
  consisting of `index.html` and `swac/`.
- Served as static files by Payara's default servlet at `/SWAC`. That path is
  absolute in the consumers, e.g. `swac/components/Devhelper/sideboard.html`
  references `/SWAC/swac/components/Icon/imgs/error.svg` and SmartDataJobs
  pages load `/SWAC/swac/swac.js`.
- MIME mappings the WAR's `WEB-INF/web.xml` used to provide are now
  configured server-wide by `init_1_configure_mimetypes.sh`, which adds the
  types Payara lacks (`woff`, `woff2`, `webmanifest`, `manifest`, `wasm`). The
  WAR is gone from the repository, so nothing else carries them.
- `configuration.js` is **not** part of SWAC. SWAC loads
  `<app_root>/configuration.js` from the embedding application, so pages under
  `/SmartDataJobs/` use `SmartDataJobs/web/configuration.js`.
- Licensing: most of SWAC is LGPL, but 13 directories below
  `swac/components/` carry their own `LICENSE.md` marking them proprietary
  ("not for redistribution or modification without permission"), e.g.
  `Booking`, `Communicator`, `Mediaplayer`, `Texteditor`, `Questions`. Because
  the directory is now mounted at runtime (never baked into an image), pushing
  the master image to a registry does not redistribute those files; the
  licensing concern applies only if the SWAC tree itself is packaged.

### 3.5 SmartMonitoringFrontend

- No artifact image or WAR deployment. The SmartMonitoringFrontend source
  directory is mounted directly into Payara's domain docroot at
  `/SmartMonitoringFrontend` (see compose.yaml).
- No build step: a NetBeans HTML5 client project whose document root is the
  repository root (`index.html`, `index.js`, `configuration.js`, `css/`, `js/`,
  `sites/`, `data/`, `customisations/`, `files/`).
- Context root **`/SmartMonitoringFrontend`** is determined by the docroot
  directory name, which must match the value hardcoded in its
  `configuration.js` data source `/SmartMonitoringFrontend/data/[fromName]`.
- All data comes from SmartData, storage (= PostgreSQL schema)
  `smartmonitoring` (hardcoded in `configuration.js`).
- The schema alone is not enough: the tables and the seed rows are the presets
  shipped in `data/admin/presets/base.json`; the provided server already has
  them. Without `tbl_systemconfiguration`
  (rows `func_userlogin`, `func_userfavs`) the login form and favourites stay
  inactive; without `tbl_observedobject` the device list is empty.
- `tbl_location.coordinates` is a `geometry(PointZ,4326)` column, so the
  database must provide PostGIS. The provided server has the extension; any
  database used instead needs `CREATE EXTENSION IF NOT EXISTS postgis` before
  `tbl_location` can be created.
- No WAR, therefore no `WEB-INF/web.xml` and no `glassfish-web.xml`: the context
  root comes from the docroot directory name, and the MIME types the WAR used to
  map (`woff2`, `webmanifest`/`manifest`, `woff`, `wasm`) are configured
  server-wide by `init_1_configure_mimetypes.sh` (`svg`, `json` and `ico` are in
  Payara's own table).
- The mount serves the **whole checkout**, so `test files/`, `docs/`, `nbproject/`
  and the repository documentation are reachable over HTTP as well. The WAR
  packaging used to drop `test files/` and `docs/`; the mount cannot (§10.8).
- PWA: `serviceworker.js` caches the app, so browsers may serve stale assets
  after a redeploy; clear the worker/site data or bump the cache version.
- Redirect options (`afterLoginLoc`, `afterLogoutLoc`, `loggedinRedirects`,
  `accountURL`, `registrationLink`) must be absolute application paths. SWAC
  joins every one of them with the context root (`app_root`, no trailing
  slash), so a relative value produces `/SmartMonitoringFrontendsites/...` and
  a value used verbatim would lose the context root. SWAC had both defects
  until 2d91aa7; `SmartMonitoringFrontend` and `SmartUser` pass absolute paths
  since 4d5ad2d / fd620fe.
- `js/ai-config.js` targets `/SmartData/smartdata/proxy/ai`, which SmartData
  does not implement (only `proxy/get`); those features are inert.

### 3.6 SWACdoc

- No artifact image or WAR deployment. The `SWACdoc` source directory is
  mounted directly into Payara's domain docroot at `/SWACdoc` (see
  `compose.yaml`) and served by Payara's default servlet.
- Static NetBeans HTML5 client project: `index.html`, `configuration.js`,
  `content/`, `docs/`, `sites/`, `data/`, `files/`, `images/`, `css/` and `js/`.
  No build step. It is the largest submodule — `data/` alone is ~144 MB of
  example datasets (maps, media) and the checkout is ~270 MB including `.git`.
- `configuration.js` pins `app_root: '/SWACdoc'`, so the docroot directory name
  must not change. Its only active data source is the file source
  `/SWACdoc/data/[fromName]`; the SmartData REST source in the same file is
  commented out.
- Needs **no** database, storage, seed data, config properties or login. It is
  static content plus the SWAC library, which it loads from the absolute path
  `/SWAC/swac/swac.js` (contract 8) — so `/SWAC` has to be mounted as well.
- Needs the server-wide MIME types from `init_1_configure_mimetypes.sh`
  (`woff`, `woff2`, `webmanifest`, `manifest`, `wasm`) for its fonts and its
  PWA manifest.
- Why it is part of the stack: the SWAC landing page (`SWAC/index.html`) links
  to `/SWACdoc/`, and the documentation is the component reference for SWAC
  consumers. It is mounted, never baked into an image.

---

## 4. Artifact images

The three Java application repositories each build **one** artifact image.
Its only job is to carry a single deployable WAR:

```text
/opt/wars/<Name>.war
```

```bash
docker build -t smartdatajobs-war:local SmartDataJobs
docker build -t smartuser-war:local     SmartUser
docker build -t smartdata-war:local     SmartData
```

Properties of these images:

- They never run Payara; they end in an `alpine` stage that only copies the
  WAR.
- Java projects build the WAR inside Docker with Maven. The Smart\* helper jars
  come from the project-local Maven repository (each application's
  `libs/maven-repo`), so no sibling checkout is needed for the Maven build.
- `target/` is excluded by each repository's `.dockerignore`, so the WAR is
  never taken from the host.

SWAC, SWACdoc and SmartMonitoringFrontend are **not** built as artifact images.
They are static HTML/JS projects mounted directly into Payara's domain docroot
from the host source directories (see compose.yaml).

Consequence for this repository: `Dockerfile.payara` **cannot** build the
applications and must not try to. It references the artifact images by tag.
Compose cannot rebuild them either — `compose up --build` only rebuilds the
master image. `scripts/up.sh` builds the three artifact images first, and every
change to a Java application requires rebuilding its artifact image (§10.2).
The three static projects need none of that: they are mounted (§8.2).

---

## 5. Master Payara image

`Dockerfile.payara` builds the runnable container:

1. `FROM ${SMARTDATAJOBS_IMAGE} AS smartdatajobs-war` (default
   `smartdatajobs-war:local`).
2. `FROM ${SMARTUSER_IMAGE} AS smartuser-war` (default `smartuser-war:local`).
3. `FROM ${SMARTDATA_IMAGE} AS smartdata-war` (default `smartdata-war:local`).
4. Maven stage downloads the PostgreSQL JDBC driver
   (`org.postgresql:postgresql:42.7.4`).
5. `FROM payara/server-full:6.2025.11-jdk17`.
6. Copies the driver into
   `/opt/payara/appserver/glassfish/domains/domain1/lib/`.
7. Copies `docker/payara/init_0_configure_databases.sh` to
   `/opt/payara/scripts/`.
8. Copies the three `*_config.properties` into `/opt/payara/`.
9. Copies the three WARs (`SmartDataJobs.war`, `SmartUser.war`,
   `SmartData.war`) into `/opt/payara/deployments`.
10. Copies `docker/payara/init_1_configure_mimetypes.sh` to
    `/opt/payara/scripts/` for server-wide MIME type support.
11. Switches back to the `payara` runtime user.

Important details:

- The Payara base image runs as user `payara`. `USER root` is only used for the
  `chmod` of the init script; `USER payara` restores the runtime user.
- The build uses the classic Docker builder on the current machine, so avoid
  BuildKit-only features such as `COPY --chmod`.
- The build context is this repository only (`.dockerignore` drops `.git`,
  `scripts`, `.env` and Markdown), so a build never touches application
  sources.
- `SMARTDATAJOBS_IMAGE`, `SMARTUSER_IMAGE` and `SMARTDATA_IMAGE` are build
  args, so Compose (or a CI job) can point at other tags/registries without
  editing the Dockerfile.

---

## 6. Payara startup and JDBC resources

Payara auto-deploys everything in `/opt/payara/deployments` — the three Java
applications. The static projects are not deployed; they are served from the
docroot (§8.2).

The image ships three scripts in `/opt/payara/scripts/`, which the entrypoint
sources in name order:

1. `init_0_configure_databases.sh` — JTA data sources.
2. `init_1_configure_mimetypes.sh` — MIME types for the docroot (§8.2).
3. `init_1_generate_deploy_commands.sh` — Payara's own, generates the deploy
   commands.

`init_0_configure_databases.sh` appends one pool/resource pair per application
to `$POSTBOOT_COMMANDS`:

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

- `smartdatajobs`: master Payara image, exposes `8080` (HTTP) and `4848`
  (admin). It connects to the **provided PostgreSQL server**
  (`frodermann.me`), whose connection details are hardcoded in its environment
  block on purpose: the target must not be redirected by a stray variable. Only
  the password comes from `.env` (`SMARTUSER_DB_PASSWORD`, single quotes).
- `api-overview`: Swagger UI plus a small nginx proxy for the OpenAPI document
  Payara generates, exposes `8099` (§8.1). It is read-only and has no database
  access; `depends_on: smartdatajobs` only so its upstream name resolves at
  start.

There is no database service and no volume: the database is provided.

SWAC, SWACdoc and SmartMonitoringFrontend are **not** deployed as WARs. Their
source directories are bind-mounted into Payara's domain docroot (§8.2):

```yaml
volumes:
  - ./SWAC:/opt/payara/appserver/glassfish/domains/domain1/docroot/SWAC:ro
  - ./SWACdoc:/opt/payara/appserver/glassfish/domains/domain1/docroot/SWACdoc:ro
  - ./SmartMonitoringFrontend:/opt/payara/appserver/glassfish/domains/domain1/docroot/SmartMonitoringFrontend:ro
```

Payara's default servlet serves them as static files at `/SWAC/`, `/SWACdoc/`
and `/SmartMonitoringFrontend/` — the same URLs consumers already use. Editing
a file there is visible on reload; no rebuild or restart is needed.

Database target:

| Data source | Server | Database | Schema |
| --- | --- | --- | --- |
| `jdbc/SmartUser` | `frodermann.me:5432` | `smartuser` | `smartuser` |
| `jdbc/SmartData` | `frodermann.me:5432` | `smartmonitoring_test` | `smartmonitoring` |

The provided server is provisioned already: `smartuser` holds the user tables,
`smartmonitoring_test` holds `tbl_*`, 50 `tbl_navigationroute` rows, 51
`tbl_systemconfiguration` rows and PostGIS. There is **no** database literally
named `smartmonitoring`; that name is the schema inside `smartmonitoring_test`.
Do not point SmartData at the `smartuser` database: it has no `smartmonitoring`
schema and the role has no `CREATE` privilege there.

Project name and container name:

- `name: ${COMPOSE_PROJECT_NAME:-smartdatajobs}`.
- Container names are pinned (`smartdatajobs`, `api-overview`), so the commands
  in §11 are stable.
- The `smartdatajobs` container pins `hostname: smartdatajobs`, because Payara
  writes that host name into the OpenAPI document (see §8.1).

Compose healthcheck:

```yaml
apps=$(asadmin ... list-applications); echo "$apps" | grep -q SmartDataJobs
  && echo "$apps" | grep -qw SmartData
  && echo "$apps" | grep -q SmartUser
  && test -f $docroot/SWAC/index.html
  && test -f $docroot/SWACdoc/index.html
  && test -f $docroot/SmartMonitoringFrontend/index.html
```

The three deployed WARs must be listed — the three static projects cannot be,
because they are served from the docroot (§8.2). For those the healthcheck
tests their entry point in the docroot, which is what fails when a bind mount is
missing. There is no HTTP client in the Payara image (no `curl`, no `wget`) and
`/bin/sh` is dash, so a request-based check is not available either.
`grep -qw SmartData` is used because `SmartData` is a prefix of `SmartDataJobs`.

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
API_OVERVIEW_PORT                default 8099
SMARTUSER_DB_PASSWORD            required (set in .env, single quotes)
```

The database connection itself is **not** configurable through the environment:
host `frodermann.me`, port `5432`, databases `smartuser` and
`smartmonitoring_test`, user `webengineering_group` and `sslmode=require` are
hardcoded in `compose.yaml` (and mirrored as defaults in
`docker/payara/init_0_configure_databases.sh`). Change them there, deliberately.
The provided server accepts only encrypted connections, so the JDBC URL carries
`?sslmode=require`.

Copy `.env.example` to `.env` to set the password and the port overrides.

### 8.1 API overview

Payara Server 6 **ships MicroProfile OpenAPI**, so it already generates one
OpenAPI 3.0 document for all deployed JAX-RS applications:

```bash
curl http://localhost:8080/openapi                          # YAML, text/plain
curl -H 'Accept: application/json' http://localhost:8080/openapi  # JSON
```

Nothing is configured for this. `SmartDataJobs`, `SmartUser` and `SmartData`
depend on `microprofile-openapi-api` and annotate their resources
(`@Operation`, `@Parameter`, `@APIResponse`, `@Tag`); the scanner additionally
picks up every unannotated JAX-RS resource, so the document is complete (61
paths, 73 operations) with or without annotations. It is regenerated on every
deploy. `SWAC`, `SWACdoc` and `SmartMonitoringFrontend` are static files, not
applications, and contribute no paths.

Limitations of the raw endpoint, both solved by the proxy:

- no UI — MicroProfile OpenAPI defines only the document;
- no `Access-Control-Allow-Origin` header, so a browser cannot fetch it from
  another port;
- `servers[]` lists `http://<container-id>:8080/<app>` and
  `https://<container-id>:8181/<app>`, i.e. the container's own host name, which
  the host cannot resolve.

The `api-overview` service (`swaggerapi/swagger-ui:v5.34.1`, container name
`api-overview`, port `API_OVERVIEW_PORT`) replaces the nginx configuration of
that image (inline `configs: api-overview-nginx` in `compose.yaml`) and
provides:

| URL | Behaviour |
| --- | --- |
| `http://localhost:8099/` | Swagger UI, loads the document relatively as `/openapi` |
| `http://localhost:8099/openapi` | proxied document; JSON, `sub_filter` strips `http://smartdatajobs:8080` and `https://smartdatajobs:8181`, so `servers[]` becomes the relative `/SmartUser`, `/SmartData`, `/SmartDataJobs` |
| `http://localhost:8099/<app>/…` | proxied to Payara, so “Try it out” is same-origin (no CORS needed) |

Consequences to keep in mind:

- The proxy resolves `smartdatajobs` through Docker's embedded DNS (127.0.0.11)
  per request, so recreating the Payara container (new IP) needs no restart
  here.
- `hostname: smartdatajobs` on the Payara service is what makes the
  `sub_filter` rules deterministic. Changing that host name requires changing
  both `sub_filter` values.
- The two rewritten prefixes collapse to the same relative URL, so the server
  selector lists each application twice. Harmless, they behave identically.
- The proxy is a convenience, not part of the contract: `/openapi` on Payara
  stays the source of truth, and dropping the service breaks nothing else.
- Compose does not reliably recreate `api-overview` when only the inline
  `api-overview-nginx` content changes. After editing it, run
  `docker compose up -d --force-recreate api-overview`.

### 8.2 Static projects served from the docroot

SWAC, SWACdoc and SmartMonitoringFrontend are static HTML/JS projects. Instead of
being packaged into WARs, their source directories are bind-mounted read-only
into Payara's domain docroot, so the default servlet serves them:

```text
host SWAC/                   -> domains/domain1/docroot/SWAC/                   -> /SWAC/
host SWACdoc/                -> domains/domain1/docroot/SWACdoc/                -> /SWACdoc/
host SmartMonitoringFrontend/-> domains/domain1/docroot/SmartMonitoringFrontend/-> /SmartMonitoringFrontend/
```

Consequences:

- The **directory name below the docroot is the context root** (contracts 8, 11
  and 14). Renaming a mount breaks absolute paths inside the consumers.
- **No build step and no restart**: edit a file in any of the three directories
  and reload the browser. This is the main difference to the three WAR
  applications (§10.2). The file system view is immediate (verified: the
  container sees a host edit at once), but Payara's static-resource cache keeps
  a file it has already served for a few seconds — an edit or delete can look
  stale for ~5 s, and a fresh reload after that shows the change.
- **No deployment**: `list-applications` shows three applications, not six, and
  the healthcheck checks the mounts instead (§8).
- **No `WEB-INF`**: `web.xml` MIME mappings and `glassfish-web.xml` context roots
  are gone. `init_1_configure_mimetypes.sh` adds the types Payara lacks (`woff`,
  `woff2`, `webmanifest`, `manifest`, `wasm`) to the domain's
  `config/default-web.xml`. Payara's own table already covers `svg`, `json`,
  `ico`, `css`, `js` and `html`, so those are not repeated. The script is
  idempotent (it skips an extension that is present) and runs on every
  container start, so it also repairs a hand-edited domain.
- The whole checkout is served, not a curated document root (§10.8): for the
  front end that includes `docs/`, `test files/` and `nbproject/`.
- `SWACdoc` loads `/SWAC/swac/swac.js`, so `/SWAC` must be mounted together with
  it.

For frontend work outside the container, serve the repository root so that all
three prefixes resolve, or edit in place and let the mount do the work:

```bash
npx serve . -l 5173
```

---

## 9. Scripts

### `scripts/up.sh`

1. Verifies that the three Java submodules contain a `Dockerfile` and that the
   three static directories contain an `index.html` (or that the `*_DIR`
   overrides point at such checkouts).
2. Builds `smartuser-war:local`, `smartdata-war:local` and
   `smartdatajobs-war:local` — the three Java artifact images.
3. Runs `docker compose up --build -d` to build the master Payara image and
   start the stack.
4. Prints the URLs.

Submodule paths are overridable:

```bash
SMARTUSER_DIR=SmartUser SMARTDATA_DIR=SmartData \
SWAC_DIR=SWAC SWACDOC_DIR=SWACdoc SMARTDATAJOBS_DIR=SmartDataJobs \
SMARTMONITORINGFRONTEND_DIR=SmartMonitoringFrontend ./scripts/up.sh
```

Note: SWAC, SWACdoc and SmartMonitoringFrontend are verified for existence only —
they are not built. The `SWAC_DIR`, `SWACDOC_DIR` and
`SMARTMONITORINGFRONTEND_DIR` overrides must still point at valid directories
for the compose volume mounts to work.

### `scripts/submodules.sh`

Initialises/updates the six submodules and adds the upstream remote inside the
three forked ones (`SmartDataJobs`, `SmartUser`, `SmartData`; `origin` is the
fork from `.gitmodules`, see §1). It never rewrites existing remotes; when an
older checkout still has `origin` = `SmartEnviroSystem` and a `fork` remote, it
reports that instead. `SWAC`, `SWACdoc` and `SmartMonitoringFrontend` have no
fork: the script only reports their single `origin` (= upstream).

There are no database bootstrap scripts: the provided server is provisioned
already (users, `smartmonitoring` schema, tables, presets). Against any other
database the schema and seed rows have to be created through the SmartData API
(`POST /SmartData/smartdata/storage/create?name=smartmonitoring`, collection
and record endpoints) or the admin pages of the front ends; see §3.5 for what
the front end needs.

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
| `SWAC`, `SWACdoc` or `SmartMonitoringFrontend` (static files) | edit the file, reload the browser — no rebuild or restart needed |
| this repo (`compose.yaml`, `Dockerfile.payara`, `docker/`, `scripts/`) | `docker compose up --build -d` |

### 10.3 Payara admin password

The Payara image ships `/opt/payara/passwordFile` containing
`AS_ADMIN_PASSWORD=admin`. Setting only the `ADMIN_PASSWORD` environment
variable does not rewrite that file. The stack therefore uses the image
defaults (`admin`/`admin`). If the password is changed, update the password
file, otherwise `asadmin` healthchecks and administration commands fail.

### 10.4 Two `Configuration` classes per application

`SmartUserAuth` and `NGI_RestUtils` contain classes whose names collide with
application classes (`de.fhbielefeld.smartuser.config.Configuration`,
`de.fhbielefeld.smartdata.config.Configuration`). The web class loader prefers
`WEB-INF/classes` over `WEB-INF/lib`, so the application's own class wins. This
is expected; do not "fix" it by changing the artifact image contents. See the
`AGENTS.md` of SmartUser and SmartData.

### 10.5 Missing artifact image looks like a broken deployment

If one artifact image is missing, `Dockerfile.payara` fails at the `FROM`
stage — or, when an old image is still present, the container deploys an older
WAR. Check `docker images | grep -- -war:local` first when behaviour disagrees
with the checkout.

### 10.6 Provided server: missing grants and the missing `smartuser.groups`

The provided server is provisioned for the applications, not for schema
management. Verified state (role `webengineering_group`):

- `smartuser` db: `USAGE` on schema `smartuser`, `SELECT/INSERT/UPDATE/DELETE`
  on the five user tables and `USAGE` on their sequences — enough for login and
  user management. **Not** granted: `CREATE` on schema `smartuser`, `CREATE` on
  the database, and ownership of the tables.
- `smartmonitoring_test` db: `SELECT/INSERT/UPDATE/DELETE` on all 28 tables of
  schema `smartmonitoring`, but not `CREATE` on that schema, so SmartData cannot
  create a new collection (table) there.
- `smartuser.groups` is **missing**, while
  `SmartUser/src/java/.../persistence/jpa/Group.java` maps to
  `@Table(name = "groups", schema = "smartuser")`. Hibernate's
  `hbm2ddl.auto=update` cannot create it without `CREATE` on the schema and only
  logs `permission denied` (`halt_on_error` is not set), so group features are
  the one thing that needs a grant from the server owner:

  ```sql
  GRANT CREATE ON SCHEMA smartuser TO webengineering_group;      -- smartuser db
  GRANT CREATE ON SCHEMA smartmonitoring TO webengineering_group; -- smartmonitoring_test db
  ```

- The server accepts **only encrypted** connections: `sslmode=disable` fails
  with `pg_hba.conf rejects connection ... no encryption`, so the JDBC URL
  carries `?sslmode=require` (`SMARTUSER_DB_SSLMODE`).
- Pool credentials with `:` or `=` must be escaped in the asadmin `--property`
  string; see `prop_escape()` in `docker/payara/init_0_configure_databases.sh`.
  Without it `create-jdbc-connection-pool` fails with
  `IllegalArgumentException: Invalid property syntax, ...` and **no**
  `jdbc/SmartUser` / `jdbc/SmartData` resource is created at all — the
  applications then fail with `databaseConnectivity:false`.

### 10.7 Pooled connections after a database restart

When the database server is restarted or becomes unreachable for longer than
the pool timeout, the Payara JTA pools still hold dead connections. The first
request that touches the database then fails with HTTP 500 and a
`java.lang.reflect.UndeclaredThrowableException` at
`com.sun.gjc.spi.base.ConnectionHolder.getWarnings`, typically in
`performLogin`.

Fix: restart the application container.

```bash
docker compose restart smartdatajobs
```

`/SmartUser/smartuser/system/info` may still report
`"databaseConnectivity":true` in that state, because it opens a fresh
connection — the health endpoint is not a reliable indicator here.

### 10.8 The docroot mounts serve the whole checkout

A bind mount cannot filter: everything in `SWAC/`, `SWACdoc/` and
`SmartMonitoringFrontend/` is reachable over HTTP, including `docs/`,
`test files/`, `nbproject/`, `.gitignore` and the repository Markdown. The WAR
packaging used to drop the parts a deployment should not expose. Two
mitigations if that matters: keep the checkouts free of secrets (they are), or
mount individual document-root entries instead of the directory (one volume per
entry — verbose, and easy to forget when a new top-level file appears).

### 10.9 MIME types live in the domain configuration

`init_1_configure_mimetypes.sh` patches `config/default-web.xml` **inside the
container**. Without it, fonts are served as `application/octet-stream` and the
PWA manifest as text; adding a mapping to the script has no effect on a running
container until it is restarted.

---

## 11. Common maintenance tasks

### Start from scratch

```bash
./scripts/up.sh           # builds the three artifact images + master image, starts Payara
```

The database is the provided PostgreSQL server and is provisioned already;
nothing is bootstrapped from here.

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

For `SWAC`, `SWACdoc` and `SmartMonitoringFrontend` the same flow runs against
upstream — there is no fork, so `origin` is both:

```bash
cd SmartMonitoringFrontend
git push origin master             # origin = SmartEnviroSystem upstream

cd ..
git add SmartMonitoringFrontend
git commit -m "chore(submodules): bump SmartMonitoringFrontend"
```

Those three are mounted rather than built, so a bump takes effect with the next
working-tree checkout — a browser reload is enough, no image build.

### Check deployment

```bash
docker compose ps
docker exec smartdatajobs asadmin --user=admin \
  --passwordfile=/opt/payara/passwordFile list-applications
docker exec smartdatajobs asadmin --user=admin \
  --passwordfile=/opt/payara/passwordFile list-jdbc-resources
```

Expected applications: `SmartData`, `SmartDataJobs`, `SmartUser` — three, not six.
Expected resources: `jdbc/SmartUser`, `jdbc/SmartData`.

The static projects are not applications. Check the mounts and the MIME setup
instead:

```bash
docker exec smartdatajobs ls -d \
  /opt/payara/appserver/glassfish/domains/domain1/docroot/{SWAC,SWACdoc,SmartMonitoringFrontend}
```

### Check the database

Against the provided server:

```bash
PGPASSWORD='…' psql "host=frodermann.me user=webengineering_group dbname=smartuser sslmode=require" \
  -c '\dn' -c '\dt smartuser.*'
PGPASSWORD='…' psql "host=frodermann.me user=webengineering_group dbname=smartmonitoring_test sslmode=require" \
  -c '\dt smartmonitoring.*'
```

Expected schemas: `public`, `smartmonitoring`, `smartuser`.
Expected tables in `smartuser`: `accessfail`, `groups`, `groupusers`,
`resources`, `userrights`, `users` (on the provided server `smartuser.groups`
is still missing — see §3.2).

The `smartmonitoring` schema lives in the separate database
`smartmonitoring_test` and is provisioned already (50 menu rows, 51 feature
rows): `tbl_ootype`, `tbl_metatype`, `tbl_datatype`, `tbl_observedobject`,
`tbl_location`, `tbl_location_join_oo`, `tbl_navigationroute` (50 rows) and
`tbl_systemconfiguration` (51 rows). Further `tbl_*` tables are created through
the SmartData API or the admin setup pages of the front ends.

The `public` schema stays empty unless something uses the default storage.
Calling `storage/create?name=smartmonitoring` for an existing schema does not
return 201.

### Check the endpoints

```bash
for p in SmartDataJobs/ SmartDataJobs/smartdatajobs/system/info \
         SmartUser/ SmartUser/smartuser/system/info \
         SmartData/ SmartData/smartdata/system/info \
         SWAC/ SWAC/swac/swac.js \
         SWACdoc/ SWACdoc/configuration.js \
         SWACdoc/data/concepts/components_example1.json \
         SmartMonitoringFrontend/ \
         SmartMonitoringFrontend/configuration.js \
         SmartMonitoringFrontend/data/admin/presets/base.json; do
    curl -s -o /dev/null -w "%{http_code} $p\n" "http://localhost:8080/$p"
done
```

All fourteen must return 200.

```bash
# SmartData storage access through jdbc/SmartData
curl -s "http://localhost:8080/SmartData/smartdata/storage/getCollections?name=public"
# -> {"list":[]}

# a storage is a PostgreSQL schema (already present on the provided server)
curl -s -X POST "http://localhost:8080/SmartData/smartdata/storage/create?name=smartmonitoring"
# -> 201 only for a schema that does not exist yet; the provided server has it

# the front end's data source: tables + the feature switches it needs
curl -s "http://localhost:8080/SmartData/smartdata/records/tbl_systemconfiguration?storage=smartmonitoring&filter=ckey,eq,func_userlogin"
# -> one row with "active":true
curl -s "http://localhost:8080/SmartData/smartdata/records/tbl_navigationroute?storage=smartmonitoring&size=1"
# -> one menu row

# SmartUser CDI + JPA
curl -s http://localhost:8080/SmartUser/smartuser/system/info
# -> "databaseConnectivity":true

# login round trip
# The username has to exist and the salt has to match the stored hash (§3.2).
# Against the provided server both documented logins currently fail with
# 404 "User not found or credentials are wrong."; the endpoint itself answers.
curl -s -c /tmp/cookies -X POST -H 'Content-Type: application/json' \
  -d '{"username":"admin","password":"admin"}' \
  http://localhost:8080/SmartUser/smartuser/user/performLogin
curl -s -b /tmp/cookies http://localhost:8080/SmartUser/smartuser/user       # 200 on success
curl -s -o /dev/null -w '%{http_code}\n' http://localhost:8080/SmartUser/smartuser/user  # 401 without cookie

# SWAC MIME types
curl -sI http://localhost:8080/SWAC/swac/libs/mathlive/fonts/KaTeX_AMS-Regular.woff2
# -> Content-Type: font/woff2
curl -sI http://localhost:8080/SWAC/swac/components/Icon/imgs/error.svg
# -> Content-Type: image/svg+xml

# OpenAPI: the document Payara generates, and the proxied overview (§8.1)
curl -s -H 'Accept: application/json' http://localhost:8080/openapi | head -c 200
curl -s http://localhost:8099/openapi | grep -c '" /smart'   # paths, relative servers
curl -s -o /dev/null -w '%{http_code}\n' http://localhost:8099/                # 200
curl -s -o /dev/null -w '%{http_code}\n' http://localhost:8099/SmartUser/smartuser/system/info  # 200
```

### Logs

```bash
docker compose logs -f smartdatajobs
```

### Clean rebuild

```bash
docker build --no-cache -t smartuser-war:local     SmartUser
docker build --no-cache -t smartdata-war:local     SmartData
docker build --no-cache -t smartdatajobs-war:local SmartDataJobs
docker compose build --no-cache
docker compose up -d
```

### After the database server was unavailable

```bash
docker compose restart smartdatajobs    # stale pooled connections (§10.7)
```

### Stop / reset

```bash
docker compose down          # stop the stack (provided DB untouched)
```

---

## 12. Verification checklist

- [ ] `docker build -t smartdatajobs-war:local SmartDataJobs` succeeds.
- [ ] `docker build -t smartuser-war:local SmartUser` succeeds.
- [ ] `docker build -t smartdata-war:local SmartData` succeeds.
- [ ] `docker compose build` succeeds.
- [ ] `docker compose up -d` starts `smartdatajobs` and `api-overview`, nothing
      else.
- [ ] `docker compose ps` reports `smartdatajobs` healthy (`api-overview` has
      no healthcheck).
- [ ] `asadmin list-applications` lists exactly `SmartDataJobs`, `SmartData` and
      `SmartUser` — and no `SWAC` / `SmartMonitoringFrontend` application.
- [ ] `asadmin list-jdbc-resources` lists `jdbc/SmartUser` and `jdbc/SmartData`.
- [ ] The three WAR HTTP endpoints return 200: `/SmartDataJobs/`,
      `/SmartUser/`, `/SmartData/`.
- [ ] `/SWAC/swac/swac.js`, `/SWACdoc/` and `/SmartMonitoringFrontend/` return
      200 from the docroot, and `/opt/payara/deployments` holds no `SWAC.war` /
      `SmartMonitoringFrontend.war`.
- [ ] Editing a file in `SWAC/` is visible on reload, without a rebuild or
      restart (§8.2).
- [ ] A SWACdoc example page (`/SWACdoc/sites/concepts/1_quickstart.html`) loads
      its data from `/SWACdoc/data/...` and the `/SWACdoc/` link on
      `/SWAC/` resolves.
- [ ] The three `*/system/config` endpoints report `"propsloaded":true`.
- [ ] `/SmartData/smartdata/storage/getCollections?name=public` returns
      `{"list":[]}`.
- [ ] `/SmartUser/smartuser/system/info` reports
      `"databaseConnectivity":true`.
- [ ] Against the provided server: `smartmonitoring` resolves through
      `jdbc/SmartData` (`storage/getCollections?name=smartmonitoring`) and
      `tbl_systemconfiguration` has 51 rows, `tbl_navigationroute` 50 rows.
- [ ] `/user` without a cookie returns 401.
- [ ] `user/performLogin` returns 200 and an `authtoken` cookie for a user whose
      password matches the stored hash. Against the provided server the
      documented logins return 404 `User not found or credentials are wrong.`
      (no `admin` user, salt mismatch — §3.2), so this is not a deployment
      failure.
- [ ] `/SmartDataJobs/` and `/SmartData/` load `/SWAC/swac/swac.js` without 404.
- [ ] `/SWAC/swac/libs/mathlive/fonts/KaTeX_AMS-Regular.woff2` is served as
      `font/woff2` by `init_1_configure_mimetypes.sh`.
- [ ] The `smartuser` schema contains the six expected tables.
- [ ] `docker compose restart smartdatajobs` becomes healthy again, logs no
      `Application with name ... is already registered` and no
      `A resource named ...Pool already exists`.
- [ ] `http://localhost:8099/` serves Swagger UI and `http://localhost:8099/openapi`
      returns the document with relative `servers[]`; `/SmartUser/…` through
      port 8099 also answers (§8.1).

---

## 13. Key files

```text
.gitmodules                         # submodule paths: fork URLs for the three Java apps, upstream for SWAC, SWACdoc, SmartMonitoringFrontend (see §1)
compose.yaml                        # provided PostgreSQL + master Payara service
                                    # + docroot mounts + read-only api-overview
Dockerfile.payara                   # master Payara image (three WARs + MIME setup)
.dockerignore                       # build context = this repo, submodules excluded
.env.example                        # password + port overrides (incl. API_OVERVIEW_PORT)
docker/payara/init_0_configure_databases.sh   # jdbc/SmartUser, jdbc/SmartData
docker/payara/init_1_configure_mimetypes.sh   # MIME types for docroot static assets
docker/payara/SmartDataJobs_config.properties
docker/payara/SmartUser_config.properties     # salts, serviceorder, confirm_mail
docker/payara/SmartData_config.properties     # postgres.jndi / mongo / smartuser auth
scripts/submodules.sh               # submodule init/update + upstream remote
scripts/up.sh                       # build the three artifact images + start the stack
```

In the application repositories, this stack depends on:

```text
SmartDataJobs/Dockerfile   # -> /opt/wars/SmartDataJobs.war
SmartUser/Dockerfile       # -> /opt/wars/SmartUser.war
SmartData/Dockerfile       # -> /opt/wars/SmartData.war
SmartMonitoringFrontend/data/admin/presets/base.json   # schema + seed data
SWACdoc/configuration.js            # app_root /SWACdoc + file data sources
```

SWAC and SmartMonitoringFrontend are consumed from their source directories via
docroot mounts, not from artifact images: neither repository has a `Dockerfile`
or a `docker/WEB-INF/` any more, and no `swac-war:local` /
`smartmonitoringfrontend-war:local` image is built. SWACdoc is plain static
files — it never had a packaging step.

---

## 14. History

The Docker setup grew inside `SmartDataJobs`: the WAR artifact `Dockerfile`,
the master `Dockerfile.payara`, `compose.yaml`, the Payara init script, the
`*_config.properties` and the operator scripts all lived there next to the
application sources. That mixed two lifecycles — a single application release
and the deployment of several applications plus infrastructure.

The deployment concern was therefore extracted into this repository. The
application repositories keep exactly their own artifact `Dockerfile`; every
cross-component fact (context roots, JNDI names, config file names, schema
ownership, build order, startup ordering, healthcheck) lives here, in §3 and in
the sections that follow it.

The SmartMonitoring front end was added afterwards, and it is the first
component whose data does not come from a database it owns: it lives entirely
in SmartData's `smartmonitoring` storage, whose tables and preset rows are part
of the provided server.

SWAC, SWACdoc and SmartMonitoringFrontend used to be packaged into static WARs
(`swac-war:local`, `smartmonitoringfrontend-war:local`) whose `WEB-INF/web.xml`
carried the MIME mappings and whose `glassfish-web.xml` pinned the context root.
That put every frontend edit behind an image build and a redeploy, so the three
are now bind-mounted into Payara's docroot (§8.2) and the MIME mappings moved to
`init_1_configure_mimetypes.sh`. Their forks became unnecessary at that point:
the fixes this stack needed were merged upstream, and `.gitmodules` records
`SmartEnviroSystem` for them.

This repository used to ship a local PostgreSQL Compose service (PostGIS,
`local-db` profile), an init SQL, two bootstrap scripts and an
`SMARTUSER_DB_MANAGED` switch to seed such a database. All of that was removed:
the stack targets the provided server only, and a self-managed database would
be provisioned outside of this repository.
