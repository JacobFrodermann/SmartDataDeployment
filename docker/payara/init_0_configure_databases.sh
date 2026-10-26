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

DB_HOST="${SMARTUSER_DB_HOST:-smartuser-db}"
DB_PORT="${SMARTUSER_DB_PORT:-5432}"
DB_NAME="${SMARTUSER_DB_NAME:-smartuser}"
DB_USER="${SMARTUSER_DB_USER:-smartuser}"
DB_PASSWORD="${SMARTUSER_DB_PASSWORD:-smartuser}"

# SmartData uses the same PostgreSQL server and, by default, the same
# database as SmartUser. It does not use the smartuser schema; its storages are
# separate schemas (public and smartmonitoring), so both applications can share
# one database without interfering.
SMARTDATA_DB_NAME="${SMARTDATA_DB_NAME:-$DB_NAME}"

DOMAIN_XML="${PAYARA_DIR}/glassfish/domains/${DOMAIN_NAME}/config/domain.xml"

# The post-boot command file lives in the container filesystem and therefore
# survives a container restart, while init_1_generate_deploy_commands.sh only
# appends to it. Truncate it here, otherwise the resource commands of the
# previous start are replayed and fail with "already exists".
if [ -n "$POSTBOOT_COMMANDS" ] && [ -f "$POSTBOOT_COMMANDS" ]; then
    : > "$POSTBOOT_COMMANDS"
fi

pool_properties() {
    # Colons must be escaped inside the asadmin --property string.
    echo "user=${DB_USER}:password=${DB_PASSWORD}:url=jdbc\\:postgresql\\://${DB_HOST}\\:${DB_PORT}/$1:driverClass=org.postgresql.Driver"
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
