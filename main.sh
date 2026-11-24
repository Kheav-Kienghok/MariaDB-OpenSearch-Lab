#!/usr/bin/env bash
# Run on YOUR WORKSTATION from inside the project folder.
#  0. checks the SSH key (exists, valid, permissions) and that all 4 nodes accept it
#  1. asks for the public IPs of db-node-01/02/03 and the OpenSearch node
#  2. reads each node's private IP over SSH
#  3. generates fresh random passwords and writes ./.env
#  4. sets hostnames db-node-01/02/03 on the DB nodes
#  5. copies the whole project (with .env) to ~/MariaDB-OpenSearch-Lab on all 4 nodes
#  6. fixes Grafana plugin dir permissions + dashboard derivative panels (on the OS node)
set -euo pipefail
KEY="${KEY:-$HOME/.ssh/id_ed25519}"

# ---------- 0a. check the key file ----------
check_key() {
  if [ ! -f "$KEY" ]; then
    echo "ERROR: SSH key not found: $KEY" >&2
    echo "       Set it with:  KEY=/path/to/key ./setup.sh" >&2
    exit 1
  fi
  local perm
  perm=$(stat -c '%a' "$KEY" 2>/dev/null || stat -f '%Lp' "$KEY")   # Linux || macOS
  if [ "$perm" != "600" ] && [ "$perm" != "400" ]; then
    echo "Key permissions are $perm (too open) - fixing to 600"
    chmod 600 "$KEY"
  fi
  # -P "" = try empty passphrase; succeeds only for a valid, unencrypted key
  if ssh-keygen -y -P "" -f "$KEY" >/dev/null 2>&1; then
    echo "Key OK: $KEY ($(ssh-keygen -l -f "$KEY" | awk '{print $4, $2}'))"
  elif ssh-add -l >/dev/null 2>&1; then
    echo "Key $KEY is passphrase-protected or unreadable; ssh-agent is running, will rely on it."
  else
    echo "ERROR: $KEY is invalid or passphrase-protected, and no ssh-agent is running." >&2
    echo "       Run:  eval \$(ssh-agent) && ssh-add $KEY   then try again." >&2
    exit 1
  fi
}
check_key

SSH="ssh -i $KEY -o IdentitiesOnly=yes -o BatchMode=yes -o ConnectTimeout=10 -o StrictHostKeyChecking=accept-new"

ask() {  # ask VAR "prompt"  -> uses env var if already set, otherwise prompts
  local var="$1" prompt="$2" val="${!1:-}"
  while [ -z "$val" ]; do
    read -r -p "$prompt: " val
    val="${val// /}"
  done
  printf -v "$var" '%s' "$val"
}

ask DB1 "Public IP of db-node-01"
ask DB2 "Public IP of db-node-02"
ask DB3 "Public IP of db-node-03"
ask OS  "Public IP of OpenSearch node"

PUB=("$DB1" "$DB2" "$DB3" "$OS")   # order: db1 db2 db3 os
LABELS=(db-node-01 db-node-02 db-node-03 opensearch)
echo "Using: db-node-01=$DB1 db-node-02=$DB2 db-node-03=$DB3 os=$OS"

# ---------- 0b. check every node accepts the key ----------
if [ "${DRY:-0}" != 1 ]; then
  echo "Testing SSH access..."
  fail=0
  for i in 0 1 2 3; do
    if err=$($SSH "ubuntu@${PUB[$i]}" "true" 2>&1); then
      echo "  OK    ${LABELS[$i]} (${PUB[$i]})"
    else
      echo "  FAIL  ${LABELS[$i]} (${PUB[$i]}): ${err##*$'\n'}" >&2
      fail=1
    fi
  done
  if [ "$fail" = 1 ]; then
    echo "ERROR: SSH check failed. Verify the IPs, that port 22 is open in the security group," >&2
    echo "       and that this key is the one the instances were launched with." >&2
    exit 1
  fi
fi

# Grafana host: defaults to the OpenSearch node; override with GRAFANA_PUB=<ip>
GRAFANA_PUB="${GRAFANA_PUB:-$OS}"

