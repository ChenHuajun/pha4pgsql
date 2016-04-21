#!/bin/bash

cd $(dirname "$0")
. ./config.ini

SSH="ssh $node1"
DATA_DIR="$pgsql_pgdata"

init_recovery_scripts()
{
    recovery_scripts=()
}

push_recovery_script()
{
   recovery_scripts[${#recovery_scripts[@]}]="$*"
}

run_recovery_scripts()
{
    result=0
    i=0
    while [ -n "${recovery_scripts[$i]}" ]
    do
        echo "run recovery scripts: ${recovery_scripts[$i]}"
        ${recovery_scripts[$i]}
        if [ $? -ne 0 ]; then
            echo "failed to run recovery_scripts: ${recovery_scripts[$i]}"
            result=1
        fi
        let i+=1
    done
    
    return $result
}

#faults (do not modify this line !!!)
mysql_crash()
{
    if [ $# -ne 1 ];then
        echo "Usage $0 target_host netdown_time"
        exit 1
    fi
    
    target_host=$1
    
    ssh $target_host killall -9 mysqld
}

pgsql_crash()
{
    if [ $# -ne 1 ];then
        echo "Usage $0 target_host netdown_time"
        exit 1
    fi
    
    target_host=$1
    
    ssh $target_host killall -9 postgres
}

net_down()
{
    if [ $# -ne 1 ];then
        echo "Usage $0 target_host netdown_time"
        exit 1
    fi
    
    target_host=$1

    echo "cut network from and to $target_host"
     
    for hanode in $node1 $node2 $node3
    do
        if [ "$target_host" != "$hanode" ];then
            if [ "$hanode" = `hostname` ]; then
                echo "You can not run this script in a HA node"
                ssh "$target_host" iptables -F
                exit 1
            fi
            ssh "$target_host" iptables -A INPUT -j DROP -s $hanode
            ssh "$target_host" iptables -A OUTPUT -j DROP -d $hanode
        fi
    done
    
    push_recovery_script net_up "$target_host"
}

net_down_reject()
{
    if [ $# -ne 1 ];then
        echo "Usage $0 target_host netdown_time"
        exit 1
    fi
    
    target_host=$1

    echo "cut(reject) network from and to $target_host"
     
    for hanode in $node1 $node2 $node3
    do
        if [ "$target_host" != "$hanode" ];then
            if [ "$hanode" = `hostname` ]; then
                echo "You can not run this script in a HA node"
                ssh "$target_host" iptables -F
                exit 1
            fi
            ssh "$target_host" iptables -A INPUT -j REJECT -s $hanode
            ssh "$target_host" iptables -A OUTPUT -j REJECT -d $hanode
        fi
    done
    
    push_recovery_script net_up "$target_host"
}

net_up()
{
    if [ $# -ne 1 ];then
        echo "Usage $0 target_host"
        exit 1
    fi
    
    #recovery network
    target_host=$1
    echo "recovery network from and to $target_host"
    ssh "$target_host" iptables -F
}

net_down_up()
{
    if [ $# -ne 2 ];then
        echo "Usage $0 target_host netdown_time"
        exit 1
    fi

    target_host=$1
    netdown_time=$2

    echo "cut network from and to $target_host for $netdown_time seconds"
     
    for hanode in $node1 $node2 $node3
    do
        if [ ! "$target_host" = "$hanode" ];then
            if [ "$hanode" = `hostname` ]; then
                echo "You can not run this script in a HA node"
                ssh "$target_host" iptables -F
                exit 1
            fi
            ssh "$target_host" iptables -A INPUT -j DROP -s $hanode
            ssh "$target_host" iptables -A OUTPUT -j DROP -d $hanode
        fi
    done

    sleep $netdown_time

    ssh "$target_host" iptables -F
    echo "network of ${target_host} recoveried"
}

os_reboot()
{
    if [ $# -ne 1 ];then
        echo "Usage $0 target_host"
        exit 1
    fi
    
    target_host=$1
    
    ssh "$target_host" reboot
}

os_crash()
{
    if [ $# -ne 1 ];then
        echo "Usage $0 target_host"
        exit 1
    fi
    
    target_host=$1
    
    #£¿£¿£¿£¿£¿£¿£¿
    
    ssh "$target_host" reboot
}

data_corrupt_nodir()
{
    if [ $# -ne 1 ];then
        echo "Usage $0 target_host"
        exit 1
    fi
    
    target_host=$1
    ssh "$target_host" mv ${DATA_DIR} "${DATA_DIR}_org"
    push_recovery_script data_corrupt_nodir_recovery "$target_host"
}

data_corrupt_nodir_recovery()
{
    if [ $# -ne 1 ];then
        echo "Usage $0 target_host"
        exit 1
    fi
    
    target_host=$1
    ssh "$target_host" mv "${DATA_DIR}_org" ${DATA_DIR}
}

data_corrupt_noperm()
{
    if [ $# -ne 1 ];then
        echo "Usage $0 target_host"
        exit 1
    fi
    
    target_host=$1
    ssh "$target_host" chmod a-x ${DATA_DIR}
    push_recovery_script data_corrupt_noperm_recovery "$target_host"
}

data_corrupt_noperm_recovery()
{
    if [ $# -ne 1 ];then
        echo "Usage $0 target_host"
        exit 1
    fi
    
    target_host=$1
    ssh "$target_host" chmod a+x ${DATA_DIR}
}
