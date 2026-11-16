# Migration plan: Maven forks back to upstream Ant submodules

Goal: drop the three Maven forks (`JacobFrodermann/SmartDataJobs`, `SmartUser`,
`SmartData`) and consume the **upstream** `SmartEnviroSystem` Ant/NetBeans
projects directly, with **all build instruction in this repository**. The
submodules become pure upstream checkouts; everything that makes them build
and deploy lives here.

## 0. Evaluation result (verified, not assumed)

Feasibility was tested empirically on 2026-11-16 by exporting the three
upstream trees and running their own `ant dist` headless:

| Test | Result |
| --- | --- |
| `SmartDataJobs` upstream `b5d916f` — `ant dist` with property overrides | **BUILD SUCCESSFUL**, `dist/SmartDataJobs.war` produced, `-post-dist` jakartaee-strip ran |
| `SmartUser` upstream `179b5f9` — same | **compilation fails** against the current `NGI_RestUtils` (uses `de.fhbielefeld.scl.rest.dataflow.DataFlowInterceptor`, which upstream `NGI_RestUtils` removed in `fd6b08f`); **succeeds** with the 3-line `de.ngi.logging.Logger` fix that the fork already carries |
| `SmartData` upstream `1cc9a09` — same | **BUILD SUCCESSFUL**, `dist/SmartData.war` produced |
| `NGI_Logger` upstream — `ant jar` | **BUILD SUCCESSFUL** (helper projects build fine too) |

The NetBeans `build-impl.xml` is self-contained and runs under plain Apache Ant
1.10 once five IDE-owned properties are supplied on the command line (see
§3.2). No NetBeans installation is needed at build time.

**Conclusion: the migration is possible.** The upstream Ant build needs no
changes; the only source-level delta that must survive is the three SmartUser
fixes (§2.1), carried as patches in this repo.

### What the property overrides are (proven working)

```bash
ant dist \
  -Dj2ee.platform.classpath=<jakartaee-api-10.0.0.jar> \
  -Dlibs.jakartaee-api-10.0.classpath=<jakartaee-api-10.0.0.jar> \
  -Dlibs.CopyLibs.classpath=<org-netbeans-modules-java-j2seproject-copylibstask.jar> \
  -Dno.dependencies=true \
  -Dreference.NGI_RestUtils.jar=<helper jar> \
  -Dreference.NGI_Logger.jar=<helper jar> \
  -Dreference.NGI_AdvancedReflection.jar=<helper jar> \
  -Dreference.SmartUserAuth.jar=<helper jar>
  # SmartUser only, additionally:
  # -Dlibs.restapi.classpath=   (empty — upstream references an IDE library
  #                              that no longer resolves; the classes it
  #                              provided come from NGI_RestUtils anyway)
```

`no.dependencies=true` skips upstream's `deps-module-jar` target, which would
otherwise Ant-build the four helper projects from sibling checkouts
(`../NGI_Logger` etc.) — the vendored jars replace that (§2.2).

## 1. Decisions (confirmed by the user)

1. **SmartUser fixes live as patches in this repo**, applied to an exported
   upstream tree at build time. No fork is kept. Optionally PR them upstream
   later and delete the patch.
2. **The four helper jars are vendored in this repo** (`build/libs/`), not
   built from four more submodules. All three forks already carry
   byte-identical copies (SHA256 verified across SmartDataJobs, SmartUser and
   SmartData `libs/maven-repo/`), so they are the proven-good artifacts.
3. **Gitlinks track upstream master**:
   `SmartDataJobs` → `b5d916f`, `SmartUser` → `179b5f9`,
   `SmartData` → `1cc9a09`. This deliberately *gains* the upstream features the
   forks were missing (job-states endpoint + stop-logging in SmartDataJobs; AI
   proxy + config secret masking in SmartData).
4. **Ant runs inside a Docker builder image** owned by this repo. The host
   needs neither Ant nor a JDK. Artifact images stay thin alpine WAR carriers
   tagged `*-war:local`, so `Dockerfile.payara` does not change at all.

