# mariadb-opensearch-logging

Production-style observability for an existing **3-node MariaDB Galera** cluster, all stored in **OpenSearch** and shown in **Grafana**. No Docker/Podman.

| Signal | Tool | Runs on | Index |
|---|---|---|---|
| Error / slow / audit logs | Filebeat OSS | each DB node | `mariadb-*` |
| Connections, reads, Galera, CPU, RAM | Metricbeat OSS | each DB node | `metricbeat-*` |
| Node up/down (ping + port 3306) | Heartbeat OSS | **vm4** (outside DB nodes) | `heartbeat-*` |
| Dashboards | Grafana + OpenSearch plugin | vm4 | - |

Why Heartbeat runs on vm4: a dead node cannot report that it is dead. A probe from outside is the only reliable up/down signal.

## Dashboard: "MariaDB Galera - Production Overview"
- **Node availability:** per-node UP/DOWN tiles for host ping and MariaDB :3306, plus the Galera cluster size each node sees (3 = healthy).
- **Connections:** avg connections per node (bar), threads connected/running, new connections/s, aborted connects/s.
- **Reads:** avg SELECT/s per node (bar), SELECT/s, all queries/s.
- **Galera:** flow control paused, receive queue.
- **Host:** CPU and memory per node.
- **Logs:** slow query count, error/warning count, recent error lines.

## Order
```bash
cp .env.example .env            # every VM. Set DB_NODES, OS_HOST, passwords
```
**vm4**
```bash
sudo bash 02-opensearch/01-install-opensearch.sh
sudo bash 02-opensearch/02-bootstrap.sh       # users, roles, templates, retention (re-runnable)
scp /etc/opensearch/root-ca.pem <user>@<db-node>:<project>/certs/root-ca.pem   # each DB node
```
**DB nodes**: install Galera first if you do not have it (Ubuntu 24.04, one node at a time, node 1 first)
```bash
sudo bash 01-mariadb-nodes/00-install-galera.sh --bootstrap   # node 1 (first entry in DB_NODES)
sudo bash 01-mariadb-nodes/00-install-galera.sh               # node 2, then node 3
```
Then the logging step, one node at a time:
```bash
sudo bash 01-mariadb-nodes/01-mariadb-logging.sh
sudo bash 01-mariadb-nodes/02-install-filebeat.sh
sudo bash 01-mariadb-nodes/03-configure-filebeat.sh
sudo bash 01-mariadb-nodes/04-db-monitor-user.sh   # ONE node only
sudo bash 01-mariadb-nodes/05-metricbeat.sh        # every node
```
**vm4**
```bash
sudo bash 02-opensearch/04-heartbeat.sh
sudo bash 02-opensearch/05-install-grafana.sh
bash 03-verify/verify.sh
```
Open `http://<vm4>:3000` -> folder **MariaDB**.

## Production notes
- Put Grafana behind HTTPS (nginx) or a VPN. Allow :9200 only from the DB nodes and vm4; :3000 only from admins.
- Replace the OpenSearch demo certificate with a real one (SAN = IP/DNS), then use `verification_mode: full` and set `GRAFANA_TLS_SKIP_VERIFY=false`.
- Each shipper has its own keystore; Grafana uses a read-only account (`grafana_reader`).
- Retention: logs `RETENTION_DAYS`, metrics/uptime `METRICS_RETENTION_DAYS` via ISM.
- Counters (SELECT/s etc.) use a derivative; a MariaDB restart shows one negative spike.
- Single-node OpenSearch is a single point of failure for monitoring; add nodes + replicas for real HA.

## Troubleshooting
| Filebeat/Metricbeat: `unknown parameter [_type]` | OpenSearch 2.x reports version 2.x, so Beats 7.x send the removed `_type`. Set `compatibility.override_main_response_version: true` in `/etc/opensearch/opensearch.yml` and restart OpenSearch (already in the install script) |
| Symptom | Check |
|---|---|
| A panel says "No data" | `verify.sh` field list; open Discover/Explore and look for the real field name (Metricbeat field names can differ by version) |
| Metricbeat mysql error | `04-db-monitor-user.sh` ran? password has only letters/digits? |
| Tiles stay UP after you stopped a node | Heartbeat on vm4 running? `journalctl -u heartbeat` |
| Grafana datasource red | `journalctl -u grafana-server`, check `grafana_reader` and that the plugin installed |
| TLS errors | CA missing in `certs/`, or use the demo `GRAFANA_TLS_SKIP_VERIFY=true` while testing |
| Filebeat `mysql` module pipeline error | see earlier fallback: `type: log` + `multiline` |
