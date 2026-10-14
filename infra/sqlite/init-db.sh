#!/bin/sh
# Creates Jamii_db from schema.sql + seed.sql if it doesn't exist (RESET_DB=true recreates it)
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

# MI runs as a non-root user and SQLite needs to write its journal next to the DB
chmod 777 /data
chmod 666 "$DB"
