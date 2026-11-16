#!/usr/bin/env bash
#
# Initialises / updates the submodules.
#
# All six submodules point at upstream SmartEnviroSystem repositories
# (see AGENTS.md section 1). There are no forks any more:
#
#   SmartDataJobs, SmartUser, SmartData   upstream Ant/NetBeans checkouts,
#                                         pinned in this repository; their
#                                         runtime fixes live in
#                                         build/patches/ and are applied at
#                                         build time (scripts/build_war.sh)
#   SWAC, SWACdoc, SmartMonitoringFrontend
#                                         upstream static projects, mounted
#                                         into Payara's docroot at runtime
#
# After a fresh clone every submodule has exactly one remote, `origin`, taken
# from .gitmodules — and that origin *is* upstream. Nothing is added or
# rewritten here. Older checkouts that still carry remotes from the fork era
# (`fork`, `upstream`) are reported; they are unused and can be deleted.
set -euo pipefail

cd "$(dirname "$0")/.."

SUBMODULES="SmartDataJobs SmartUser SmartData SWAC SWACdoc SmartMonitoringFrontend"

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

    # Remotes from the fork era are unused leftovers; report, never rewrite.
    for stale in fork upstream; do
        if git -C "$name" remote get-url "$stale" >/dev/null 2>&1; then
            echo "   note: an unused '$stale' remote still exists ($(git -C "$name" remote get-url "$stale"));"
            echo "         it can be removed with: git -C $name remote remove $stale"
        fi
    done
done

echo
echo "Done."
