#!/bin/bash
#
# Runs before init_1_generate_deploy_commands.sh.
#
# Creates the JTA data sources that the applications expect:
#
#   jdbc/SmartUser  -> SmartUser persistence unit (schema smartuser)
#   jdbc/SmartData  -> SmartData storage access (schemas public, smartmonitoring)
#
# Both resources are created here, before Payara appends its automatic
# deployment commands to the post-boot command file.
#
# This file is sourced by the Payara container entrypoint, so use return
# instead of exit when skipping the configuration.

# Defaults mirror compose.yaml (the provided PostgreSQL server); compose sets
# every one of these explicitly.
DB_HOST="${SMARTUSER_DB_HOST:-frodermann.me}"
DB_PORT="${SMARTUSER_DB_PORT:-5432}"
DB_NAME="${SMARTUSER_DB_NAME:-smartuser}"
DB_USER="${SMARTUSER_DB_USER:-webengineering_group}"
DB_PASSWORD="${SMARTUSER_DB_PASSWORD:?SMARTUSER_DB_PASSWORD is not set}"

# The provided server rejects unencrypted connections (pg_hba: "no encryption"),
# so the JDBC URL asks for TLS.
DB_SSLMODE="${SMARTUSER_DB_SSLMODE:-require}"
DB_PARAMS=""
if [ -n "$DB_SSLMODE" ]; then
    DB_PARAMS="?sslmode=${DB_SSLMODE}"
fi

# SmartData uses the same PostgreSQL server as SmartUser but its own database.
SMARTDATA_DB_NAME="${SMARTDATA_DB_NAME:-$DB_NAME}"

DOMAIN_XML="${PAYARA_DIR}/glassfish/domains/${DOMAIN_NAME}/config/domain.xml"

# The post-boot command file lives in the container filesystem and therefore
# survives a container restart, while init_1_generate_deploy_commands.sh only
# appends to it. Truncate it here, otherwise the resource commands of the
# previous start are replayed and fail with "already exists".
if [ -n "$POSTBOOT_COMMANDS" ] && [ -f "$POSTBOOT_COMMANDS" ]; then
    : > "$POSTBOOT_COMMANDS"
fi

# asadmin parses --property as a colon separated list of name=value pairs and
# rejects an unescaped ':' or '=' inside a value. A single backslash escapes
# both ('\:' and '\='), and one backslash level is what survives the trip
# through $POSTBOOT_COMMANDS. Verified against payara/server-full:6.2025.11-jdk17
# with a password containing ':?>=&$*<' - without the escaping
# create-jdbc-connection-pool fails with
#   IllegalArgumentException: Invalid property syntax, missing property value: ...
# and no jdbc/SmartUser or jdbc/SmartData resource is created at all.
prop_escape() {
    local value="$1"
    value="${value//\\/\\\\}"
    value="${value//:/\\:}"
    value="${value//=/\\=}"
    printf '%s' "$value"
}

pool_properties() {
    local database="$1"
    local url="jdbc:postgresql://${DB_HOST}:${DB_PORT}/${database}${DB_PARAMS}"
    echo "user=$(prop_escape "$DB_USER"):password=$(prop_escape "$DB_PASSWORD"):url=$(prop_escape "$url"):driverClass=org.postgresql.Driver"
}

append_resource() {
    POOL_NAME="$1"
    JNDI_NAME="$2"
    DATABASE="$3"

    # Do not add duplicate resources when an existing domain is restarted.
    if [ -f "$DOMAIN_XML" ] && grep -q "$JNDI_NAME" "$DOMAIN_XML"; then
        return 0
    fi

    cat >> "$POSTBOOT_COMMANDS" <<EOF
create-jdbc-connection-pool --datasourceclassname org.postgresql.ds.PGSimpleDataSource --restype javax.sql.DataSource --property $(pool_properties "$DATABASE") ${POOL_NAME}
create-jdbc-resource --connectionpoolid ${POOL_NAME} ${JNDI_NAME}

EOF
}

append_resource SmartUserPool jdbc/SmartUser "$DB_NAME"
append_resource SmartDataPool jdbc/SmartData "$SMARTDATA_DB_NAME"
