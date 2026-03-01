#!/bin/bash
# build-tle.sh -- Produce a TLE-ready SQL file from the PGXS extension SQL
#
# Usage:
#   ./scripts/build-tle.sh                        # Output to stdout
#   ./scripts/build-tle.sh > /tmp/tle.sql          # Output to file
#
# Then in psql:
#   SELECT pgtle.install_extension(
#     'pg_inferal_relay', '0.1.0',
#     'Consume LDES streams from Inferal Relay',
#     pg_read_file('/tmp/tle.sql')
#   );
#   CREATE EXTENSION pg_inferal_relay SCHEMA inferal_relay;

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
SQL_FILE="$SCRIPT_DIR/../sql/pg_inferal_relay--0.1.0.sql"

if [ ! -f "$SQL_FILE" ]; then
    echo "Error: $SQL_FILE not found" >&2
    exit 1
fi

# Strip schema creation and search_path (TLE handles these via control parameters)
sed '/^CREATE SCHEMA IF NOT EXISTS/d; /^SET search_path/d' "$SQL_FILE"
