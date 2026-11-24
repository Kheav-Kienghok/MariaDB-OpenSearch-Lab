#!/usr/bin/env bash
# Run on vm4 (Ubuntu 24.04). Installs a single-node OpenSearch (no Docker).
. "$(dirname "$0")/../common.sh"; need_root

export DEBIAN_FRONTEND=noninteractive
apt-get update -y && apt-get install -y curl gnupg lsb-release ca-certificates
curl -fsSL https://artifacts.opensearch.org/publickeys/opensearch.pgp | gpg --dearmor --yes -o /usr/share/keyrings/opensearch.gpg
echo "deb [signed-by=/usr/share/keyrings/opensearch.gpg] https://artifacts.opensearch.org/releases/bundle/opensearch/${OS_VERSION_REPO}/apt stable main" \
  > /etc/apt/sources.list.d/opensearch.list
apt-get update -y

echo 'vm.max_map_count=262144' > /etc/sysctl.d/99-opensearch.conf
sysctl -p /etc/sysctl.d/99-opensearch.conf

# 2.12+ requires the initial admin password at install time
env OPENSEARCH_INITIAL_ADMIN_PASSWORD="$OS_ADMIN_PASSWORD" apt-get install -y opensearch

cat > /etc/opensearch/jvm.options.d/heap.options <<CFG
-Xms${OS_HEAP}
-Xmx${OS_HEAP}
CFG

sed -i '/^network.host/d;/^discovery.type/d;/^cluster.name/d' /etc/opensearch/opensearch.yml
cat >> /etc/opensearch/opensearch.yml <<CFG
cluster.name: db-logs
network.host: 0.0.0.0
discovery.type: single-node
# Beats 7.x only skip the removed _type field when the server reports a 7.x version
compatibility.override_main_response_version: true
CFG

systemctl daemon-reload
systemctl enable --now opensearch
echo "Waiting for OpenSearch..."
for i in $(seq 1 60); do
  curl -sk -u "admin:$OS_ADMIN_PASSWORD" "https://localhost:$OS_PORT" >/dev/null && break; sleep 3
done
curl -sk -u "admin:$OS_ADMIN_PASSWORD" "https://localhost:$OS_PORT" | head -12

echo
echo ">> Copy the CA to each DB node's project folder as certs/root-ca.pem:"
echo "   scp /etc/opensearch/root-ca.pem <user>@<db-node>:<project>/certs/root-ca.pem"
echo ">> Firewall: allow TCP $OS_PORT from the 3 DB node IPs only."
