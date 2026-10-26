#!/usr/bin/env bash
#
# One-time SmartMonitoring data bootstrap.
#
# The front end reads all of its data from the SmartData storage
# (= PostgreSQL schema) "smartmonitoring". A fresh deployment has neither the
# schema nor the tables, so the front end shows no menus and no login form.
#
# This script:
#
#   1. creates the storage "smartmonitoring" if the schema does not exist,
#   2. applies the presets that the deployed front end ships in
#      data/admin/presets/base.json:
#
#        Base tables                 tbl_ootype, tbl_metatype, tbl_datatype,
#                                    tbl_observedobject, tbl_location,
#                                    tbl_location_join_oo
#        Navigationsmenü             tbl_navigationroute + 50 menu rows
#        Admin Funktionsverwaltung   tbl_systemconfiguration + 51 feature rows
#
# The presets are fetched from the running application, so the schema always
# matches the deployed WAR. Everything is idempotent: existing tables and
# non-empty tables are skipped, so the script can be re-run after a partial
# bootstrap.
#
# Requirement: the stack is running (./scripts/up.sh) and the front end is
# deployed, because the preset file is read from there.
#
# Requirements on the host: bash, curl, jq, docker compose.
set -euo pipefail

cd "$(dirname "$0")/.."

BASE_URL="http://localhost:${SMARTDATAJOBS_HTTP_PORT:-8080}"
SMARTDATA_URL="$BASE_URL/SmartData/smartdata"
STORAGE="${SMARTMONITORING_STORAGE:-smartmonitoring}"
FRONTEND_CONTEXT="${SMARTMONITORINGFRONTEND_CONTEXT:-SmartMonitoringFrontend}"
PRESETS_URL="$BASE_URL/$FRONTEND_CONTEXT/data/admin/presets/base.json"

DB_NAME="${SMARTUSER_DB_NAME:-smartuser}"
DB_USER="${SMARTUSER_DB_USER:-smartuser}"

for cmd in curl jq docker; do
    command -v "$cmd" >/dev/null 2>&1 || {
        echo "error: '$cmd' is required but not installed." >&2
        exit 1
    }
done

if ! [[ "$STORAGE" =~ ^[A-Za-z_][A-Za-z0-9_]*$ ]]; then
    echo "error: invalid storage name '$STORAGE'." >&2
    exit 1
fi

psql_value() {
    # </dev/null: docker compose exec would otherwise consume the stdin of the
    # while-read loops that call this function, silently truncating the preset
    # list to its first entry.
    docker compose exec -T smartuser-db \
        psql -U "$DB_USER" -d "$DB_NAME" -tAc "$1" </dev/null
}

# ---------------------------------------------------------------- SmartData up
echo "Waiting for SmartData to answer..."
smartdata_up=0
for _ in $(seq 1 60); do
    if curl -fsS -o /dev/null "$SMARTDATA_URL/system/info"; then
        smartdata_up=1
        break
    fi
    sleep 5
done
if [ "$smartdata_up" -ne 1 ]; then
    echo "error: SmartData is not reachable at $SMARTDATA_URL." >&2
    echo "       Start the stack first: ./scripts/up.sh" >&2
    exit 1
fi

# ------------------------------------------------------------------- storage
if [ "$(psql_value "select 1 from information_schema.schemata where schema_name = '$STORAGE'")" = "1" ]; then
    echo "Storage '$STORAGE' already exists."
else
    echo "Creating storage '$STORAGE'..."
    curl -fsS -X POST "$SMARTDATA_URL/storage/create?name=$STORAGE" >/dev/null
fi

# ---------------------------------------------------------------- extensions
# tbl_location.coordinates is geometry(PointZ,4326), so the database needs
# PostGIS. A freshly initialised volume already has it
# (docker/postgres/init-smartuser.sql); this covers volumes that were created
# before the stack used the PostGIS image.
if ! psql_value "create extension if not exists postgis" >/dev/null 2>&1; then
    echo "error: could not enable the PostGIS extension in database '$DB_NAME'." >&2
    echo "       The database image must be postgis/postgis:16-3.4-alpine" >&2
    echo "       (see compose.yaml), because tbl_location uses geometry(PointZ,4326)." >&2
    exit 1
fi

# -------------------------------------------------------------------- presets
if ! presets="$(curl -fsS "$PRESETS_URL")"; then
    echo "error: could not read the presets from $PRESETS_URL" >&2
    echo "       Is the SmartMonitoringFrontend application deployed?" >&2
    exit 1
fi

echo "Applying presets from $PRESETS_URL"

created=0
existing=0
while IFS= read -r preset; do
    name="$(printf '%s' "$preset" | jq -r '.fromName')"
    body="$(printf '%s' "$preset" | jq -c '.body')"

    if ! [[ "$name" =~ ^[A-Za-z_][A-Za-z0-9_]*$ ]]; then
        echo "  ! skipping invalid table name '$name'" >&2
        continue
    fi

    if [ "$(psql_value "select to_regclass('$STORAGE.$name') is not null")" = "t" ]; then
        echo "  = $name (exists)"
        existing=$((existing + 1))
        continue
    fi

    status="$(curl -s -o /dev/null -w '%{http_code}' \
        -X POST -H 'Content-Type: application/json' \
        --data-binary "$body" \
        "$SMARTDATA_URL/collection/$name?storage=$STORAGE")"

    if [ "$status" = "201" ] || [ "$status" = "200" ]; then
        echo "  + $name"
        created=$((created + 1))
    else
        echo "  ! $name failed with HTTP $status" >&2
        exit 1
    fi
