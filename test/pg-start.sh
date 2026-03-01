#!/bin/bash
set -e

# Set trust auth so any local user can connect as postgres
PG_HBA="/etc/postgresql/$PG_VERSION/main/pg_hba.conf"
echo "local all all trust" > "$PG_HBA"
echo "host all all 127.0.0.1/32 trust" >> "$PG_HBA"
echo "host all all ::1/128 trust" >> "$PG_HBA"
echo "host all all 0.0.0.0/0 md5" >> "$PG_HBA"

# pg_net requires shared_preload_libraries (must be set before start)
PG_CONF="/etc/postgresql/$PG_VERSION/main/postgresql.conf"
echo "shared_preload_libraries = 'pg_net,pg_tle'" >> "$PG_CONF"
echo "listen_addresses = '*'" >> "$PG_CONF"

# Start the PGDG default cluster
su postgres -c "pg_ctlcluster $PG_VERSION main start"
until pg_isready -q; do sleep 0.1; done

# Make pg_inferal_relay available as a proper extension
SHAREDIR=$(su postgres -c "pg_config --sharedir")/extension
cp /repo/pg_inferal_relay.control "$SHAREDIR/"
cp /repo/sql/pg_inferal_relay--0.1.0.sql "$SHAREDIR/"

# Set password for external connections
psql -U postgres --set ON_ERROR_STOP=1 -qc "ALTER USER postgres PASSWORD 'postgres'"

# Install extensions
psql -U postgres --set ON_ERROR_STOP=1 -qc "CREATE EXTENSION pgtap"
psql -U postgres --set ON_ERROR_STOP=1 -qc "CREATE EXTENSION pg_inferal_relay"
psql -U postgres --set ON_ERROR_STOP=1 -qc "CREATE EXTENSION http"
psql -U postgres --set ON_ERROR_STOP=1 -qc "CREATE EXTENSION pg_net"
psql -U postgres --set ON_ERROR_STOP=1 -qc "CREATE EXTENSION dblink"
psql -U postgres --set ON_ERROR_STOP=1 -qc "CREATE EXTENSION pg_tle"
psql -U postgres --set ON_ERROR_STOP=1 -qc "CREATE EXTENSION pg_curl"

# Generate TLE SQL for smoke test (remap schema to avoid conflict with PGXS install)
# Keep CREATE SCHEMA (unlike build-tle.sh which strips it) so the extension owns the schema.
# Strip SET search_path (case-insensitive; not needed with fully-qualified names).
sed '/^[Ss][Ee][Tt] search_path/d; s/inferal_relay\b/inferal_relay_tle/g' \
    /repo/sql/pg_inferal_relay--0.1.0.sql > /tmp/pg_inferal_relay_tle.sql

# Generate copy-paste SQL for smoke test (remap schema to avoid conflict with PGXS install)
# Keep both CREATE SCHEMA and SET search_path (copy-paste mode needs them).
sed 's/inferal_relay\b/inferal_relay_cp/g' \
    /repo/sql/pg_inferal_relay--0.1.0.sql > /tmp/pg_inferal_relay_copypaste.sql

# Run command if provided
if [ $# -gt 0 ]; then
    exec "$@"
fi