priv() { $SSH "ubuntu@$1" "hostname -I | awk '{print \$1}'"; }
if [ "${DRY:-0}" = 1 ]; then P=(172.31.0.1 172.31.0.2 172.31.0.3 172.31.0.4)
else P=(); for ip in "${PUB[@]}"; do P+=("$(priv "$ip")"); done; fi
echo "Private IPs: ${P[*]}"

# special char '-' is required by OpenSearch's password rules; keep alnum+'-' only (safe in shell/JSON/YAML)
gen()  { echo "$(openssl rand -hex 8)Aa-$(openssl rand -hex 4)"; }
gen2() { echo "$(openssl rand -hex 10)Aa1"; }          # letters+digits only (DB account/DSN safe)

cat > .env <<ENV
CLUSTER_NAME=prod_mariadb_cluster
ENVIRONMENT=production

# OpenSearch VM
OS_HOST=${P[3]}
OS_PORT=9200
OS_HEAP=1g
OS_ADMIN_PASSWORD=$(gen)
OS_VERSION_REPO=2.x

FILEBEAT_USER=filebeat_writer
FILEBEAT_PASSWORD=$(gen)
FILEBEAT_VERSION=7.12.1

LOG_DIR=/var/log/mariadb
RETENTION_DAYS=14

# MariaDB Galera install
SST_USER=sstuser
SST_PASSWORD=$(gen2)
INNODB_BUFFER_POOL=
APP_CIDR=

# Metrics / uptime / Grafana
DB_NODES="db-node-01=${P[0]} db-node-02=${P[1]} db-node-03=${P[2]}"
CHECK_INTERVAL=10s
METRICS_RETENTION_DAYS=30
MB_MYSQL_USER=metricbeat
MB_MYSQL_PASSWORD=$(gen2)
GRAFANA_ADMIN_PASSWORD=$(gen)
GRAFANA_READER_USER=grafana_reader
GRAFANA_READER_PASSWORD=$(gen)
GRAFANA_TLS_SKIP_VERIFY=true
ENV
chmod 600 .env
echo "Wrote .env"
[ "${DRY:-0}" = 1 ] && exit 0

for i in 0 1 2; do
  N=$(printf 'db-node-%02d' $((i+1)))
  $SSH "ubuntu@${PUB[$i]}" "sudo hostnamectl set-hostname $N &&
    grep -q '127.0.1.1 $N' /etc/hosts || echo '127.0.1.1 $N' | sudo tee -a /etc/hosts >/dev/null
    echo 'preserve_hostname: true' | sudo tee /etc/cloud/cloud.cfg.d/99-preserve-hostname.cfg >/dev/null"
  echo "hostname set: ${PUB[$i]} -> $N"
done

for ip in "${PUB[@]}"; do
  rsync -az -e "$SSH" ./ "ubuntu@$ip:~/MariaDB-OpenSearch-Lab/"
  echo "copied project to $ip"
done

# ---- Grafana fixes (only applies once Grafana + the dashboard are installed) ----
fix_grafana() {
  $SSH "ubuntu@$GRAFANA_PUB" '
    if ! id grafana >/dev/null 2>&1; then
      echo "grafana user not found yet - skipping Grafana fix"
      exit 0
    fi
    sudo mkdir -p /var/lib/grafana/plugins
    sudo chown -R grafana:grafana /var/lib/grafana
    if [ -f /var/lib/grafana/dashboards/mariadb-galera-overview.json ]; then
      sudo python3 - <<"PY"
import json
p="/var/lib/grafana/dashboards/mariadb-galera-overview.json"
d=json.load(open(p)); n=0
for pn in d["panels"]:
    for t in pn.get("targets",[]):
        for m in t.get("metrics",[]):
            if m.get("type")=="derivative":
                m["pipelineAgg"]=m.get("field","1"); n+=1
json.dump(d,open(p,"w"),indent=1); print("fixed",n)
PY
      sudo chown grafana:grafana /var/lib/grafana/dashboards/mariadb-galera-overview.json
    else
      echo "dashboard JSON not found yet - skipping derivative fix"
    fi
  '
}
fix_grafana

echo "Done. Next: open the security group, then run the install scripts (README)."