done < <(printf '%s' "$presets" | jq -c '.list[] | .collections[]?')

records_added=0
records_skipped=0
while IFS= read -r preset; do
    name="$(printf '%s' "$preset" | jq -r '.fromName')"

    if ! [[ "$name" =~ ^[A-Za-z_][A-Za-z0-9_]*$ ]]; then
        echo "  ! skipping invalid table name '$name'" >&2
        continue
    fi

    # Identity attribute of the table, used to make the seeding idempotent.
    identity="$(printf '%s' "$presets" | jq -r --arg n "$name" '
        [ .list[] | .collections[]? | select(.fromName == $n)
          | .body.attributes[] | select(.isIdentity == true) | .name ][0] // "id"')"
    if ! [[ "$identity" =~ ^[A-Za-z_][A-Za-z0-9_]*$ ]]; then
        echo "  ! skipping $name: unexpected identity attribute '$identity'" >&2
        continue
    fi

    added=0
    skipped=0
    # One record at a time: a single bad record (for example a duplicate id in
    # the preset data) must not abort the whole seed and leave a partial table.
    while IFS= read -r record; do
        id="$(printf '%s' "$record" | jq -r --arg a "$identity" '.[$a] // empty')"

        if [[ "$id" =~ ^[0-9]+$ ]] \
            && [ "$(psql_value "select count(*) from $STORAGE.$name where $identity = $id")" != "0" ]; then
            skipped=$((skipped + 1))
            continue
        fi

        status="$(curl -s -o /dev/null -w '%{http_code}' \
            -X POST -H 'Content-Type: application/json' \
            --data-binary "[$record]" \
            "$SMARTDATA_URL/records/$name?storage=$STORAGE") "

        if [ "${status% }" = "201" ] || [ "${status% }" = "200" ]; then
            added=$((added + 1))
        else
            echo "  ! $name: record $identity=$id failed with HTTP ${status% }" >&2
            exit 1
        fi
    done < <(printf '%s' "$preset" | jq -c '.body[]')

    echo "  + $name (added: $added, already present: $skipped)"
    records_added=$((records_added + added))
    records_skipped=$((records_skipped + skipped))
done < <(printf '%s' "$presets" | jq -c '.list[] | .data[]?')

# --------------------------------------------------------------- login switch
# Every feature switch ships with active=false, including func_userlogin. The
# start page gates its login form on that row, so the stack would have no way to
# log in. Enabling it is a deliberate deployment decision (locals SmartUser login
# is the main entry point); set SMARTMONITORING_ENABLE_USERLOGIN=false to keep
# the shipped state and activate features in sites/admin/functions.html.
if [ "${SMARTMONITORING_ENABLE_USERLOGIN:-true}" = "true" ]; then
    switch="$(psql_value "select id, active from $STORAGE.tbl_systemconfiguration where ckey = 'func_userlogin'" || true)"
    if [ -z "$switch" ]; then
        echo "  ! func_userlogin switch not found - the login form stays hidden" >&2
    else
        login_id="${switch%%|*}"
        login_state="${switch##*|}"
        if [ "$login_state" = "t" ]; then
            echo "  = func_userlogin already active"
        else
            status="$(curl -s -o /dev/null -w '%{http_code}' \
                -X PUT -H 'Content-Type: application/json' \
                --data-binary '{"active":true}' \
                "$SMARTDATA_URL/records/tbl_systemconfiguration/$login_id?storage=$STORAGE")"
            if [ "$status" = "200" ]; then
                echo "  + func_userlogin activated (login form on the start page)"
            else
                echo "  ! could not activate func_userlogin (HTTP $status)" >&2
                exit 1
            fi
        fi
    fi
fi

echo
echo "Done. Tables created: $created (already present: $existing),"
echo "seed rows inserted: $records_added (already present: $records_skipped)."
echo
echo "SmartMonitoring: http://localhost:${SMARTDATAJOBS_HTTP_PORT:-8080}/$FRONTEND_CONTEXT/"
echo "Log in with admin / admin (from ./scripts/init-smartuser.sh)."
echo
echo "Other feature switches (dashboard, maps, labelling, ...) ship inactive;"
echo "activate them in $FRONTEND_CONTEXT/sites/admin/functions.html."
echo
echo "Optional PostgreSQL views for the hierarchy/map pages:"
echo "  docker compose exec -T smartuser-db psql -U $DB_USER -d $DB_NAME \\"
echo "      -c 'set search_path to $STORAGE' \\"
echo "      -f - < ../$FRONTEND_CONTEXT/docs/setup/view_oo_hierarchy.sql"
