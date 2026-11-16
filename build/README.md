# build/ — the Ant build system for the Java applications

The three Java application submodules — `SmartDataJobs`, `SmartUser`,
`SmartData` — are consumed as **pure upstream `SmartEnviroSystem` Ant/NetBeans
checkouts**: the gitlinks point at upstream master, and the application
repositories carry no build instruction of ours. All build instruction lives
in this repository.

| Path | Role |
| --- | --- |
| `Dockerfile.ant-builder` | builder image: JDK 17 + Apache Ant 1.10.18 + the vendored libs |
| `Dockerfile.artifact` | generic thin artifact image carrying exactly one WAR |
| `ant-settings.properties` | property overrides that make the NetBeans build run headless |
| `libs/` | vendored build inputs, checksummed in `libs/libs.sha256` |
| `patches/SmartUser/` | the three SmartUser fixes, applied to the exported tree |
| `work/` | per-application export/build output; gitignored, disposable |

`scripts/build_war.sh` drives everything. Per application it:

1. **exports** the pinned submodule tree: `git archive HEAD` of the gitlink,
   extracted into `build/work/<Name>/src` — never a copy of the working tree;
2. **patches** the export (SmartUser only) from `build/patches/<Name>/`;
3. runs **`ant dist`** with the property overrides from
   `ant-settings.properties`, inside the builder container;
4. verifies `dist/<Name>.war` exists and is non-empty;
5. packages the **thin artifact image** `<name>-war:local` with the WAR at
   `/opt/wars/<Name>.war` — the contract `Dockerfile.payara` consumes
   (AGENTS.md §3, contracts 1 and 2).

The submodule working tree is never touched: `git status` inside a submodule
stays clean and the built WAR always reflects the pinned gitlink. The design
and its empirical verification are recorded in `MIGRATION_PLAN.md`.

## Usage

```bash
./scripts/build_war.sh SmartDataJobs
./scripts/build_war.sh SmartUser
./scripts/build_war.sh SmartData
```

| Mode | Requires | Use |
| --- | --- | --- |
| default | Docker only — `ant dist` runs inside `smartdata-ant-builder:local`, which the wrapper builds automatically on first use | normal builds; what `scripts/up.sh` calls |
| `--host-ant` | Apache Ant 1.10+ and JDK 17 on the host; the container paths in the property file are remapped to `build/libs/` | fast local iteration |

Environment overrides: `ANT_BUILDER_IMAGE` (builder image tag, default
`smartdata-ant-builder:local`) and the usual `SMARTDATAJOBS_DIR`,
`SMARTUSER_DIR`, `SMARTDATA_DIR` submodule path variables.

Before every build the wrapper verifies `build/libs/` against `libs.sha256`
and fails hard on any mismatch.

## The property overrides (`ant-settings.properties`)

Upstream's `nbproject/build-impl.xml` references properties that a NetBeans
installation normally defines. The property file supplies them, so the build
runs headless under plain Apache Ant 1.10 — no NetBeans, no IDE:

| Property | Meaning |
| --- | --- |
| `j2ee.platform.classpath` | Jakarta EE 10 platform API (compile-time only) |
| `libs.jakartaee-api-10.0.classpath` | the same jar, under the name upstream's `project.properties` references |
| `libs.CopyLibs.classpath` | the NetBeans CopyLibs Ant task, required by `-init-taskdefs` |
| `no.dependencies=true` | skip upstream's `deps-module-jar`, which would Ant-build the four helper projects from sibling checkouts — the vendored jars replace that |
| `reference.NGI_RestUtils.jar` (likewise `NGI_Logger`, `NGI_AdvancedReflection`, `SmartUserAuth`) | the four vendored Smart* helper jars |

The paths are `/opt/ant-builder/libs/…`, valid inside the builder container;
`--host-ant` mode maps them 1:1 to `build/libs/`.

**SmartUser additionally needs `-Dlibs.restapi.classpath=`** (empty value):
upstream references an IDE library that no longer resolves — the classes it
provided come from `NGI_RestUtils`. The wrapper passes it as a `-D` on the
command line, because an **empty value in a property file does not override**;
only a `-D` does.

## Vendored jars (`build/libs/`)

| Jar | Provenance |
| --- | --- |
| `NGI_Logger-1.0.0.jar` | Smart* helper project; taken from the application repositories' `libs/maven-repo/` trees, where byte-identical copies exist (SHA256-verified identical across the three former forks) |
| `NGI_RestUtils-1.0.0.jar` | same |
| `NGI_AdvancedReflection-1.0.0.jar` | same |
| `SmartUserAuth-1.0.0.jar` | same |
| `jakarta.jakartaee-api-10.0.0.jar` | Jakarta EE 10 platform API, compile-time only — upstream's `-post-dist` strips it from the WAR; Payara provides the implementation at runtime |
| `org-netbeans-modules-java-j2seproject-copylibstask.jar` | the NetBeans CopyLibs Ant task. Not published on Maven Central; vendored from a NetBeans installation. Small, self-contained, Apache-licensed |

`libs.sha256` records the SHA256 of all six files; `build_war.sh` verifies it
before every build. The builder image copies `build/libs/` to
`/opt/ant-builder/libs`, so the build itself needs no network — Ant is
downloaded only when the builder image is built, from the official Apache
distribution with a pinned SHA512.

## The SmartUser patches (`build/patches/SmartUser/`)

The three fixes the former fork carried live here as patches, applied to the
exported upstream tree at build time:

| Patch | Change | Required for |
| --- | --- | --- |
| `0001-de-ngi-logging.patch` | `src/java/de/fhbielefeld/smartuser/rest/UserRightsResource.java`: `DataFlowInterceptor` → `de.ngi.logging.Logger` | **compilation** — upstream SmartUser does not compile against the current `NGI_RestUtils`, which removed `DataFlowInterceptor`. Genuine upstream bug. |
| `0002-beans-discovery-all.patch` | `web/WEB-INF/beans.xml`: `bean-discovery-mode="none"` → `"all"` | **runtime** — without CDI the `@PersistenceContext`/`@Resource` injections stay `null` and login/user management fail with HTTP 500 |
| `0003-absolute-redirect-paths.patch` | `web/configuration.js`: relative → absolute redirect paths (`afterLoginLoc`, `afterLogoutLoc`, `registrationLink`, `loggedinRedirects`) | **runtime** — SWAC joins these values with the context root |

Policy:

- Patches apply with `patch -p1 --fuzz=0`; a failing patch is a **hard
  error**. It means upstream moved and the patch needs a conscious rebase —
  never fuzz, never a silent skip.
- All three fixes could be PR'd upstream — `0001` especially, it is a genuine
  upstream bug. Once merged, delete the patch file here and re-pin the
  gitlink.

## Pitfalls

### Patch rebase on a gitlink bump

Bumping the `SmartUser` gitlink can make the patches stop applying — upstream
moved underneath them. The build fails and names the failing patch. Regenerate
the patch against the new tree (from the old fork's diff or by hand) and
commit it here; never weaken `--fuzz=0`.

### New `libs.*` references upstream

If a bumped upstream `nbproject/project.properties` introduces a new `libs.*`
reference, the build fails and names the missing property. Add it to
`ant-settings.properties` — with an empty value if the classes come from
another jar; an empty value only takes effect as a `-D` (the
`libs.restapi.classpath` precedent above).

### Editing inside a submodule does not affect builds

Builds start from `git archive HEAD` of the pinned gitlink, so edits and
uncommitted changes inside a submodule working tree are invisible to the
build. To change an application: commit in the submodule, bump the gitlink in
this repository, re-run `./scripts/build_war.sh <Name>`.
