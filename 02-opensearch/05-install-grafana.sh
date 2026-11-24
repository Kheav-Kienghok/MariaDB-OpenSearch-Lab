#!/usr/bin/env bash
# Run on vm4: Grafana + OpenSearch plugin + provisioned data sources + dashboard.
. "$(dirname "$0")/../common.sh"; need_root
export DEBIAN_FRONTEND=noninteractive

apt-get install -y apt-transport-https wget gnupg
mkdir -p /etc/apt/keyrings
wget -q -O - https://apt.grafana.com/gpg.key | gpg --dearmor --yes -o /etc/apt/keyrings/grafana.gpg
echo "deb [signed-by=/etc/apt/keyrings/grafana.gpg] https://apt.grafana.com stable main" > /etc/apt/sources.list.d/grafana.list
apt-get update -y && apt-get install -y grafana

# Grafana 13 package: grafana-cli needs an explicit homepath, a readable cwd, and must run as the grafana user
gcli() {
  if grafana cli --help >/dev/null 2>&1; then BIN="grafana cli"; else BIN="grafana-cli"; fi
  ( cd /usr/share/grafana && runuser -u grafana -- $BIN --homepath /usr/share/grafana --config /etc/grafana/grafana.ini "$@" )
}
mkdir -p /var/lib/grafana/plugins
chown -R grafana:grafana /var/lib/grafana
gcli plugins install grafana-opensearch-datasource

SKIP=$GRAFANA_TLS_SKIP_VERIFY
ds() { # uid name index
cat <<CFG
  - name: $2
    uid: $1
    type: grafana-opensearch-datasource
    access: proxy
    url: https://localhost:$OS_PORT
    basicAuth: true
    basicAuthUser: $GRAFANA_READER_USER
    editable: false
    jsonData:
      database: "$3"
      timeField: "@timestamp"
      flavor: opensearch
      version: "2.11.0"
      pplEnabled: false
      tlsSkipVerify: $SKIP
      logMessageField: message
      logLevelField: log.level
      maxConcurrentShardRequests: 5
    secureJsonData:
      basicAuthPassword: "$GRAFANA_READER_PASSWORD"
CFG
}
{ echo "apiVersion: 1"; echo "datasources:"
  ds os-metrics   "OS MariaDB Metrics"   "metricbeat-*"
  ds os-heartbeat "OS MariaDB Uptime"    "heartbeat-*"
  ds os-logs      "OS MariaDB Logs"      "mariadb-*"
} > /etc/grafana/provisioning/datasources/opensearch.yaml
chown root:grafana /etc/grafana/provisioning/datasources/opensearch.yaml
chmod 640 /etc/grafana/provisioning/datasources/opensearch.yaml

cat > /etc/grafana/provisioning/dashboards/mariadb.yaml <<CFG
apiVersion: 1
providers:
  - name: mariadb
    folder: MariaDB
    type: file
    allowUiUpdates: false
    options:
      path: /var/lib/grafana/dashboards
CFG
mkdir -p /var/lib/grafana/dashboards
cp "$ROOT"/grafana/dashboards/*.json /var/lib/grafana/dashboards/
chown -R grafana:grafana /var/lib/grafana/dashboards

systemctl daemon-reload
systemctl enable --now grafana-server
for i in $(seq 1 30); do curl -s localhost:3000/api/health | grep -q ok && break; sleep 2; done
gcli admin reset-admin-password "$GRAFANA_ADMIN_PASSWORD" >/dev/null
systemctl restart grafana-server
echo "Grafana: http://<vm4-ip>:3000   (admin / GRAFANA_ADMIN_PASSWORD)"
echo "Dashboard: MariaDB -> 'MariaDB Galera - Production Overview'"
echo "Production: put Grafana behind nginx/HTTPS or a VPN; do not expose :3000 publicly."
