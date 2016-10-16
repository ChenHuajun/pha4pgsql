#!/bin/bash
# create config.pcs via configure file template

cd "$(dirname "$0")"
. ./config.ini

template_file=template/${pcs_template}

# generate config.pcs
sed -e 's#${pha4pgsql_dir}#'${pha4pgsql_dir}#g \
    -e 's#${writer_vip}#'${writer_vip}#g \
    -e 's#${reader_vip}#'${reader_vip}#g \
    -e 's#${node1}#'${node1}#g \
    -e 's#${node2}#'${node2}#g \
    -e 's#${node3}#'${node3}#g \
    -e 's#${othernodes}#'${othernodes}#g \
    -e 's#${vip_nic}#'${vip_nic}#g \
    -e 's#${vip_cidr_netmask}#'${vip_cidr_netmask}#g \
    -e 's#${pgsql_pgctl}#'${pgsql_pgctl}#g \
    -e 's#${pgsql_psql}#'${pgsql_psql}#g \
    -e 's#${pgsql_pgdata}#'${pgsql_pgdata}#g \
    -e 's#${pgsql_pgport}#'${pgsql_pgport}#g \
    -e 's#${pgsql_rep_mode}#'${pgsql_rep_mode}#g \
    -e 's#${pgsql_repuser}#'"${pgsql_repuser}#g" \
    -e 's#${pgsql_reppassord}#'"${pgsql_reppassord}#g" \
    -e 's#${pgsql_restore_command}#'"${pgsql_restore_command}#g" \
    -e 's#${pgsql_enable_distlock}#'${pgsql_enable_distlock}#g \
    -e 's#${pgsql_distlock_psql_cmd}#'"${pgsql_distlock_psql_cmd}#g" \
    -e 's#${pgsql_distlock_lockname}#'${pgsql_distlock_lockname}#g \
    -e 's#${enable_lvs}#'${enable_lvs}#g \
    $template_file > config.pcs
	


