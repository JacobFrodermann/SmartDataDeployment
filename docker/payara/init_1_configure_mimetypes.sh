#!/bin/bash
#
# Payara's config/default-web.xml, which is what the static files served from
# the domain docroot (/SWAC/ and /SmartMonitoringFrontend/) use, lacks MIME
# types for a few assets those applications need: woff/woff2 fonts and the PWA
# webmanifest.  Their WARs used to map these in WEB-INF/web.xml; with the
# docroot mount the mapping has to be server-wide.
#
# svg, json and ico are mapped by Payara already and are not repeated here.
# Every mapping is guarded by an existence check, so this is idempotent.
#
# This file is sourced by the Payara container entrypoint, so use return 0
# instead of exit 0 when skipping.

DEFAULT_WEB_XML="${PAYARA_DIR}/glassfish/domains/${DOMAIN_NAME}/config/default-web.xml"

if [ ! -f "$DEFAULT_WEB_XML" ]; then
    echo "init_1_configure_mimetypes: $DEFAULT_WEB_XML not found – skipping" >&2
    return 0
fi

# Each line: extension:mime-type
MAPPINGS=(
    "woff:font/woff"
    "woff2:font/woff2"
    "webmanifest:application/manifest+json"
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
