#!/usr/bin/env bash
# Run on EACH DB node: installs Metricbeat OSS, ships MariaDB + Galera + host metrics to OpenSearch.
. "$(dirname "$0")/../common.sh"; need_root
NODE_NAME="$(hostname -s)"

if command -v dpkg >/dev/null; then
  curl -fL "https://artifacts.elastic.co/downloads/beats/metricbeat/metricbeat-oss-${FILEBEAT_VERSION}-amd64.deb" -o /tmp/mb.deb
  dpkg -i /tmp/mb.deb
else
  curl -fL "https://artifacts.elastic.co/downloads/beats/metricbeat/metricbeat-oss-${FILEBEAT_VERSION}-x86_64.rpm" -o /tmp/mb.rpm
  rpm -Uvh --replacepkgs /tmp/mb.rpm
fi

mkdir -p /etc/metricbeat/certs
if [ -f "$ROOT/certs/root-ca.pem" ]; then
  install -m 0644 "$ROOT/certs/root-ca.pem" /etc/metricbeat/certs/ca.crt
  SSL_BLOCK='  ssl.certificate_authorities: ["/etc/metricbeat/certs/ca.crt"]
  ssl.verification_mode: certificate'
else
  echo "WARN: certs/root-ca.pem missing -> TLS verification DISABLED (testing only)"
  SSL_BLOCK='  ssl.verification_mode: none'
fi

metricbeat keystore create --force >/dev/null
printf '%s' "$FILEBEAT_PASSWORD"  | metricbeat keystore add OS_PASSWORD    --stdin --force
printf '%s' "$MB_MYSQL_PASSWORD"  | metricbeat keystore add MYSQL_PASSWORD --stdin --force

metricbeat modules enable mysql system >/dev/null
cat > /etc/metricbeat/modules.d/mysql.yml <<CFG
- module: mysql
  metricsets: ["status", "galera_status"]
  period: $CHECK_INTERVAL
  hosts: ["$MB_MYSQL_USER:\${MYSQL_PASSWORD}@tcp(127.0.0.1:3306)/"]
CFG
cat > /etc/metricbeat/modules.d/system.yml <<CFG
- module: system
  period: 30s
  metricsets: ["cpu", "load", "memory"]
  cpu.metrics: ["percentages", "normalized_percentages"]
CFG

cat > /etc/metricbeat/metricbeat.yml <<CFG
metricbeat.config.modules:
  path: \${path.config}/modules.d/*.yml
  reload.enabled: false

fields:
  cluster: "$CLUSTER_NAME"
  node_name: "$NODE_NAME"
  environment: "$ENVIRONMENT"
fields_under_root: true

processors:
  - add_host_metadata: ~

output.elasticsearch:
  hosts: ["https://$OS_HOST:$OS_PORT"]
  username: "$FILEBEAT_USER"
  password: "\${OS_PASSWORD}"
  index: "metricbeat-%{+yyyy.MM.dd}"
$SSL_BLOCK

setup.ilm.enabled: false
setup.template.enabled: false
setup.template.name: "metricbeat"
setup.template.pattern: "metricbeat-*"
setup.dashboards.enabled: false
# Beats 7.12 ship an old seccomp filter that blocks clone3() used by glibc 2.39 (Ubuntu 24.04)
seccomp.enabled: false
logging.level: info
CFG
chmod 600 /etc/metricbeat/metricbeat.yml

metricbeat test config -e
metricbeat test modules mysql || echo "WARN: mysql module test failed (check 04-db-monitor-user.sh ran)"
metricbeat test output
systemctl enable --now metricbeat
echo ">> journalctl -u metricbeat -f"
