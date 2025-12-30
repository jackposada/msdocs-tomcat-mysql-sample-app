#!/usr/bin/env bash
set -euo pipefail

CERT_THUMBPRINT="3AA47D96BF925400CD5DC5287AE62FE2AA770162"
CERT_PATH="/var/ssl/certs/${CERT_THUMBPRINT}.crt"
ALIAS_NAME="combine-ca"
STORE_PASS="changeit"
TRUSTSTORE_PATH="${JAVA_HOME}/lib/security/cacerts"

if [ ! -f "${CERT_PATH}" ]; then
  echo "[init-ca] Expected cert at ${CERT_PATH} not found. Ensure WEBSITE_LOAD_CERTIFICATES includes ${CERT_THUMBPRINT}." >&2
  exit 1
fi

# Import the Combine CA into the JVM truststore if not already present.
if ! keytool -list -keystore "${TRUSTSTORE_PATH}" -storepass "${STORE_PASS}" -alias "${ALIAS_NAME}" >/dev/null 2>&1; then
  echo "[init-ca] Importing Combine CA into JVM truststore..."
  keytool -importcert -noprompt -trustcacerts \
    -alias "${ALIAS_NAME}" \
    -file "${CERT_PATH}" \
    -keystore "${TRUSTSTORE_PATH}" \
    -storepass "${STORE_PASS}"
else
  echo "[init-ca] Combine CA already present in JVM truststore."
fi

# Let the platform start Tomcat normally after this script finishes.
