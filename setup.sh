#!/bin/bash

cd "$(dirname "$0")"
. ./config.ini

echo "generate config.pcs..."
./gencfg.sh

# clear pgsql-data-status attribute from all node
for node in `crm_node -l|awk '{print $2}'`
do
    crm_attribute -l forever -N ${node} -n "pgsql-data-status" -D
done

# setup cib
echo "setup cib..."
sh config.pcs
if [ $? -ne 0 ]; then
    echo 'failed to execute "sh config.pcs"' >&2
    exit 1
fi

# initialize data of distributed lock
if [ "$pgsql_enable_distlock" = "true" ]; then
	echo "initialize data of distributed lock..."
    echo $pgsql_distlock_psql_cmd -vlockname=$pgsql_distlock_lockname -f tools/distlock_init.sql | tr -d '\\' | sh
	if [ $? -ne 0 ]; then
        echo 'failed to initialize data of distributed lock' >&2
        exit 1
    fi
fi
