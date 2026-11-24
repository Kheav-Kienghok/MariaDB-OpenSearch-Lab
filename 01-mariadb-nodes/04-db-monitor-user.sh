#!/usr/bin/env bash
# Run on ONE MariaDB node as root. Galera replicates the account to the others.
. "$(dirname "$0")/../common.sh"; need_root
for H in 127.0.0.1 localhost; do
mysql <<SQL
CREATE USER IF NOT EXISTS '$MB_MYSQL_USER'@'$H' IDENTIFIED BY '$MB_MYSQL_PASSWORD' WITH MAX_USER_CONNECTIONS 3;
ALTER USER '$MB_MYSQL_USER'@'$H' IDENTIFIED BY '$MB_MYSQL_PASSWORD';
GRANT USAGE ON *.* TO '$MB_MYSQL_USER'@'$H';
SQL
done
mysql -e "FLUSH PRIVILEGES; SELECT user,host FROM mysql.user WHERE user='$MB_MYSQL_USER';"
