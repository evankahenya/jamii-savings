#!/bin/sh
# One-shot setup: load the masking pipeline into Elasticsearch, then add Kibana data views.
set -e
ES=http://elasticsearch:9200
KB=http://kibana:5601

echo "[elk-init] waiting for Elasticsearch"
until curl -sf "$ES/_cluster/health?wait_for_status=yellow&timeout=5s" >/dev/null; do sleep 5; done

curl -sf -X PUT "$ES/_ingest/pipeline/jamii-logs" -H 'Content-Type: application/json' \
  --data-binary @/observability/jamii-logs-pipeline.json >/dev/null
echo "[elk-init] ingest pipeline jamii-logs loaded"

# traces bypass jamii-logs; Elastic's traces-apm@custom hook masks their labels and URLs
curl -sf -X PUT "$ES/_ingest/pipeline/traces-apm@custom" -H 'Content-Type: application/json' \
  --data-binary @/observability/traces-masking-pipeline.json >/dev/null
echo "[elk-init] ingest pipeline traces-apm@custom loaded"

# keep logs for LOG_RETENTION (default 14d); FULL API logging stores every request/response body
curl -sf -X PUT "$ES/_ilm/policy/filebeat" -H 'Content-Type: application/json' -d "{
  \"policy\": {\"phases\": {
    \"hot\": {\"actions\": {\"rollover\": {\"max_age\": \"1d\", \"max_primary_shard_size\": \"5gb\"}}},
    \"delete\": {\"min_age\": \"${LOG_RETENTION:-14d}\", \"actions\": {\"delete\": {}}}
  }}}" >/dev/null
echo "[elk-init] log retention set to ${LOG_RETENTION:-14d}"

# database calls per request (API -> data service -> query), built from traces by a continuous transform.
# The index and transform are only created if missing; 400/409 on a re-run means they already exist.
code=$(curl -s -o /dev/null -w '%{http_code}' -X PUT "$ES/jamii-db-calls" -H 'Content-Type: application/json' \
  --data-binary @/observability/db-calls-index.json)
echo "[elk-init] index jamii-db-calls -> HTTP $code"
code=$(curl -s -o /dev/null -w '%{http_code}' -X PUT "$ES/_transform/jamii-db-calls" -H 'Content-Type: application/json' \
  --data-binary @/observability/db-calls-transform.json)
echo "[elk-init] transform jamii-db-calls -> HTTP $code"
curl -s -o /dev/null -X POST "$ES/_transform/jamii-db-calls/_start" || true

echo "[elk-init] waiting for Kibana"
until curl -sf "$KB/api/status" | grep -q '"level":"available"'; do sleep 5; done

create_view() {
  # $1 id, $2 name, $3 index pattern; 400 on a re-run means it already exists
  code=$(curl -s -o /dev/null -w '%{http_code}' -X POST "$KB/api/data_views/data_view" \
    -H 'kbn-xsrf: true' -H 'Content-Type: application/json' \
    -d "{\"data_view\":{\"id\":\"$1\",\"name\":\"$2\",\"title\":\"$3\",\"timeFieldName\":\"@timestamp\"}}")
  echo "[elk-init] data view '$2' -> HTTP $code"
}
create_view jamii-logs "Jamii logs" "filebeat-*"
create_view jamii-traces "Jamii traces" "traces-apm*"
create_view jamii-db-calls "Jamii database calls" "jamii-db-calls"

# Jamii dashboards: API overview, errors & troubleshooting, request explorer, integration (MI)
code=$(curl -s -o /dev/null -w '%{http_code}' -X POST "$KB/api/saved_objects/_import?overwrite=true" \
  -H 'kbn-xsrf: true' -F "file=@/observability/kibana-dashboards.ndjson")
echo "[elk-init] Jamii dashboards -> HTTP $code"

# dashboards mix logs and traces panels: a filter on a field one data view lacks is skipped, not "no results"
code=$(curl -s -o /dev/null -w '%{http_code}' -X POST "$KB/internal/kibana/settings" \
  -H 'kbn-xsrf: true' -H 'x-elastic-internal-origin: kibana' -H 'Content-Type: application/json' \
  -d '{"changes":{"courier:ignoreFilterIfFieldNotInIndex":true}}')
echo "[elk-init] filter setting -> HTTP $code"
echo "[elk-init] done"
