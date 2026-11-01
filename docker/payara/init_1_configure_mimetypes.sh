#!/bin/bash
#
# Server-wide MIME mappings for the static projects served from the domain
# docroot (/SWAC/, /SWACdoc/, /SmartMonitoringFrontend/).
#
# SWAC, SWACdoc and SmartMonitoringFrontend are no longer deployed as WARs, so
# the mappings their WEB-INF/web.xml used to carry are gone with them. This
# script adds them to Payara's config/default-web.xml, which is the descriptor
# the default servlet of the docroot uses.
#
# Payara's table already covers html, css, js, json, svg and ico. Missing, and
# therefore added here: woff, woff2 (SWAC fonts), webmanifest/manifest (the
# front end's PWA manifest) and wasm (SWAC's WebAssembly assets).
#
# The entrypoint sources every /opt/payara/scripts/init_* file in name order, so
# this runs after init_0_configure_databases.sh and before
# init_1_generate_deploy_commands.sh. Use return 0, not exit 0, when skipping.
#
# Idempotent: every mapping is guarded by an existence check, so a restart on the
# same domain does not duplicate entries.

DEFAULT_WEB_XML="${PAYARA_DIR}/glassfish/domains/${DOMAIN_NAME}/config/default-web.xml"

if [ ! -f "$DEFAULT_WEB_XML" ]; then
    echo "init_1_configure_mimetypes: $DEFAULT_WEB_XML not found – skipping" >&2
    return 0
fi

# Each entry: extension:mime-type
MAPPINGS=(
    "woff:font/woff"
    "woff2:font/woff2"
    "webmanifest:application/manifest+json"
    "manifest:application/manifest+json"
    "wasm:application/wasm"
)

added=0
for mapping in "${MAPPINGS[@]}"; do
    ext="${mapping%%:*}"
    mime="${mapping##*:}"

    if grep -q "<extension>$ext</extension>" "$DEFAULT_WEB_XML"; then
        continue
    fi

    # Insert the mapping before the closing </web-app> tag.
    tmp="$(mktemp)"
    awk -v ext="$ext" -v mime="$mime" '
        !done && /^<\/web-app>/ {
            print "  <mime-mapping>"
            print "    <extension>" ext "</extension>"
            print "    <mime-type>" mime "</mime-type>"
            print "  </mime-mapping>"
            done = 1
        }
        { print }
    ' "$DEFAULT_WEB_XML" > "$tmp" && mv "$tmp" "$DEFAULT_WEB_XML"

    if ! grep -q "<extension>$ext</extension>" "$DEFAULT_WEB_XML"; then
        echo "init_1_configure_mimetypes: could not add $ext" >&2
        continue
    fi
    added=$((added + 1))
done

echo "init_1_configure_mimetypes: $added MIME mapping(s) added"