## 2. Target layout of this repository

```text
SmartDataDeployment/
├── compose.yaml                  # unchanged
├── Dockerfile.payara              # unchanged (still consumes *-war:local)
├── docker/                        # unchanged
├── scripts/
│   ├── up.sh                      # rewritten: ant-based artifact build
│   ├── submodules.sh              # simplified: upstream-only remotes
│   └── build_war.sh               # NEW: the Ant build wrapper (§3)
├── build/                         # NEW: all build instruction lives here
│   ├── Dockerfile.ant-builder     # NEW: Ant 1.10 + JDK 17 builder image
│   ├── ant-settings.properties    # NEW: shared -D overrides (§3.2)
│   ├── patches/
│   │   └── SmartUser/
│   │       ├── 0001-de-ngi-logging.patch
│   │       ├── 0002-beans-discovery-all.patch
│   │       └── 0003-absolute-redirect-paths.patch
│   └── libs/
│       ├── NGI_Logger-1.0.0.jar           (SHA256 ec8b8a0d…)
│       ├── NGI_RestUtils-1.0.0.jar        (SHA256 fbe573b9…)
│       ├── NGI_AdvancedReflection-1.0.0.jar (SHA256 db99d43f…)
│       ├── SmartUserAuth-1.0.0.jar        (SHA256 a2c21c6a…)
│       └── libs.sha256                   # provenance file
├── SmartDataJobs/                 # submodule -> SmartEnviroSystem/SmartDataJobs @ b5d916f
├── SmartUser/                     # submodule -> SmartEnviroSystem/SmartUser     @ 179b5f9
├── SmartData/                     # submodule -> SmartEnviroSystem/SmartData     @ 1cc9a09
├── SWAC/ …                        # unchanged upstream submodules
```

The submodule trees themselves stay **untouched** — the wrapper never edits
files in place, it exports to a work directory (§3.1). That keeps the
submodules clean upstream checkouts: `git status` inside them is always empty.

## 3. The build wrapper (`scripts/build_war.sh`)

### 3.1 Flow per application

1. **Export** the pinned submodule tree to a work directory:
   `git -C <submodule> archive HEAD | tar -x -C build/work/<Name>`.
   (`archive HEAD`, not a copy of the working tree: the build must reflect the
   pinned gitlink, and the submodule must stay readable as a checkout.)
2. **Patch** (SmartUser only): apply
   `build/patches/<Name>/*.patch` with `patch -p1 --fuzz=0`. Fail loudly if a
   patch does not apply — that means upstream moved and the patch needs a
   rebase, which must never happen silently.
3. **Ant build** inside the builder container (§3.3):
   `ant dist` with the property overrides from §0, pointing
   `reference.*.jar` at the vendored `build/libs/` jars.
4. **Verify** the result: `dist/<Name>.war` exists and is non-empty.
5. **Package** the artifact image (§4).

### 3.2 `build/ant-settings.properties`

One file, all applications, mapping the IDE-owned properties to paths inside
the builder container:

```properties
# Jakarta EE 10 platform API (compile-time only; Payara provides the impl)
j2ee.platform.classpath=/opt/ant-builder/libs/jakarta.jakartaee-api-10.0.0.jar
libs.jakartaee-api-10.0.classpath=/opt/ant-builder/libs/jakarta.jakartaee-api-10.0.0.jar

# NetBeans CopyLibs task jar (required by build-impl.xml -init-taskdefs)
libs.CopyLibs.classpath=/opt/ant-builder/libs/org-netbeans-modules-java-j2seproject-copylibstask.jar

# Do not Ant-build the helper projects from sibling checkouts; the vendored
# jars below replace them.
no.dependencies=true

# Vendored Smart* helper jars (identical in all three forks' maven-repos)
reference.NGI_RestUtils.jar=/opt/ant-builder/libs/NGI_RestUtils-1.0.0.jar
reference.NGI_Logger.jar=/opt/ant-builder/libs/NGI_Logger-1.0.0.jar
reference.NGI_AdvancedReflection.jar=/opt/ant-builder/libs/NGI_AdvancedReflection-1.0.0.jar
reference.SmartUserAuth.jar=/opt/ant-builder/libs/SmartUserAuth-1.0.0.jar

# SmartUser only: upstream references an IDE library that no longer resolves.
libs.restapi.classpath=
```

