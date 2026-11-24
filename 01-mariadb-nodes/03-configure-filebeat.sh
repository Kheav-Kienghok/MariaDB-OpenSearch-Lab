#!/usr/bin/env bash
# Configures Filebeat on a DB node and starts it.
. "$(dirname "$0")/../common.sh"; need_root

NODE_NAME="$(hostname -s)"

# CA for OpenSearch TLS: copy vm4:/etc/opensearch/root-ca.pem to ./certs/root-ca.pem
mkdir -p /etc/filebeat/certs
if [ -f "$ROOT/certs/root-ca.pem" ]; then
  install -m 0644 "$ROOT/certs/root-ca.pem" /etc/filebeat/certs/ca.crt
  SSL_BLOCK='  ssl.certificate_authorities: ["/etc/filebeat/certs/ca.crt"]
  ssl.verification_mode: certificate'
else
  echo "WARN: certs/root-ca.pem not found -> TLS verification DISABLED (testing only)"
  SSL_BLOCK='  ssl.verification_mode: none'
fi

# password in keystore
filebeat keystore create --force >/dev/null
printf '%s' "$FILEBEAT_PASSWORD" | filebeat keystore add OS_PASSWORD --stdin --force

# mysql module (error + slow log)
filebeat modules enable mysql >/dev/null
cat > /etc/filebeat/modules.d/mysql.yml <<CFG
- module: mysql
  error:
    enabled: true
    var.paths: ["$LOG_DIR/mariadb.log*"]
  slowlog:
    enabled: true
    var.paths: ["$LOG_DIR/mariadb-slow.log*"]
CFG

# main config
cat > /etc/filebeat/filebeat.yml <<CFG
filebeat.config.modules:
  path: \${path.config}/modules.d/*.yml
  reload.enabled: false

# Audit log is not covered by the mysql module -> plain input + dissect
filebeat.inputs:
  - type: log
    paths: ["$LOG_DIR/mariadb-audit.log"]
    fields:
      log_type: mariadb_audit
    fields_under_root: true
    processors:
      - dissect:
          field: message
          tokenizer: "%{ts},%{serverhost},%{user},%{client_host},%{connection_id},%{query_id},%{operation},%{database},%{object}"
          target_prefix: "mariadb_audit"
          ignore_failure: true

fields:
  cluster: "$CLUSTER_NAME"
  node_name: "$NODE_NAME"
  environment: "$ENVIRONMENT"
fields_under_root: true

processors:
  - add_host_metadata: ~

output.elasticsearch:          # the OSS build talks to OpenSearch through this output
  hosts: ["https://$OS_HOST:$OS_PORT"]
  username: "$FILEBEAT_USER"
  password: "\${OS_PASSWORD}"
  index: "mariadb-%{+yyyy.MM.dd}"
$SSL_BLOCK

# OpenSearch has ISM instead of ILM; template is created by 02-bootstrap.sh
setup.ilm.enabled: false
setup.template.enabled: false
setup.template.name: "mariadb"
setup.template.pattern: "mariadb-*"
setup.dashboards.enabled: false

# Beats 7.12 ship an old seccomp filter that blocks clone3() used by glibc 2.39 (Ubuntu 24.04)
seccomp.enabled: false
logging.level: info
CFG
chmod 600 /etc/filebeat/filebeat.yml

filebeat test config -e
filebeat test output
systemctl enable --now filebeat
sleep 3; systemctl --no-pager status filebeat | head -5
echo ">> Watch:  journalctl -u filebeat -f"
