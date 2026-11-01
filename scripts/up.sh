#!/usr/bin/env bash
#
# Builds the three Java artifact images, then the master Payara image, then
# starts the stack.
#
# The application repositories are git submodules of this repository (see
# AGENTS.md §2). Their paths can be overridden:
#
#   SMARTDATAJOBS_DIR=SmartDataJobs
#   SMARTUSER_DIR=SmartUser
#   SMARTDATA_DIR=SmartData
#   SWAC_DIR=SWAC
#   SWACDOC_DIR=SWACdoc
#   SMARTMONITORINGFRONTEND_DIR=SmartMonitoringFrontend
#
# SWAC, SWACdoc and SmartMonitoringFrontend have no build step: compose mounts
# their source directories into Payara's docroot (AGENTS.md §8.2), so only their
# presence is checked here.
set -euo pipefail

cd "$(dirname "$0")/.."

SMARTDATAJOBS_DIR="${SMARTDATAJOBS_DIR:-SmartDataJobs}"
SMARTUSER_DIR="${SMARTUSER_DIR:-SmartUser}"
SMARTDATA_DIR="${SMARTDATA_DIR:-SmartData}"
SWAC_DIR="${SWAC_DIR:-SWAC}"
SWACDOC_DIR="${SWACDOC_DIR:-SWACdoc}"
SMARTMONITORINGFRONTEND_DIR="${SMARTMONITORINGFRONTEND_DIR:-SmartMonitoringFrontend}"

# Java applications: built from their own Dockerfile.
for dir in "$SMARTDATAJOBS_DIR" "$SMARTUSER_DIR" "$SMARTDATA_DIR"; do
    if [ ! -f "$dir/Dockerfile" ]; then
        echo "error: no Dockerfile in $dir" >&2
        echo "       initialise the submodules (./scripts/submodules.sh) or override *_DIR" >&2
        exit 1
    fi
done

# Static projects: mounted at runtime, so their entry point must exist.
for dir in "$SWAC_DIR" "$SWACDOC_DIR" "$SMARTMONITORINGFRONTEND_DIR"; do
    if [ ! -f "$dir/index.html" ]; then
        echo "error: no index.html in $dir" >&2
        echo "       initialise the submodules (./scripts/submodules.sh) or override *_DIR" >&2
        exit 1
    fi
done

echo "Building SmartUser artifact image..."
docker build -t smartuser-war:local "$SMARTUSER_DIR"

echo "Building SmartData artifact image..."
docker build -t smartdata-war:local "$SMARTDATA_DIR"

echo "Building SmartDataJobs artifact image..."
docker build -t smartdatajobs-war:local "$SMARTDATAJOBS_DIR"

echo "SWAC, SWACdoc and SmartMonitoringFrontend are mounted from their source"
echo "directories, not built."

echo "Building master Payara image and starting the stack..."
docker compose up --build -d

echo "SmartDataJobs: http://localhost:${SMARTDATAJOBS_HTTP_PORT:-8080}/SmartDataJobs/"
echo "SmartMonitoring: http://localhost:${SMARTDATAJOBS_HTTP_PORT:-8080}/SmartMonitoringFrontend/"
echo "SmartUser:     http://localhost:${SMARTDATAJOBS_HTTP_PORT:-8080}/SmartUser/"
echo "SmartData:     http://localhost:${SMARTDATAJOBS_HTTP_PORT:-8080}/SmartData/"
echo "SWAC:          http://localhost:${SMARTDATAJOBS_HTTP_PORT:-8080}/SWAC/"
echo "SWACdoc:       http://localhost:${SMARTDATAJOBS_HTTP_PORT:-8080}/SWACdoc/"
echo "API overview:  http://localhost:${API_OVERVIEW_PORT:-8099}/"
echo "Payara admin:  http://localhost:${SMARTDATAJOBS_ADMIN_PORT:-4848} (admin/admin)"
echo
echo "The database is the provided PostgreSQL server and is provisioned already;"
echo "there is nothing to bootstrap here."
