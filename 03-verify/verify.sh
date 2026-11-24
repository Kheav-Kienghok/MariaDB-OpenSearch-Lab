#!/usr/bin/env bash
# Run from any host that can reach OpenSearch.
. "$(dirname "$0")/../common.sh"
API="https://$OS_HOST:$OS_PORT"
C=(-sk -u "admin:$OS_ADMIN_PASSWORD" -H 'Content-Type: application/json')
agg() { # index query
  curl "${C[@]}" "$API/$1/_search" -d "{\"size\":0,\"query\":{\"bool\":{\"filter\":[{\"range\":{\"@timestamp\":{\"gte\":\"now-5m\"}}},{\"query_string\":{\"query\":\"$2\"}}]}},
   \"aggs\":{\"n\":{\"terms\":{\"field\":\"node_name\"}}}}" \
   | python3 -c 'import sys,json; d=json.load(sys.stdin); print("   ", {b["key"]:b["doc_count"] for b in d.get("aggregations",{}).get("n",{}).get("buckets",[])} or "NO DATA")'
}
echo "== cluster health"; curl "${C[@]}" "$API/_cluster/health?pretty" | grep -E 'status|number_of_nodes'
echo "== indices";        curl "${C[@]}" "$API/_cat/indices/mariadb-*,metricbeat-*,heartbeat-*?v"
echo "== last 5 min, docs per node"
echo " logs (error/slow/audit):";   agg 'mariadb-*'    '*'
echo " heartbeat ping:";            agg 'heartbeat-*'  'check:host_ping'
echo " heartbeat mariadb port:";    agg 'heartbeat-*'  'check:mariadb_port'
echo " mysql status metrics:";      agg 'metricbeat-*' 'metricset.name:status'
echo " galera_status metrics:";     agg 'metricbeat-*' 'metricset.name:galera_status'
echo "== field names the dashboard uses (should be non-empty)"
for f in mysql.status.threads.connected mysql.status.command.select mysql.galera_status.cluster.size mysql.galera_status.flow_ctl.paused up_value; do
  N=$(curl -s "${C[@]}" "$API/metricbeat-*,heartbeat-*/_count" -d "{\"query\":{\"exists\":{\"field\":\"$f\"}}}" | python3 -c 'import sys,json;print(json.load(sys.stdin).get("count","err"))')
  printf "   %-45s %s\n" "$f" "$N"
done
