#!/bin/env bash
# Part of the SW360 Portal Project.
# SPDX-License-Identifier: EPL-2.0

set -o errexit -o nounset -o pipefail

# Load Docker secrets in a CRLF-safe way: secrets files checked out with
# Windows line endings would otherwise leave a trailing carriage return
# in sourced values (e.g. COUCHDB_PASSWORD="sw360fossie\r"), which CouchDB
# rejects with "Name or password is incorrect" and eventually locks the
# account for (see eclipse-sw360/sw360#4558).
load_secrets_file() {
  if [ -f "$1" ]; then
    # shellcheck disable=SC1090
    source <(tr -d '\r' < "$1")
  fi
}

# Export sourced secrets so envsubst can see them when generating configs.
set -o allexport
load_secrets_file "/run/secrets/COUCHDB_SECRETS"
load_secrets_file "/run/secrets/SW360_SECRETS"
set +o allexport

mkdir -p /etc/sw360/authorization /etc/sw360/rest

# Seed JWT signing keystore with explicit source precedence:
# 1) Docker secret JWT_KEYSTORE (operator override)
# 2) Existing persisted /etc/sw360/jwt-keystore.jks
# 3) Bundled fallback /app/sw360/jwt-keystore.jks
if [ -f /run/secrets/JWT_KEYSTORE ]; then
  cp /run/secrets/JWT_KEYSTORE /etc/sw360/jwt-keystore.jks
  chmod 600 /etc/sw360/jwt-keystore.jks
  echo "Seeded /etc/sw360/jwt-keystore.jks from Docker secret JWT_KEYSTORE."
elif [ -f /etc/sw360/jwt-keystore.jks ]; then
  echo "Using existing /etc/sw360/jwt-keystore.jks from persisted volume."
elif [ -f /app/sw360/jwt-keystore.jks ]; then
  cp /app/sw360/jwt-keystore.jks /etc/sw360/jwt-keystore.jks
  chmod 600 /etc/sw360/jwt-keystore.jks
  echo "Seeded /etc/sw360/jwt-keystore.jks from bundled fallback."
else
  echo "WARNING: No JWT keystore found at /etc/sw360/jwt-keystore.jks and no" \
       "Docker secret JWT_KEYSTORE or bundled fallback at /app/sw360/jwt-keystore.jks." >&2
  echo "WARNING: Authorization server startup may fail if no classpath fallback is available." >&2
fi

# Seed the S/MIME e-mail signing keystore from an optional Docker secret.
# Note that seeding alone does not enable signing: EMAIL_PROPERTIES_SIGNING_KEYSTORE_PATH
# and EMAIL_PROPERTIES_SIGNING_KEYSTORE_PASSWORD must be set as well.
if [ -f /run/secrets/SMIME_KEYSTORE ]; then
  cp /run/secrets/SMIME_KEYSTORE /etc/sw360/smime-keystore.p12
  chmod 600 /etc/sw360/smime-keystore.p12
  echo "Seeded /etc/sw360/smime-keystore.p12 from Docker secret SMIME_KEYSTORE."
fi

# Write configuration from environment variables
/usr/bin/envsubst < /app/sw360/couchdb.properties.template > /etc/sw360/couchdb.properties
/usr/bin/envsubst < /app/sw360/etc_sw360/authorization/application.yml.template > /etc/sw360/authorization/application.yml
/usr/bin/envsubst < /app/sw360/etc_sw360/rest/application.yml.template > /etc/sw360/rest/application.yml
/usr/bin/envsubst < /app/sw360/etc_sw360/sw360.properties.template > /etc/sw360/sw360.properties
/usr/bin/envsubst < /app/sw360/manager/tomcat-users.xml > "$CATALINA_HOME"/conf/tomcat-users.xml

# Wait for DB
test_for_couchdb() {
  curl -s "$COUCHDB_URL"/_up | grep -q '"status":"ok"'
  return $?
}
until test_for_couchdb; do
  >&2 echo "CouchDB is unavailable - sleeping"
  sleep 1
done

# Start Tomcat
echo
echo 'SW360 configuration complete; Starting up...'
echo
"$CATALINA_HOME"/bin/catalina.sh run
