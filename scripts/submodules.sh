#!/usr/bin/env bash
#
# Initialises / updates the application submodules and makes the second remote
# available inside them.
#
# The five application repositories are git submodules of this repository. The
# recorded URL in .gitmodules is the fork (JacobFrodermann/*), because that is
# where the commits pinned by this repository exist. SmartEnviroSystem/* is
# upstream.
#
# After a fresh clone the submodules have exactly one remote:
#
#   origin -> git@github.com:JacobFrodermann/<name>.git   (from .gitmodules)
#
# This script adds the upstream repository as the second remote, so both
# repositories are reachable without renaming origin:
#
#   upstream -> git@github.com:SmartEnviroSystem/<name>.git
#
# Pushing keeps working against origin (the fork); pulling upstream changes is
# `git -C <submodule> fetch upstream`.
set -euo pipefail

cd "$(dirname "$0")/.."

UPSTREAM_ORG="${UPSTREAM_ORG:-SmartEnviroSystem}"
FORK_ORG="${FORK_ORG:-JacobFrodermann}"

SUBMODULES="SmartDataJobs SmartUser SmartData SWAC SmartMonitoringFrontend"

echo "Initialising submodules..."
git submodule update --init --recursive

for name in $SUBMODULES; do
    if [ ! -d "$name/.git" ] && [ ! -f "$name/.git" ]; then
        echo "error: $name is not checked out" >&2
        exit 1
    fi

    origin_url="$(git -C "$name" remote get-url origin 2>/dev/null || true)"
    echo "== $name"
    echo "   origin:   ${origin_url:-<none>}"

    if git -C "$name" remote get-url upstream >/dev/null 2>&1; then
        upstream_url="$(git -C "$name" remote get-url upstream)"
        echo "   upstream: $upstream_url (already configured)"
    else
        git -C "$name" remote add upstream "git@github.com:$UPSTREAM_ORG/$name.git"
        echo "   upstream: git@github.com:$UPSTREAM_ORG/$name.git (added)"
    fi

    # Older checkouts used origin=SmartEnviroSystem and a remote named "fork".
    # Report that instead of silently rewriting the user's remotes.
    if git -C "$name" remote get-url fork >/dev/null 2>&1; then
        echo "   note: an additional remote 'fork' exists ($(git -C "$name" remote get-url fork))"
    fi
    if [ -n "$origin_url" ] && [ "$origin_url" != "git@github.com:$FORK_ORG/$name.git" ]; then
        echo "   note: origin is not the fork URL from .gitmodules;"
        echo "         'git submodule sync' would point it at the fork again"
    fi
done

echo
echo "Done."
