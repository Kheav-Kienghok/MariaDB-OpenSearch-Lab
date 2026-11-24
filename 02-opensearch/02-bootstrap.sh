#!/usr/bin/env bash
# Run on vm4 after install (safe to re-run): users, roles, templates, retention.
. "$(dirname "$0")/../common.sh"; need_root
API="https://localhost:$OS_PORT"
A=(-sk -u "admin:$OS_ADMIN_PASSWORD" -H 'Content-Type: application/json')
PATTERNS='["mariadb-*","metricbeat-*","heartbeat-*"]'

echo "== writer role (Filebeat, Metricbeat, Heartbeat)"
curl "${A[@]}" -X PUT "$API/_plugins/_security/api/roles/beats_writer" -d "{
  \"cluster_permissions\": [\"cluster_monitor\",\"cluster:admin/ingest/pipeline/put\",\"cluster:admin/ingest/pipeline/get\",\"indices:admin/template/get\"],
  \"index_permissions\": [{
    \"index_patterns\": $PATTERNS,
    \"allowed_actions\": [\"crud\",\"create_index\",\"indices_monitor\",\"indices:admin/mapping/put\",\"indices:admin/auto_create\"]
  }]
}"; echo
curl "${A[@]}" -X PUT "$API/_plugins/_security/api/internalusers/$FILEBEAT_USER" \
  -d "{\"password\":\"$FILEBEAT_PASSWORD\",\"backend_roles\":[],\"description\":\"Beats shipper\"}"; echo
curl "${A[@]}" -X PUT "$API/_plugins/_security/api/rolesmapping/beats_writer" -d "{\"users\":[\"$FILEBEAT_USER\"]}"; echo

echo "== Grafana read-only role"
curl "${A[@]}" -X PUT "$API/_plugins/_security/api/roles/grafana_ro" -d "{
  \"cluster_permissions\": [\"cluster_composite_ops_ro\"],
  \"index_permissions\": [{
    \"index_patterns\": $PATTERNS,
    \"allowed_actions\": [\"read\",\"indices_monitor\",\"indices:admin/get\",\"indices:admin/mappings/get\",\"indices:admin/resolve/index\"]
  }]
}"; echo
curl "${A[@]}" -X PUT "$API/_plugins/_security/api/internalusers/$GRAFANA_READER_USER" \
  -d "{\"password\":\"$GRAFANA_READER_PASSWORD\",\"backend_roles\":[],\"description\":\"Grafana datasource\"}"; echo
curl "${A[@]}" -X PUT "$API/_plugins/_security/api/rolesmapping/grafana_ro" -d "{\"users\":[\"$GRAFANA_READER_USER\"]}"; echo

DYN='"dynamic_templates":[{"strings_as_keyword":{"match_mapping_type":"string","mapping":{"type":"keyword","ignore_above":4096}}}]'
echo "== templates"
curl "${A[@]}" -X PUT "$API/_index_template/mariadb" -d "{
  \"index_patterns\":[\"mariadb-*\"], \"priority\":200,
  \"template\":{\"settings\":{\"number_of_shards\":1,\"number_of_replicas\":0},
    \"mappings\":{$DYN,\"properties\":{\"@timestamp\":{\"type\":\"date\"},\"message\":{\"type\":\"text\"}}}}}"; echo
curl "${A[@]}" -X PUT "$API/_index_template/dbmon-metrics" -d "{
  \"index_patterns\":[\"metricbeat-*\",\"heartbeat-*\"], \"priority\":200,
  \"template\":{\"settings\":{\"number_of_shards\":1,\"number_of_replicas\":0},
    \"mappings\":{$DYN,\"properties\":{\"@timestamp\":{\"type\":\"date\"}}}}}"; echo

policy() { # name days patterns
  curl "${A[@]}" -X PUT "$API/_plugins/_ism/policies/$1" -d "{
   \"policy\":{\"description\":\"Delete after $2 days\",\"default_state\":\"hot\",
    \"states\":[{\"name\":\"hot\",\"actions\":[],\"transitions\":[{\"state_name\":\"delete\",\"conditions\":{\"min_index_age\":\"$2d\"}}]},
                {\"name\":\"delete\",\"actions\":[{\"delete\":{}}],\"transitions\":[]}],
    \"ism_template\":[{\"index_patterns\":$3,\"priority\":100}]}}"; echo
}
echo "== retention"
policy mariadb-retention "$RETENTION_DAYS" '["mariadb-*"]'
policy dbmon-metrics-retention "$METRICS_RETENTION_DAYS" '["metricbeat-*","heartbeat-*"]'
echo Done.
