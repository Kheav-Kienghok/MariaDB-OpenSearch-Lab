#!/usr/bin/env bash
# Installs Filebeat OSS (OpenSearch-compatible) on a DB node.
. "$(dirname "$0")/../common.sh"; need_root

if command -v dpkg >/dev/null; then
  URL="https://artifacts.elastic.co/downloads/beats/filebeat/filebeat-oss-${FILEBEAT_VERSION}-amd64.deb"
  curl -fL "$URL" -o /tmp/filebeat-oss.deb
  dpkg -i /tmp/filebeat-oss.deb
else
  URL="https://artifacts.elastic.co/downloads/beats/filebeat/filebeat-oss-${FILEBEAT_VERSION}-x86_64.rpm"
  curl -fL "$URL" -o /tmp/filebeat-oss.rpm
  rpm -Uvh --replacepkgs /tmp/filebeat-oss.rpm
fi
filebeat version
