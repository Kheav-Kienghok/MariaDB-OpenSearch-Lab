#!/usr/bin/env bash
# Run on EACH MariaDB node, ONE AT A TIME (keeps Galera quorum).
. "$(dirname "$0")/../common.sh"; need_root

mkdir -p "$LOG_DIR"; chown mysql:mysql "$LOG_DIR"; chmod 750 "$LOG_DIR"

# Pick config dir (Ubuntu/Debian vs RHEL family)
if   [ -d /etc/mysql/mariadb.conf.d ]; then CNF=/etc/mysql/mariadb.conf.d/60-logging.cnf
else CNF=/etc/my.cnf.d/60-logging.cnf; fi

cat > "$CNF" <<CFG
[mysqld]
log_error=$LOG_DIR/mariadb.log
slow_query_log=1
slow_query_log_file=$LOG_DIR/mariadb-slow.log
long_query_time=1.0
log_slow_admin_statements=1

# Audit plugin
plugin_load_add=server_audit
server_audit_logging=ON
server_audit_events=CONNECT,QUERY_DDL,QUERY_DML
server_audit_file_path=$LOG_DIR/mariadb-audit.log
server_audit_file_rotate_size=100000000
server_audit_file_rotations=5
CFG
echo "Wrote $CNF"

cat > /etc/logrotate.d/mariadb-custom <<CFG
$LOG_DIR/mariadb.log $LOG_DIR/mariadb-slow.log {
    daily
    rotate 7
    missingok
    notifempty
    compress
    delaycompress
    create 640 mysql mysql
    postrotate
        mysqladmin flush-logs >/dev/null 2>&1 || true
    endscript
}
CFG

systemctl restart mariadb
for i in $(seq 1 30); do
  mysql -N -e "SELECT 1" >/dev/null 2>&1 && break
  sleep 2
done
mysql -e "SHOW GLOBAL STATUS WHERE Variable_name IN ('wsrep_cluster_size','wsrep_local_state_comment','wsrep_ready');"
echo ">> Wait until wsrep_cluster_size=3 and Synced before running this on the next node."
