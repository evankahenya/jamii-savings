#!/bin/sh
# Creates the Jamii SQLite database inside the shared volume from schema.sql + seed.sql.
# Runs once per `docker compose up`; does nothing if the DB already exists
# (set RESET_DB=true to rebuild it from scratch).
set -eu

DB=/data/Jamii_db

if [ "${RESET_DB:-false}" = "true" ]; then
  echo "[sqlite-init] RESET_DB=true - deleting existing database"
  rm -f "$DB" "$DB-journal" "$DB-wal" "$DB-shm"
fi

if [ -f "$DB" ]; then
  echo "[sqlite-init] $DB already exists - leaving it alone"
else
  echo "[sqlite-init] creating $DB from schema.sql + seed.sql"
  sqlite3 "$DB" < /sql/schema.sql
  sqlite3 "$DB" < /sql/seed.sql
fi

echo "[sqlite-init] row counts:"
sqlite3 "$DB" "SELECT 'branch', COUNT(*) FROM branch UNION ALL SELECT 'customer', COUNT(*) FROM customer UNION ALL SELECT 'account', COUNT(*) FROM account;"

# MI runs as the non-root 'wso2carbon' user, and SQLite needs write access
# to the folder (for its journal file), so open up permissions on the volume.
chmod 777 /data
chmod 666 "$DB"
