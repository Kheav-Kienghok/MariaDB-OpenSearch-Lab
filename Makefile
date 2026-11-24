# Run each target on the VM it belongs to (as a user with sudo).
.PHONY: galera-bootstrap galera-join opensearch logging filebeat db-user metricbeat heartbeat grafana verify
galera-bootstrap:  ## DB node 1 only
	sudo bash 01-mariadb-nodes/00-install-galera.sh --bootstrap
galera-join:       ## DB node 2, then node 3
	sudo bash 01-mariadb-nodes/00-install-galera.sh
opensearch:  ## vm4: OpenSearch + users/templates/retention
	sudo bash 02-opensearch/01-install-opensearch.sh
	sudo bash 02-opensearch/02-bootstrap.sh
logging:     ## each DB node, ONE AT A TIME
	sudo bash 01-mariadb-nodes/01-mariadb-logging.sh
filebeat:    ## each DB node
	sudo bash 01-mariadb-nodes/02-install-filebeat.sh
	sudo bash 01-mariadb-nodes/03-configure-filebeat.sh
db-user:     ## ONE DB node only (Galera replicates it)
	sudo bash 01-mariadb-nodes/04-db-monitor-user.sh
metricbeat:  ## each DB node
	sudo bash 01-mariadb-nodes/05-metricbeat.sh
heartbeat:   ## vm4 (external vantage point: up/down checks)
	sudo bash 02-opensearch/04-heartbeat.sh
grafana:     ## vm4
	sudo bash 02-opensearch/05-install-grafana.sh
verify:
	bash 03-verify/verify.sh
