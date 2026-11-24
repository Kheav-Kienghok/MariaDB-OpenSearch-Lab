#!/usr/bin/env bash
# Run on vm4 (or any host OUTSIDE the DB nodes): up/down probes for every node.
#  - ICMP ping      -> is the host/VM alive?
#  - TCP :3306      -> is MariaDB accepting connections?
. "$(dirname "$0")/../common.sh"; need_root

curl -fL "https://artifacts.elastic.co/downloads/beats/heartbeat/heartbeat-oss-${FILEBEAT_VERSION}-amd64.deb" -o /tmp/hb.deb
dpkg -i /tmp/hb.deb

heartbeat keystore create --force >/dev/null
printf '%s' "$FILEBEAT_PASSWORD" | heartbeat keystore add OS_PASSWORD --stdin --force

MON=""
for pair in $DB_NODES; do
  N="${pair%%=*}"; IP="${pair##*=}"
  MON+="
  - type: icmp
    id: ${N}-ping
    name: \"${N} host (ping)\"
    hosts: [\"${IP}\"]
    schedule: \"@every ${CHECK_INTERVAL}\"
    timeout: 3s
    fields: { node_name: \"${N}\", check: host_ping, cluster: \"${CLUSTER_NAME}\" }
    fields_under_root: true
  - type: tcp
    id: ${N}-mariadb
    name: \"${N} MariaDB :3306\"
    hosts: [\"${IP}:3306\"]
    schedule: \"@every ${CHECK_INTERVAL}\"
    timeout: 3s
    fields: { node_name: \"${N}\", check: mariadb_port, cluster: \"${CLUSTER_NAME}\" }
    fields_under_root: true"
done

cat > /etc/heartbeat/heartbeat.yml <<CFG
heartbeat.monitors:$MON

# numeric flag so Grafana can show UP/DOWN tiles (1 = up, 0 = down)
processors:
  - script:
      lang: javascript
      source: >
        function process(event) {
          var s = event.Get("monitor.status");
          event.Put("up_value", s === "up" ? 1 : 0);
        }

output.elasticsearch:
  hosts: ["https://localhost:$OS_PORT"]
  username: "$FILEBEAT_USER"
  password: "\${OS_PASSWORD}"
  index: "heartbeat-%{+yyyy.MM.dd}"
  ssl.certificate_authorities: ["/etc/opensearch/root-ca.pem"]
  ssl.verification_mode: certificate

setup.ilm.enabled: false
setup.template.enabled: false
setup.template.name: "heartbeat"
setup.template.pattern: "heartbeat-*"
setup.dashboards.enabled: false
seccomp.enabled: false
CFG
chmod 600 /etc/heartbeat/heartbeat.yml
heartbeat test config -e
heartbeat test output
systemctl enable --now heartbeat
echo ">> journalctl -u heartbeat -f"
