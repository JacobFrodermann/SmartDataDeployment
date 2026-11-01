#!/usr/bin/env bash
#
# Initialises / updates the submodules and makes a second remote available where
# one is needed.
#
# The submodules come from two places (see AGENTS.md §1):
#
#   SmartDataJobs, SmartUser, SmartData   fork (JacobFrodermann/*), because the
#                                         commits pinned here do not exist
#                                         upstream
#   SWAC, SWACdoc, SmartMonitoringFrontend
#                                         upstream (SmartEnviroSystem/*) only
#
# After a fresh clone every submodule has exactly one remote, `origin`, taken
# from .gitmodules. For the three fork projects this script adds the upstream
# repository as the second remote, so both are reachable without renaming
# origin:
#
#   upstream -> git@github.com:SmartEnviroSystem/<name>.git
#
# Pushing keeps working against origin (the fork); pulling upstream changes is
# `git -C <submodule> fetch upstream`.
#
# The three upstream-only projects have no fork: their origin *is* upstream, so
# fetch, push and PR base are one remote and nothing is added.
set -euo pipefail

cd "$(dirname "$0")/.."

UPSTREAM_ORG="${UPSTREAM_ORG:-SmartEnviroSystem}"
FORK_ORG="${FORK_ORG:-JacobFrodermann}"

SUBMODULES="SmartDataJobs SmartUser SmartData SWAC SWACdoc SmartMonitoringFrontend"
FORKLESS="SWAC SWACdoc SmartMonitoringFrontend"

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

    # Upstream-only project: origin is upstream, there is no fork to add.
    if printf '%s\n' $FORKLESS | grep -qx "$name"; then
        echo "   note: no fork exists for $name; origin is upstream, nothing to add"
        if git -C "$name" remote get-url fork >/dev/null 2>&1; then
            echo "   note: an older 'fork' remote still exists ($(git -C "$name" remote get-url fork));"
            echo "         it is unused and can be removed"
        fi
        continue
    fi

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
