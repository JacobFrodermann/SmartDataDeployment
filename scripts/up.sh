#!/usr/bin/env bash
#
# Builds all artifact images, then the master Payara image, then starts the
# stack.
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
set -euo pipefail

cd "$(dirname "$0")/.."

SMARTDATAJOBS_DIR="${SMARTDATAJOBS_DIR:-SmartDataJobs}"
SMARTUSER_DIR="${SMARTUSER_DIR:-SmartUser}"
SMARTDATA_DIR="${SMARTDATA_DIR:-SmartData}"
SWAC_DIR="${SWAC_DIR:-SWAC}"
SWACDOC_DIR="${SWACDOC_DIR:-SWACdoc}"
SMARTMONITORINGFRONTEND_DIR="${SMARTMONITORINGFRONTEND_DIR:-SmartMonitoringFrontend}"

for dir in "$SMARTDATAJOBS_DIR" "$SMARTUSER_DIR" "$SMARTDATA_DIR" "$SWAC_DIR" "$SWACDOC_DIR" "$SMARTMONITORINGFRONTEND_DIR"; do
    if [ ! -d "$dir" ]; then
        echo "error: $dir does not exist" >&2
        echo "       initialise the submodules (./scripts/submodules.sh)" >&2
        exit 1
    fi
done

echo "Building SmartUser artifact image..."
docker build -t smartuser-war:local "$SMARTUSER_DIR"

echo "Building SmartData artifact image..."
docker build -t smartdata-war:local "$SMARTDATA_DIR"

echo "Building SmartDataJobs artifact image..."
docker build -t smartdatajobs-war:local "$SMARTDATAJOBS_DIR"

echo "SWAC, SWACdoc and SmartMonitoringFrontend are mounted from host directories, not built."

echo "Building master Payara image and starting services..."
docker compose up --build -d

echo
if [ "$(docker compose exec -T smartuser-db psql -U "${SMARTUSER_DB_USER:-smartuser}" -d "${SMARTUSER_DB_NAME:-smartuser}" -tAc 'select count(*) from smartuser.users' 2>/dev/null || echo '') " = "0 " ]; then
    echo "SmartUser has no users yet. After startup, run ./scripts/init-smartuser.sh once"
    echo "to create the default users (admin/admin) and the anonymous CREATE right."
    echo
fi

echo "SmartDataJobs: http://localhost:${SMARTDATAJOBS_HTTP_PORT:-8080}/SmartDataJobs/"
echo "SmartMonitoring: http://localhost:${SMARTDATAJOBS_HTTP_PORT:-8080}/SmartMonitoringFrontend/"
echo "SmartUser:     http://localhost:${SMARTDATAJOBS_HTTP_PORT:-8080}/SmartUser/"
echo "SmartData:     http://localhost:${SMARTDATAJOBS_HTTP_PORT:-8080}/SmartData/"
echo "SWAC:          http://localhost:${SMARTDATAJOBS_HTTP_PORT:-8080}/SWAC/"
echo "SWACdoc:       http://localhost:${SMARTDATAJOBS_HTTP_PORT:-8080}/SWACdoc/"
echo "Payara admin:  http://localhost:${SMARTDATAJOBS_ADMIN_PORT:-4848} (admin/admin)"
echo
echo "Fresh database? Run ./scripts/init-smartuser.sh once after the container is healthy."
echo "Then run ./scripts/init-smartmonitoring.sh to create the smartmonitoring storage,"
echo "its tables and the feature switches the front end needs."