The wrapper passes `-propertyfile build/ant-settings.properties` plus, for
SmartUser, `-Dlibs.restapi.classpath=` (an empty value in a property file does
not override, it must be a `-D`).

### 3.3 `build/Dockerfile.ant-builder`

```dockerfile
FROM eclipse-temurin:17-jdk
# Apache Ant from the official Apache binary distribution (tar.gz from dlcdn)
ARG ANT_VERSION=1.10.15
RUN curl -fsSL "https://dlcdn.apache.org/ant/binaries/apache-ant-${ANT_VERSION}-bin.tar.gz" \
      -o /tmp/ant.tgz \
 && echo "<sha512>  /tmp/ant.tgz" | sha512sum -c - \
 && tar -xzf /tmp/ant.tgz -C /opt \
 && ln -s /opt/apache-ant-${ANT_VERSION} /opt/ant \
 && rm /tmp/ant.tgz
ENV PATH=/opt/ant/bin:$PATH
ENV ANT_OPTS=-Duser.home=/tmp
COPY build/libs /opt/ant-builder/libs
WORKDIR /workspace
```

Notes:

- **Ant itself** comes from the official Apache distribution with a pinned
  SHA512 (the host Ant 1.10.18 used for the evaluation is fine too, but the
  builder image must be self-contained). Pick the current 1.10.x at
  implementation time and record the checksum.
- **`jakarta.jakartaee-api-10.0.0.jar`** and the **CopyLibs task jar** go into
  `build/libs/` as well, so the builder needs no network at run time. The
  CopyLibs jar is *not* on Maven Central (verified: 404) — take it from the
  local NetBeans installation
  (`/usr/lib/netbeans/java/ant/extra/org-netbeans-modules-java-j2seproject-copylibstask.jar`,
  108 976 bytes) and record its SHA256 in `build/libs/libs.sha256`. It is a
  small self-contained Ant task, Apache-licensed, vendored once.
- The four Smart\* helper jars are copied out of the current forks'
  `libs/maven-repo/` (SHA256s in §2; identical across all three forks).

### 3.4 Why export instead of building in the submodule

- The submodule stays a pristine upstream checkout (no generated files, no
  patched files, `git status` clean).
- Patches are visible and reviewable in this repo, and a failing `patch`
  invocation is a hard error that forces a conscious rebase — the exact
  opposite of a fork silently drifting.
- Docker build contexts stay small: the export directory contains only the
  upstream tree, not `.git`.

## 4. Artifact images

The application repositories lose their `Dockerfile`s (the forks are deleted,
§6). The artifact images become **generic** and are built by this repo:

```dockerfile
# build/Dockerfile.artifact — ARG WAR=SmartDataJobs.war
FROM alpine:3.20
ARG WAR
COPY ${WAR} /opt/wars/${WAR}
```

`scripts/build_war.sh` runs the Ant builder, then:

```bash
docker build -f build/Dockerfile.artifact \
  --build-arg WAR=SmartDataJobs.war \
  -t smartdatajobs-war:local \
  build/work/SmartDataJobs
```

The tag names (`smartdatajobs-war:local`, `smartuser-war:local`,
`smartdata-war:local`) and the `/opt/wars/<Name>.war` contract are **unchanged**,
so `Dockerfile.payara`, `compose.yaml` and the whole §3 integration contract of
AGENTS.md survive untouched.

## 5. Step-by-step execution order

