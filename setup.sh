#!/bin/bash

cd "$(dirname "$0")"
. ./config.ini

master=$1

if [ ! -f config.pcs ]; then
    echo "config.pcs does not exists, please run install.sh/gencfg.sh to create it"
fi

# erase cib
echo "erase cib..."
# switch all node to maintenance mode
for node in `crm_node -l|awk '{print $2}'`
do
    pcs property set --node ${node} maintenance=on
done

cibadmin --erase -f
if [ $? -ne 0 ]; then
    echo 'failed to execute "cibadmin --erase -f"' >&2
    exit 1
fi

pcs resource cleanup

if [ -n "$master" ]; then
    echo "set the pgsql_REPL_INFO to $master"
    crm_attribute --type crm_config --name pgsql_REPL_INFO -s pgsql_replication -v "$master"
fi

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
