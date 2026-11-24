#!/usr/bin/env bash
# Ubuntu 24.04: install MariaDB + Galera on THIS node (run on each of the 3 VMs).
#   Node 1 (first entry in DB_NODES):   sudo bash 00-install-galera.sh --bootstrap
#   Node 2 and 3 (after node 1 is up):  sudo bash 00-install-galera.sh
. "$(dirname "$0")/../common.sh"; need_root
BOOT=0; [ "${1:-}" = "--bootstrap" ] && BOOT=1

. /etc/os-release
[ "$ID" = ubuntu ] || echo "WARN: written for Ubuntu 24.04 (found $ID $VERSION_ID)"

# ---- who am I? (hostname -s must match a name in DB_NODES) ----
ME="$(hostname -s)"; MYIP=""; ALL_IPS=(); FIRST=""
for pair in $DB_NODES; do
  n="${pair%%=*}"; ip="${pair##*=}"; ALL_IPS+=("$ip"); [ -z "$FIRST" ] && FIRST="$n"
  [ "$n" = "$ME" ] && MYIP="$ip"
done
[ -n "$MYIP" ] || { echo "ERROR: hostname '$ME' is not in DB_NODES ($DB_NODES). Fix with: hostnamectl set-hostname <name>"; exit 1; }
ip -o -4 addr show | awk '{print $4}' | cut -d/ -f1 | grep -qxF "$MYIP" || { echo "ERROR: $MYIP is not configured on this VM"; exit 1; }
[ "${#ALL_IPS[@]}" -eq 3 ] || echo "WARN: DB_NODES has ${#ALL_IPS[@]} entries (3 expected)"
[ $BOOT -eq 1 ] && [ "$ME" != "$FIRST" ] && echo "WARN: --bootstrap on '$ME' but the first node is '$FIRST'"
CLUSTER_ADDR="gcomm://$(IFS=,; echo "${ALL_IPS[*]}")"

MEM_MB=$(awk '/MemTotal/{print int($2/1024)}' /proc/meminfo)
BP="${INNODB_BUFFER_POOL:-$((MEM_MB/2))M}"      # default: 50% of RAM (safe on a 4 GB VM)
echo "Node $ME ($MYIP)  cluster=$CLUSTER_NAME  buffer_pool=$BP  bootstrap=$BOOT"

# ---- joiners need a reachable peer ----
if [ $BOOT -eq 0 ]; then
  OK=0
  for ip in "${ALL_IPS[@]}"; do [ "$ip" = "$MYIP" ] && continue
    timeout 3 bash -c "echo > /dev/tcp/$ip/4567" 2>/dev/null && OK=1 && break
  done
  [ $OK -eq 1 ] || { echo "ERROR: no other node answers on :4567. Bootstrap node 1 first (and open the firewall)."; exit 1; }
fi

# ---- install ----
export DEBIAN_FRONTEND=noninteractive
apt-get update -y
apt-get install -y mariadb-server mariadb-backup galera-4 socat rsync
systemctl stop mariadb

PROVIDER=/usr/lib/galera/libgalera_smm.so
[ -f "$PROVIDER" ] || PROVIDER="$(find /usr/lib -name libgalera_smm.so | head -1)"
[ -f "$PROVIDER" ] || { echo "ERROR: libgalera_smm.so not found (galera-4 not installed?)"; exit 1; }

# ---- Galera config ----
cat > /etc/mysql/mariadb.conf.d/60-galera.cnf <<CFG
[mysqld]
bind-address=0.0.0.0
binlog_format=ROW
default_storage_engine=InnoDB
innodb_autoinc_lock_mode=2
innodb_buffer_pool_size=$BP
innodb_flush_log_at_trx_commit=2      # trades a little durability for speed; Galera replicates anyway
max_connections=300

wsrep_on=ON
wsrep_provider=$PROVIDER
wsrep_cluster_name="$CLUSTER_NAME"
wsrep_cluster_address="$CLUSTER_ADDR"
wsrep_node_address="$MYIP"
wsrep_node_name="$ME"
wsrep_sst_method=mariabackup
wsrep_sst_auth="$SST_USER:$SST_PASSWORD"
CFG
chown root:mysql /etc/mysql/mariadb.conf.d/60-galera.cnf
chmod 640 /etc/mysql/mariadb.conf.d/60-galera.cnf

# ---- firewall (only touches ufw if it is already active) ----
if command -v ufw >/dev/null && ufw status | grep -q "Status: active"; then
  for ip in "${ALL_IPS[@]}"; do
    for pp in 3306/tcp 4567/tcp 4567/udp 4568/tcp 4444/tcp; do
      ufw allow from "$ip" to any port "${pp%/*}" proto "${pp#*/}" >/dev/null
    done
  done
  ufw allow from "$OS_HOST" to any port 3306 proto tcp >/dev/null     # Heartbeat probe from vm4
  [ -n "${APP_CIDR:-}" ] && ufw allow from "$APP_CIDR" to any port 3306 proto tcp >/dev/null
  echo "ufw rules added"
else
  echo "NOTE: ufw is not active. Make sure nodes can reach each other on 3306, 4567 (tcp+udp), 4568, 4444."
fi

# ---- start ----
if [ $BOOT -eq 1 ]; then
  galera_new_cluster
else
  systemctl start mariadb            # joins and runs an SST from a donor (can take a minute)
fi

for i in $(seq 1 90); do
  ST=$(mariadb -N -e "SHOW STATUS LIKE 'wsrep_local_state_comment'" 2>/dev/null | awk '{print $2}')
  [ "$ST" = "Synced" ] && break; sleep 4
done

if [ $BOOT -eq 1 ]; then
  mariadb <<SQL
CREATE USER IF NOT EXISTS '$SST_USER'@'localhost' IDENTIFIED BY '$SST_PASSWORD';
ALTER USER '$SST_USER'@'localhost' IDENTIFIED BY '$SST_PASSWORD';
GRANT RELOAD, PROCESS, LOCK TABLES, BINLOG MONITOR ON *.* TO '$SST_USER'@'localhost';
DROP DATABASE IF EXISTS test;
FLUSH PRIVILEGES;
SQL
  echo ">> Node 1 is up. Now run this script (no flag) on node 2, then node 3."
fi

mariadb -e "SHOW STATUS WHERE Variable_name IN ('wsrep_cluster_size','wsrep_cluster_status','wsrep_local_state_comment','wsrep_ready','wsrep_connected');"
echo ">> Healthy = cluster_size grows 1 -> 2 -> 3, status Primary, state Synced, ready ON."