Each step ends in a verifiable state; do not start the next before the
previous one is green.

### Step 1 — Vendor the build inputs (this repo only, no submodule change)

- [ ] `mkdir -p build/libs build/patches/SmartUser`
- [ ] Copy the four helper jars from `SmartDataJobs/libs/maven-repo/…` into
      `build/libs/`, plus `jakarta.jakartaee-api-10.0.0.jar` (from the local
      Maven cache; it is the exact version upstream's `project.properties`
      reference) and the CopyLibs task jar from the NetBeans installation.
- [ ] Write `build/libs/libs.sha256` with all six checksums and let
      `build_war.sh` verify it before every build.
- [ ] Write `build/ant-settings.properties` (§3.2).

### Step 2 — Generate the SmartUser patches from the fork

- [ ] From `SmartUser`, export the three diffs against upstream as patch
      files (they are the *only* src/web deltas, verified):
      - `0001-de-ngi-logging.patch` — `UserRightsResource.java`:
        `DataFlowInterceptor` → `de.ngi.logging.Logger` (3 lines; **required
        for compilation** against the current NGI_RestUtils)
      - `0002-beans-discovery-all.patch` — `web/WEB-INF/beans.xml`
        `bean-discovery-mode="none"` → `"all"` (**required for runtime**:
        without CDI, `@PersistenceContext`/`@Resource` stay null and login
        fails with 500)
      - `0003-absolute-redirect-paths.patch` — `web/configuration.js`
        relative → absolute redirect paths (**required for runtime**: SWAC
        joins them with the context root)
- [ ] Verify each patch applies cleanly to a fresh export of upstream
      `179b5f9` with `patch -p1 --dry-run`.

### Step 3 — Build the builder image and the wrapper

- [ ] `build/Dockerfile.ant-builder` (§3.3), tag `smartdatajobs-ant-builder:local`.
- [ ] `scripts/build_war.sh <Name>` implementing §3.1; it must support an
      optional `--host-ant` mode for fast local iteration (uses the host Ant,
      same property file) — useful during development, not used by `up.sh`.
- [ ] Smoke test all three: `./scripts/build_war.sh SmartDataJobs` etc.
      must produce the three WARs.

### Step 4 — Validate WAR parity against the current Maven WARs

Before switching the deployment, diff the Ant WARs against the currently
deployed Maven WARs:

- [ ] Same `WEB-INF/lib` jar set per application (SmartUser: 18 jars — the
      Ant build packages `sun-jndi-ldap.jar` from upstream `libs/`, the Maven
      build used `sun-jndi-ldap-1.0.0.jar` from the maven-repo; identical
      content, name differs. SmartData: 9 jars. SmartDataJobs: 8 jars.)
- [ ] `WEB-INF/classes` contains the same packages; `persistence.xml`,
      `hibernate.properties`, `beans.xml` present (beans.xml *with* the
      discovery patch applied).
- [ ] No `jakartaee-*.jar` in any WAR (upstream's `-post-dist` handles this;
      verify it ran).
- [ ] Optional but recommended: `docker compose up -d` with the Ant WARs and
      run the whole §12 verification checklist of AGENTS.md (list-applications,
      propsloaded, storage access, login round trip, MIME types, OpenAPI).

### Step 5 — Switch the submodules to upstream

- [ ] `.gitmodules`: change the three Java URLs from
      `git@github.com:JacobFrodermann/<Name>.git` to
      `https://github.com/SmartEnviroSystem/<Name>.git` (or the SSH form),
      keep `branch = master`.
- [ ] `git submodule set-url` for each; then fetch upstream inside each
      submodule and checkout the pinned commit:
      `SmartDataJobs` → `b5d916f`, `SmartUser` → `179b5f9`,
      `SmartData` → `1cc9a09`.
- [ ] `git add .gitmodules SmartDataJobs SmartUser SmartData` and commit the
      new gitlinks.
