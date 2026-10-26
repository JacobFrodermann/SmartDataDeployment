#!/usr/bin/env bash
#
# One-time SmartUser bootstrap.
#
# Calls GET /SmartUser/smartuser/system/setup, which creates the default
# users, resources and user rights:
#
#   *        anonymous user with CREATE right on the user resource
#   admin    user with "*" right on the "*" resource (password: admin)
#   AppUser  application user with GRANT right (password: SmartPassword1298!)
#
# The endpoint is one-shot: calling it again violates unique constraints and
# returns HTTP 500. This script therefore checks the users table first.
set -euo pipefail

cd "$(dirname "$0")/.."

DB_NAME="${SMARTUSER_DB_NAME:-smartuser}"
DB_USER="${SMARTUSER_DB_USER:-smartuser}"
BASE_URL="http://localhost:${SMARTDATAJOBS_HTTP_PORT:-8080}"

users="$(docker compose exec -T smartuser-db \
    psql -U "$DB_USER" -d "$DB_NAME" -tAc \
    "select count(*) from information_schema.tables where table_schema = 'smartuser' and table_name = 'users'" 2>/dev/null || echo 0)"

if [ "${users:-0}" -eq 0 ]; then
    echo "The smartuser.users table does not exist yet."
    echo "Start the stack first (./scripts/up.sh) and wait until it is healthy."
    exit 1
fi

count="$(docker compose exec -T smartuser-db \
    psql -U "$DB_USER" -d "$DB_NAME" -tAc 'select count(*) from smartuser.users')"

if [ "${count:-0}" -gt 0 ]; then
    echo "SmartUser is already initialised ($count users) - nothing to do."
    exit 0
fi

echo "Running SmartUser setup..."
curl -fsS "${BASE_URL}/SmartUser/smartuser/system/setup"
echo
echo "Done. Default logins:"
echo "  admin    / admin"
echo "  AppUser  / SmartPassword1298!   (application token user)"
