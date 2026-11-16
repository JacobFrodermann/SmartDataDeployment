#!/usr/bin/env bash
#
# Builds one application WAR from its upstream Ant/NetBeans submodule and
# packages it as the thin artifact image Dockerfile.payara expects
# (AGENTS.md section 4).
#
#   ./scripts/build_war.sh SmartDataJobs
#   ./scripts/build_war.sh SmartUser
#   ./scripts/build_war.sh SmartData
#
# Flow (MIGRATION_PLAN.md section 3.1):
#   1. export the pinned submodule tree to build/work/<Name>/src
#   2. apply the patches from build/patches/<Name>/ (SmartUser only)
#   3. run `ant dist` with the property overrides from
#      build/ant-settings.properties, inside the ant-builder container
#   4. verify dist/<Name>.war exists and is non-empty
#   5. build the artifact image <name>-war:local from build/Dockerfile.artifact
#
# The submodule working tree is never touched: the build always starts from
# `git archive HEAD`, so the submodule stays a clean upstream checkout and the
# built WAR always reflects the pinned gitlink.
#
# Modes:
#   default        build inside the ant-builder Docker image (no host Ant/JDK
#                  needed); the image is built on first use
#   --host-ant     run `ant` from the host instead (fast iteration; requires
#                  Apache Ant 1.10+ and a JDK 17 on the host)
#
# Environment overrides:
#   SMARTDATAJOBS_DIR / SMARTUSER_DIR / SMARTDATA_DIR   submodule paths
#   ANT_BUILDER_IMAGE  ant-builder image tag
#                     (default: smartdata-ant-builder:local)

set -euo pipefail

cd "$(dirname "$0")/.."
repo_root="$(pwd)"

# --- configuration -----------------------------------------------------------

BUILDER_IMAGE="${ANT_BUILDER_IMAGE:-smartdata-ant-builder:local}"

case "${1:-}" in
    SmartDataJobs|SmartUser|SmartData)
        app="$1"; shift ;;
    *)
        echo "usage: $0 [--host-ant] <SmartDataJobs|SmartUser|SmartData>" >&2
        exit 1 ;;
esac

host_ant=0
if [ "${1:-}" = "--host-ant" ]; then
    host_ant=1; shift
fi

case "$app" in
    SmartDataJobs) dir_var=SMARTDATAJOBS_DIR; image=smartdatajobs-war:local ;;
    SmartUser)     dir_var=SMARTUSER_DIR;     image=smartuser-war:local ;;
    SmartData)     dir_var=SMARTDATA_DIR;     image=smartdata-war:local ;;
esac
submodule_dir="${!dir_var:-$app}"

if [ ! -d "$submodule_dir/.git" ] && [ ! -f "$submodule_dir/.git" ]; then
    echo "error: $submodule_dir is not a checked-out submodule" >&2
    echo "       run ./scripts/submodules.sh first" >&2
    exit 1
fi

work="$repo_root/build/work/$app"
src_dir="$work/src"
jar_dir="$work/jar"

# --- 0. verify the vendored build inputs ------------------------------------

( cd "$repo_root/build/libs" && sha256sum --quiet --check libs.sha256 ) \
    || { echo "error: build/libs/ does not match build/libs/libs.sha256" >&2
         echo "       restore the vendored jars (see build/README.md)" >&2
         exit 1; }

# --- 1. export the pinned submodule tree -------------------------------------

echo "==> $app: exporting pinned submodule tree ($submodule_dir @ $(git -C "$submodule_dir" rev-parse --short HEAD))"
rm -rf "$work"
mkdir -p "$src_dir" "$jar_dir"
git -C "$submodule_dir" archive HEAD | tar -x -C "$src_dir"

# --- 2. apply patches --------------------------------------------------------

patch_dir="$repo_root/build/patches/$app"
if [ -d "$patch_dir" ] && [ -n "$(find "$patch_dir" -name '*.patch' -print -quit)" ]; then
    echo "==> $app: applying patches from build/patches/$app"
    for p in "$patch_dir"/*.patch; do
        echo "    $(basename "$p")"
        # --fuzz=0 + hard failure: a patch that no longer applies means
        # upstream moved and the patch needs a conscious rebase (AGENTS.md
        # section 10.10). Never weaken this.
        patch -d "$src_dir" -p1 --fuzz=0 --batch < "$p"
    done
else
    echo "==> $app: no patches to apply"
fi

# --- 3. run the Ant build ----------------------------------------------------

ant_settings_host="$repo_root/build/ant-settings.properties"

if [ "$host_ant" -eq 1 ]; then
    echo "==> $app: running host ant dist"
    # Map the container paths in ant-settings.properties to build/libs/.
    ant_args=(
        -propertyfile "$ant_settings_host"
        -Dj2ee.platform.classpath="$repo_root/build/libs/jakarta.jakartaee-api-10.0.0.jar"
        -Dlibs.jakartaee-api-10.0.classpath="$repo_root/build/libs/jakarta.jakartaee-api-10.0.0.jar"
        -Dlibs.CopyLibs.classpath="$repo_root/build/libs/org-netbeans-modules-java-j2seproject-copylibstask.jar"
        -Dreference.NGI_RestUtils.jar="$repo_root/build/libs/NGI_RestUtils-1.0.0.jar"
        -Dreference.NGI_Logger.jar="$repo_root/build/libs/NGI_Logger-1.0.0.jar"
        -Dreference.NGI_AdvancedReflection.jar="$repo_root/build/libs/NGI_AdvancedReflection-1.0.0.jar"
        -Dreference.SmartUserAuth.jar="$repo_root/build/libs/SmartUserAuth-1.0.0.jar"
    )
    if [ "$app" = "SmartUser" ]; then
        # Upstream SmartUser references an IDE library (libs.restapi.classpath)
        # that no longer resolves; the classes it provided come from
        # NGI_RestUtils. An empty value in a property file does not override,
        # so it must be a -D.
        ant_args+=( -Dlibs.restapi.classpath= )
    fi
    ( cd "$src_dir" && ant "${ant_args[@]}" dist )
else
    echo "==> $app: running ant dist in the builder container"
    if ! docker image inspect "$BUILDER_IMAGE" >/dev/null 2>&1; then
        echo "    building $BUILDER_IMAGE first..."
        docker build -t "$BUILDER_IMAGE" -f "$repo_root/build/Dockerfile.ant-builder" "$repo_root"
    fi
    docker run --rm \
        -v "$src_dir":/workspace:ro \
        -v "$jar_dir":/out \
        -v "$ant_settings_host":/opt/ant-builder/ant-settings.properties:ro \
        --entrypoint /bin/bash \
        "$BUILDER_IMAGE" -c '
            set -euo pipefail
            cp -r /workspace /build && cd /build
            ant_args=( -propertyfile /opt/ant-builder/ant-settings.properties )
            if [ "'"$app"'" = "SmartUser" ]; then
                ant_args+=( -Dlibs.restapi.classpath= )
            fi
            ant "${ant_args[@]}" dist
            cp "dist/'"$app"'.war" /out/
        '
fi

# --- 4. verify the WAR -------------------------------------------------------

war="$jar_dir/$app.war"
if [ ! -s "$war" ]; then
    echo "error: $war was not produced or is empty" >&2
    exit 1
fi
echo "==> $app: built $(du -h "$war" | cut -f1) $app.war"

# --- 5. package the artifact image ------------------------------------------

echo "==> $app: building artifact image $image"
docker build -f "$repo_root/build/Dockerfile.artifact" \
    --build-arg WAR="$app.war" \
    -t "$image" \
    "$jar_dir"

echo "==> $app: done ($image)"