- [ ] `scripts/submodules.sh`: simplify — the fork/upstream remote split for
      the three Java apps disappears; every submodule now has one remote,
      like SWAC/SWACdoc/SmartMonitoringFrontend already do.

### Step 6 — Rewire `scripts/up.sh`

- [ ] Replace the three `docker build -t <name>-war:local <dir>` calls with
      `./scripts/build_war.sh SmartDataJobs` etc. (which ends in the artifact
      image build).
- [ ] Keep the existence checks for the six submodules as they are.
- [ ] `docker compose up --build -d` stays the last step, unchanged.

### Step 7 — Documentation

- [ ] AGENTS.md: rewrite §1 (repositories: no forks any more, all six
      submodules upstream-only, `submodules.sh` adds no second remote), §4
      (artifact images now built by *this* repo from upstream Ant sources +
      patches), §5 (unchanged master image), §9 (up.sh flow), §10 (rebuild
      matrix: "changed an application" now means "bumped the submodule +
      rebuilt the WAR through the wrapper"; add the patch-rebase pitfall,
      §8 of this plan), §13/§14 (key files, history note).
- [ ] Add a `build/README.md` documenting the wrapper, the property
      overrides, the vendored jars and their provenance, and the patch policy.

### Step 8 — Retire the forks

- [ ] Only after the stack has run green on upstream WARs for a while:
      archive/delete `JacobFrodermann/SmartDataJobs`, `SmartUser`,
      `SmartData` on GitHub. Until then, keep them as a fallback.
- [ ] Optionally: PR the SmartUser fixes to `SmartEnviroSystem/SmartUser`
      (the `de.ngi.logging` one is an upstream bug fix — it does not compile
      against their own current NGI_RestUtils — and has a good chance of being
      accepted). Once merged, delete the corresponding patch file and re-pin
      the gitlink.

## 6. Risks and mitigations

| Risk | Mitigation |
| --- | --- |
| Upstream moves and a patch stops applying | `patch --fuzz=0` + hard failure in the wrapper; the gitlink pins the exact commit, so this can only happen on a deliberate bump, never on a rebuild |
| Upstream build changes its property contract (e.g. new `libs.*` reference) | Same situation: the pinned gitlink keeps rebuilds stable; a bump surfaces the break immediately at build time |
| CopyLibs jar provenance (not on Maven Central) | Vendored once with SHA256 recorded; it is a stable, Apache-licensed NetBeans artifact that has not changed in years |
| Behaviour drift from tracking upstream master (AI proxy in SmartData now active; job-states endpoint appears) | Deliberate (decision 3); the front end's `ai-config.js` targets `proxy/ai` which now *exists* — verify during Step 4 stack validation; `SmartData_config.properties` keeps it unconfigured/inert |
| WAR packaging differences (Maven vs Ant) | Step 4 parity diff before switching; the Ant WARs are the *original* packaging the applications were designed for |
| Losing the fork history | The forks stay on GitHub until Step 8; the deployment repo's git history references them |

## 7. What does *not* change

- `compose.yaml`, `Dockerfile.payara`, `docker/` — untouched.
- The three static submodules (SWAC, SWACdoc, SmartMonitoringFrontend) and
  their docroot mounts — untouched.
- All context roots, JNDI names, config files, healthcheck, §3 integration
  contract — untouched, because the artifact image tags and WAR paths do not
  change.
- The provided PostgreSQL server and all data — untouched.

## 8. New pitfall for AGENTS.md §10 (write it during Step 7)

**Patch rebase on submodule bump**: bumping the `SmartUser` gitlink can break
`0001…0003` patches. The wrapper fails loudly; the fix is to regenerate the
patch against the new tree (from the fork's diff, or by hand) — never to
weaken `--fuzz`. Also document: `ant-settings.properties` maps IDE-owned
properties; if a bumped upstream `project.properties` introduces a new
`libs.*` reference, add it there (empty value if the classes come from another
jar) — the build error message names the missing property.
