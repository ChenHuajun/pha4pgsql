#!/bin/bash

. ../config.ini

#check cluster status
###########################################################
#mysql_status()
#InPut:无
#OutPut:
#设置以下SHELL内部变量
# CLUSTER_STATUS:  "crm_mon -Afr1"的输出
# MASTER_NODE:     pgsql Master所在节点
# SLAVE_NODES:     pgsql Slave所在节点列表
#
#return
#0 Normal
#1 无法获取cib信息，比如pacemaker,corosync服务未启动
#2 分区未达到法定票数或和任意一个另外的HA节点状态不一致
###########################################################
pgsql_status() {

#    crm_verify -L
#    if [ $? -ne 0 ]; then
#        echo "failed to execute \"crm_verify -L\"">&2
#        return 1
#    fi
    
    CLUSTER_STATUS=`crm_mon -Afr1`
    if [ $? -ne 0 ]; then
        echo "failed to execute \"crm_mon -Afr1\"">&2
        return 1
    fi
    
    if [ -n "$node3" ]; then
        echo "$CLUSTER_STATUS"|grep "partition with quorum" >/dev/null
        if [ $? -ne 0 ]; then
            echo "partition WITHOUT quorum" >&2
            return 2
        fi
    
        if [ "$use_ssh" = "yes" ]; then
            # 测试发现几个节点的crm状态可能会不一致，保险起见需要进行检查。
            # 但是网络出现故障（丢包而不是拒绝）时，ssh命令可能会阻塞，故需要设置连接超时。 
            localnode=`hostname`
            local_status=`echo "$CLUSTER_STATUS"|grep -E "Current DC:|Online:"`
            for hanode in $node1 $node2 $node3
            do
                if [ "$hanode" != "$localnode" ]; then
                    remote_status=`ssh -o ConnectTimeout=2 $hanode crm_mon -Afr1|grep -E "Current DC:|Online:"`
                    if [ "$remote_status" = "$local_status" ]; then
                        break;
                    fi
                fi
            done
        
            if [ "$remote_status" != "$local_status" ]; then
                echo "inconsistentat status with other HA nodes" >&2
                return 2
            fi
        fi
    
    fi
    
    pgsql_locates=`crm_resource --resource msPostgresql --locate`
    if [ $? -ne 0 ]; then
        echo "failed to execute \"crm_resource --resource msPostgresql --locate\"">&2
        return 1
    fi

    MASTER_NODE=`echo "$pgsql_locates" | grep "running on:" | grep Master | awk '{print $6}'`
    SLAVE_NODES=`echo "$pgsql_locates" | grep "running on:" | grep -v Master | awk '{print $6}'`
    
    # translate \n to space
    SLAVE_NODES=`echo $SLAVE_NODES`
    
    return 0 
}

check_with_timeout()
{
    func="$1"
    timeout=$2

    start=`date +%s`
    expire=`expr $timeout + $start`
    
    while true
    do
        output=`$func 2>&1`
        if [ $? -eq 0 ]; then
            if [ -n "$output" ];then
                echo "Successful to call \"$func\" :$output"
            fi
            return 0
        fi
        
        if [ `date +%s` -gt $expire ]; then
            echo "Tried $timeout seconds and failed to call \"$func\" :$output"
            return 1
        fi
        sleep 1
    done
}

check_resource_started()
{
    for resource in $1
    do
        crm_resource --resource $resource --locate 2>/dev/null | grep "is running on:" >/dev/null
        if [ $? -ne 0 ]; then
            return 1
        fi
    done
    
    return 0
}

check_resource_stoped()
{
    for resource in $1
    do
        crm_resource --resource $resource --locate 2>/dev/null | grep "is running on:" >/dev/null
        if [ $? -eq 0 ]; then
            return 1
        fi
    done
    
    return 0
}

check_node_standbyed()
{
    nodename=$1
    
    for resource in $RESOURCE_LIST
    do
        crm_resource --resource $resource --locate 2>/dev/null | grep "is running on: $nodename" >/dev/null
        if [ $? -eq 0 ]; then
            return 1
        fi
    done
    
    return 0
}

check_replication_ok()
{
    local data_status

    for node in $node1 $node2 $node3 $othernodes
    do
        data_status=`crm_attribute -l forever -N "$node" -n "pgsql-data-status" -G -q 2>/dev/null`
        if [ "$data_status" != "LATEST" -a "$data_status" != "STREAMING|ASYNC" -a "$data_status" != "STREAMING|POTENTIAL" -a "$data_status" != "STREAMING|SYNC" ]; then
            return 1
        fi
    done
    
    return 0
}

pgsql_status
rc=$?
if [ $rc -ne 0 ]; then
    exit `expr 100 + $rc`
fi