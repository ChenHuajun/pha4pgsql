
# Pacemaker High Availability for PostgreSQL

## 简介
在众多的PostgreSQL HA方案中，流复制HA方案是性能，可靠性，部署成本等方面都比较好的，也是目前被普遍采用的方案。而用于管理流复制集群的工具中，Pacemaker+Corosync又是比较成熟可靠的。

但是原生的基于Pacemaker+Corosync搭建PostgreSQL流复制HA集群配置和使用都比较复杂，因此封装了一些常用的集群配置和操作命令，目的在于简化集群的部署和使用。同时对Resource Agent 3.9.7的pgsql RA进行了增强，引入分布式锁服务，防止双节点集群出现脑裂，并确保同步复制下failover后数据不丢失。 但是，你还是必须了解Pacemaker的相关概念和基本操作，用于解决封装脚本处理不了的问题。


## 功能特性
1. 秒级故障转移
2. 支持双节点集群和多节点集群
3. 支持同步复制和异步复制
4. 同步复制下failover零数据丢失
5. 提供读写VIP和只读VIP，集群的拓扑结构对应用透明

## 基本架构和原理
1. Pacemaker + Corosync作为集群基础软件，Corosync负责集群通信和成员关系管理，Pacemaker负责资源管理。
2. 集群用到资源包括PostgreSQL和VIP等，PostgreSQL对应的Resource Agent(RA)为expgsql，expgsql负责实施PostgreSQL的起停，监视，failover等操作。
3. 集群初始启动时expgsql通过比较所有节点的xlog位置，找出xlog最新的节点作为Master，其它节点作为Slave通过读写VIP连接到Master上进行WAL复制。
4. 集群启动后expgsql不断监视PostgreSQL的健康状况，当expgsql发现PostgreSQL资源故障时报告给Pacemaker，由Pacemaker实施相应动作。
   - 如果是PostgreSQL进程故障，原地重启PostgreSQL，并且该节点上的fail-count加1。
   - fail-count累加到3时不再分配PostgreSQL资源到这个节点。如果该节点为Master，会提升一个Slave为Master，即发起failover。
5. Corosync发现节点故障(主机或网络故障)时，Pacemaker也根据情况实施相应动作。
   - 对多节点集群，未包含过半节点成员的分区将主动释放本分区内的所有资源，包括PostgreSQL和VIP。
   - 合法的分区中如果没有Master，Pacemaker会提升一个Slave为Master，即发起failover。
6. Master上的expgsql会不断监视Slave的复制健康状况，同步复制下会选定一个Slave作为同步Slave。
7. 当同步Slave出现故障时，Master上的expgsql会临时将同步复制切换到异步复制，防止Master上的写操作被hang住。如果故障Slave恢复或存在另一个健康的Slave，再切换到同步复制。
8. 为防止集群分区后，Slave升级为新Master而旧Master切换到异步复制导致脑裂和数据双写，引入分布式锁服务进行仲裁。Slave升级为新Master和旧Master切换到异步复制前必须先取得锁，避免这两件事同时发生。失去锁的Master会主动停止PostgreSQL进程，防止出现双主。
9. 如果分布锁服务发生故障而所有PostgreSQL节点都是健康的，expgsql会忽视锁服务，即不影响集群服务。但在分布锁服务故障期间，Master发生节点故障(注意区分节点故障和资源故障)，集群将无法正常failover。
10. 同步复制下只有同步Slave才有资格成为候选Master，加上有分布式锁的防护，可以确保failover后数据不丢失。
11. 集群初始启动和每次failover时通过pg_ctl promote提升Slave为Master并使时间线加1，同时记录Master节点名，时间线和切换时的xlog位置到集群CIB。
12. 集群重启时根据集群CIB中记录的信息确定Master节点，并保持时间线不变。
13. expgsql启动PostgreSQL前会检查该节点的时间线和xlog，如果和集群CIB中记录的信息有冲突，将报错。需要人工通过cls_repair_slave(pg_rewind)等手段修复。
14. 读写VIP和Master节点绑定，只读VIP和其中一个Slave绑定，应用只需访问VIP，无需关心具体访问哪个节点。


## 集群操作命令一览
1. cls_start  
   启动集群
2. cls_stop   
   停止集群
3. cls_online_switch      
   在线主从切换,对多节点集群当前不支持指定新Master。在多节点的同步复制下，只有pgsql-data-status值为“STREAMING|SYNC”的节点，即同步复制节点可以作为候选master。如果希望指定其它节点作为新的master，可以在master上执行下面的操作，然后等待pgsql-data-status更新。

		su - postgres
		echo "synchronous_standby_names = 'node3'" > /var/lib/pgsql/tmp/rep_mode.conf
		pg_ctl -D /home/postgresql/data reload
		exit

4. cls_master   
   输出当前Master节点名
5. cls_status   
   显示集群状态
6. cls_cleanup   
   清除资源状态和fail-count。在某个节点上资源失败次数(fail-count)超过3次Pacemaker将不再分配该资源到此节点，人工修复故障后需要调用cleanup让Pacemkaer重新尝试启动资源。
7. cls_reset_master [master]   
   设置pgsql_REPL_INFO使指定的节点成为Master；如未指定Master，则清除pgsql_REPL_INFO让Pacemaker重新在所有节点中选出xlog位置最新的节点作为Master。仅用于集群中没有任何节点满足Master条件情况下的紧急修复。
8. cls_repair_by_pg_rewind
   通过pg_rewind修复当前节点，主要用于旧Master的修复，回退超出时间线分叉点的那部分更新，并和新Master建立复制关系。pg_rewind仅在PostgreSQL 9.5以上版本提供
9. cls_rebuild_slave   
   通过pg_basebackup在当前节点重建Slave。执行该命令前需要停止当前节点上的PostgreSQL进程并清空旧的数据目录。
10. cls_unmanage   
   unmanage所有资源使其脱离Pacemaker的控制。当需要重启Pacemaker和Corosync又不能停止PostgreSQL服务时，可以先调用这个命令，Pacemaker和Corosync重启完成后再用cls_manage恢复管理。
11. cls_manage   
   恢复cls_unmanage产生的资源unmanaged状态。
12. cls_maintenance_node <nodename> 
   使节点进入维护模式。维护模式和unmanage resource相比的区别是会取消monitor，比unmanage更彻底。
13. cls_unmaintenance_node <nodename> 
   解除节点的维护模式。
14. cls_standby_node <nodename>   
   释放某节点上所有资源。可用于特定节点的维护，比如升级。
15. cls_unstandby_node <nodename>   
   恢复cls_standby_node产生的节点standby状态。

以上命令必须以root用户执行

## 依赖软件
- pacemaker
- pcs
- psmisc
- policycoreutils-python
- postgresql-server

## 安装

安装过程以在以下环境下部署双节点HA集群为例说明。  

- OS:CentOS 7.0  
- 节点1主机名:node1  
- 节点2主机名:node2   
- writer_vip:192.168.41.136   
- reader_vip:192.168.41.137   
- 用作分布式锁服务的PostgreSQL的连接字符串:"host=node3 port=5439 dbname=postgres user=postgres"

### Linux集群环境安装与配置
#### 环境准备
1. 所有节点设置时钟同步

		cp /usr/share/zoneinfo/Asia/Shanghai /etc/localtime
		ntpdate time.windows.com && hwclock -w  

2. 所有节点设置独立的主机名(node1，node2)

		hostnamectl set-hostname node1

3. 设置对所有节点的域名解析(修改/etc/hosts)
4. 所有节点间设置SSH互信

#### 禁用防火墙 
在所有节点执行：

	setenforce 0
	sed -i.bak "s/SELINUX=enforcing/SELINUX=permissive/g" /etc/selinux/config
	systemctl disable firewalld.service
	systemctl stop firewalld.service
	iptables -F

如果开启防火墙需要开放postgres，pcsd和corosync的端口。

* postgres:5432/tcp
* pcsd:2224/tcp
* corosync:5405/udp

#### 安装Pacemaker和Corosync及相关软件包
在所有节点执行：

    yum install -y pacemaker pcs psmisc policycoreutils-python

注：如果OS自带的Pacemaker比较旧，建议下载新版的。之前在Pacemaker 1.1.7上遇到了不少Bug，因此不建议使用这个版本或更老的版本。

#### 启用pcsd服务
在所有节点执行：

	systemctl start pcsd.service
	systemctl enable pcsd.service

#### 设置hacluster用户密码
在所有节点执行：

	echo hacluster | passwd hacluster --stdin

#### 集群认证
在任何一个节点上执行:

	pcs cluster auth -u hacluster -p hacluster node1 node2

#### 同步配置
在任何一个节点上执行:

    pcs cluster setup --last_man_standing=1 --name pgcluster node1 node2

#### 启动集群
在任何一个节点上执行:

    pcs cluster start --all

#### 启用pacemaker & corosync服务
在所有节点执行：

	systemctl start corosync.service
	systemctl enable corosync.service
	systemctl start pacemaker.service
	systemctl enable pacemaker.service
	
### 安装和配置PostgreSQL

#### 安装PostgreSQL
在所有节点执行：

    yum install postgresql-server

OS自带的PostgreSQL往往比较旧，可参考http://www.postgresql.org/download/linux/ ，安装最新版PostgreSQL.

#### 创建主数据库
在node1节点执行：

1. 创建数据目录

		mkdir -p /data/postgresql/data
		chown -R postgres:postgres /data/postgresql/
		chmod 0700 /data/postgresql/data

2. 初始化db
	
		su - postgres
		initdb -D /data/postgresql/data/

3. 修改postgresql.conf  

		listen_addresses = '*'
		wal_level = hot_standby
		synchronous_commit = on
		max_wal_senders=5
		wal_keep_segments = 32
		hot_standby = on
		replication_timeout = 5000
		wal_receiver_status_interval = 2
		max_standby_streaming_delay = -1
		max_standby_archive_delay = -1
		restart_after_crash = off
		hot_standby_feedback = on

    注：PostgreSQL 9.3及以后版本，应将replication_timeout替换成wal_sender_timeout；PostgreSQL 9.5以上版本，可加上"wal_log_hints = on"，使得可以使用pg_rewind修复旧Master。


4. 修改pg_hba.conf
 
		local   all                 all                              trust
		host    all                 all     192.168.41.0/24          md5
		host    replication         all     192.168.41.0/24          md5

5. 启动

		pg_ctl -D /data/postgresql/data/ start

6. 创建复制用户

		createuser --login --replication replication -P

    9.5以上版本如需要支持pg_rewind，需加上“-s”选项。

		createuser --login --replication replication -P -s

#### 创建备数据库
在node2节点执行：

1. 创建数据目录

		mkdir -p /data/postgresql/data
		chown -R postgres:postgres /data/postgresql/
		chmod 0700 /data/postgresql/data

2. 创建基础备份

		su - postgres
		pg_basebackup -h node1 -U replication -D /data/postgresql/data/ -X stream -P


#### 停止PostgreSQL服务
在node1上执行:

		pg_ctl -D /data/postgresql/data/ stop

### 配置分布式锁服务
分布式锁服务的作用是防止双节点集群出现脑裂。当网络发生故障形成分区时，备可能会被提升为主，同时旧主会将同步复制切换到异步复制，这可能导致数据丢失。通过分布式锁服务可以确保新主的提升和旧主的切换到异步复制同时只能有一个成功。

分布式锁服务通过HA集群外部的另外一个PostgreSQL服务实现。需要事先创建锁表。

	create table if not exists distlock(lockname text primary key,owner text not null,ts timestamptz not null,expired_time interval not null);

可选地，可以创建锁的历史表，每次锁的owner变更(主从角色切换)都会记录到历史表(distlock_history)中。

	create table if not exists distlock_history(id serial primary key,lockname text not null,owner text not null,ts timestamptz not null,expired_time interval not null);
	
	CREATE OR REPLACE FUNCTION distlock_log_update() RETURNS trigger AS $$
	    BEGIN
	    
	        IF TG_OP = 'INSERT' or NEW.owner <> OLD.owner THEN
	            INSERT INTO distlock_history(lockname, owner, ts, expired_time) values(NEW.lockname, NEW.owner, NEW.ts, NEW.expired_time);
	        END IF;
	        RETURN NEW;
	    END;
	$$ LANGUAGE plpgsql;


	DROP TRIGGER IF EXISTS distlock_log_update ON distlock;
	
	CREATE TRIGGER distlock_log_update AFTER INSERT OR UPDATE ON distlock
	    FOR EACH ROW EXECUTE PROCEDURE distlock_log_update();


### 安装和配置pha4pgsql
在任意一个节点上执行:

1. 下载pha4pgsql

		git clone git://github.com/Chenhuajun/pha4pgsql.git

2. 编辑config.ini

		pcs_template=dual.pcs.template
		OCF_ROOT=/usr/lib/ocf
		RESOURCE_LIST="msPostgresql vip-master vip-slave"
		pha4pgsql_dir=/opt/pha4pgsql
		writer_vip=192.168.41.136
		reader_vip=192.168.41.137
		node1=node1
		node2=node2
		vip_nic=eno33554984
		vip_cidr_netmask=24
		pgsql_pgctl=/usr/bin/pg_ctl
		pgsql_psql=/usr/bin/psql
		pgsql_pgdata=/data/postgresql/data
		pgsql_pgdata=5432
		pgsql_restore_command=""
		pgsql_rep_mode=sync
		pgsql_repuser=replication
		pgsql_reppassord=replication
		pgsql_enable_distlock=true
		pgsql_distlock_psql_cmd='/usr/bin/psql \\"host=node3 port=5439 dbname=postgres user=postgres connect_timeout=5\\"'
		pgsql_distlock_lockname=pgsql_cls1

    需要根据实际环境修改上面的参数。当多个多个集群使用锁服务时，确保每个集群的pgsql_distlock_lockname值必须是唯一的。

3. 安装pha4pgsql

		sh install.sh
   
	这一步会拷贝需要的脚本到本地和远程机器上，并生成集群的资源配置文件。

		[root@node1 pha4pgsql]# cat config.pcs 
		
		pcs cluster cib pgsql_cfg
		
		pcs -f pgsql_cfg property set no-quorum-policy="ignore"
		pcs -f pgsql_cfg property set stonith-enabled="false"
		pcs -f pgsql_cfg resource defaults resource-stickiness="1"
		pcs -f pgsql_cfg resource defaults migration-threshold="10"
		
		pcs -f pgsql_cfg resource create vip-master IPaddr2 \
		   ip="192.168.41.136" \
		   nic="eno33554984" \
		   cidr_netmask="24" \
		   op start   timeout="60s" interval="0s"  on-fail="restart" \
		   op monitor timeout="60s" interval="10s" on-fail="restart" \
		   op stop    timeout="60s" interval="0s"  on-fail="block"
		
		pcs -f pgsql_cfg resource create vip-slave IPaddr2 \
		   ip="192.168.41.137" \
		   nic="eno33554984" \
		   cidr_netmask="24" \
		   op start   timeout="60s" interval="0s"  on-fail="restart" \
		   op monitor timeout="60s" interval="10s" on-fail="restart" \
		   op stop    timeout="60s" interval="0s"  on-fail="block"
		   
		pcs -f pgsql_cfg resource create pgsql expgsql \
		   pgctl="/usr/bin/pg_ctl" \
		   psql="/usr/bin/psql" \
		   pgdata="5432" \
		   pgport="" \
		   rep_mode="sync" \
		   node_list="node1 node2" \
		   restore_command="" \
		   primary_conninfo_opt="user=replication password=replication keepalives_idle=60 keepalives_interval=5 keepalives_count=5" \
		   master_ip="192.168.41.136" \
		   restart_on_promote="false" \
		   enable_distlock="true" \
		   distlock_lock_cmd="/opt/pha4pgsql/tools/distlock '/usr/bin/psql \"host=node3 port=5439 dbname=postgres user=postgres connect_timeout=5\"' lock distlock:pgsql_cls1 @owner 9 12" \
		   distlock_unlock_cmd="/opt/pha4pgsql/tools/distlock '/usr/bin/psql \"host=node3 port=5439 dbname=postgres user=postgres connect_timeout=5\"' unlock distlock:pgsql_cls1 @owner" \
		   distlock_lockservice_deadcheck_nodelist="node1 node2" \
		   op start   timeout="60s" interval="0s"  on-fail="restart" \
		   op monitor timeout="60s" interval="4s" on-fail="restart" \
		   op monitor timeout="60s" interval="3s"  on-fail="restart" role="Master" \
		   op promote timeout="60s" interval="0s"  on-fail="restart" \
		   op demote  timeout="60s" interval="0s"  on-fail="stop" \
		   op stop    timeout="60s" interval="0s"  on-fail="block" \
		   op notify  timeout="60s" interval="0s"
		
		pcs -f pgsql_cfg resource master msPostgresql pgsql \
		   master-max=1 master-node-max=1 clone-node-max=1 notify=true \
		   migration-threshold="3" target-role="Master"
		
		pcs -f pgsql_cfg constraint colocation add vip-master with Master msPostgresql INFINITY
		pcs -f pgsql_cfg constraint order promote msPostgresql then start vip-master symmetrical=false score=INFINITY
		pcs -f pgsql_cfg constraint order demote  msPostgresql then stop  vip-master symmetrical=false score=0
		
		pcs -f pgsql_cfg constraint colocation add vip-slave with Slave msPostgresql INFINITY
		pcs -f pgsql_cfg constraint order promote  msPostgresql then start vip-slave symmetrical=false score=INFINITY
		pcs -f pgsql_cfg constraint order stop msPostgresql then stop vip-slave symmetrical=false score=0
		
		pcs cluster cib-push pgsql_cfg


	可以根据需要对config.pcs做相应修改，在执行下面的配置脚本

		./setup.sh

    注意，安装和配置过程只需在一个节点上执行即可。

4. 设置环境变量

        export PATH=/opt/pha4pgsql/bin:$PATH

4. 启动集群

        cls_start

5. 确认集群状态
       
        cls_status

    cls_status的输出示例如下：

		[root@node1 pha4pgsql]# cls_status
		Last updated: Fri Apr 22 02:01:01 2016
		Last change: Fri Apr 22 02:01:00 2016 by root via crm_resource on node1
		Stack: corosync
		Current DC: node2 (2) - partition with quorum
		Version: 1.1.12-a14efad
		2 Nodes configured
		4 Resources configured
		
		
		Online: [ node1 node2 ]
		
		Full list of resources:
		
		 vip-master	(ocf::heartbeat:IPaddr2):	Started node1 
		 vip-slave	(ocf::heartbeat:IPaddr2):	Started node2 
		 Master/Slave Set: msPostgresql [pgsql]
		     Masters: [ node1 ]
		     Slaves: [ node2 ]
		
		Node Attributes:
		* Node node1:
		    + #cluster-name                   	: pgcluster 
		    + #site-name                      	: pgcluster 
		    + master-pgsql                    	: 1000      
		    + pgsql-data-status               	: LATEST    
		    + pgsql-master-baseline           	: 00000000070000D0
		    + pgsql-status                    	: PRI       
		* Node node2:
		    + #cluster-name                   	: pgcluster 
		    + #site-name                      	: pgcluster 
		    + master-pgsql                    	: -INFINITY 
		    + pgsql-data-status               	: STREAMING|ASYNC
		    + pgsql-status                    	: HS:async  
		
		Migration summary:
		* Node node2: 
		* Node node1: 
		
		pgsql_REPL_INFO:node1|1|00000000070000D0

	检查集群的健康状态。完全健康的集群需要满足以下条件：
	
	1. msPostgresql在每个节点上都已启动
	2. 在其中一个节点上msPostgresql处于Master状态，其它的为Salve状态
	3. Salve节点的data-status值是以下中的一个   
		- STREAMING|SYNC   
		   同步复制Slave
		- STREAMING|POTENTIAL   
		   候选同步复制Slave
		- STREAMING|ASYNC   
		   异步复制Slave
	
	
	pgsql-data-status的取值详细可参考下面的说明

		The transitional state of data is displayed. This state remains after stopping pacemaker. When starting pacemaker next time, this state is used to judge whether my data is old or not.
		DISCONNECT
		Master changes other node state into DISCONNECT if Master can't detect connection of replication because of LAN failure or breakdown of Slave and so on.
		{state}|{sync_state}
		Master changes other node state into {state}|{sync_state} if Master detects connection of replication.
		{state} and {sync_state} means state of replication which is retrieved using "select state and sync_state from pg_stat_replication" on Master.
		For example, INIT, CATCHUP, and STREAMING are displayed in {state} and ASYNC, SYNC are displayed in {sync_state}
		LATEST
		It's displayed when it's Master.
		These states are the transitional state of final data, and it may be not consistent with the state of actual data. For instance, During PRI, the state is "LATEST". But the node is stopped or down, this state "LATEST" is maintained if Master doesn't exist in other nodes. It never changes to "DISCONNECT" for oneself. When other node newly is promoted, this new Master changes the state of old Master to "DISCONNECT". When any node can not become Master, this "LATEST" will be keeped.

	pgsql_REPL_INFO的3段内容分别指当前master，上次提升前的时间线和xlog位置。

		pgsql_REPL_INFO:node1|1|00000000070000D0

## 故障测试

### Master上的postgres进程故障

1. 强制杀死Master上的postgres进程

		[root@node1 pha4pgsql]# killall postgres

2. 检查集群状态   
    由于设置了migration-threshold="3"，发生一次普通的错误，Pacemaker会在原地重新启动postgres进程，不发生主从切换。
（如果Master的物理机或网络发生故障，直接进行failover。）

		[root@node1 pha4pgsql]# cls_status
		Last updated: Fri Apr 22 02:03:17 2016
		Last change: Fri Apr 22 02:03:10 2016 by root via crm_resource on node1
		Stack: corosync
		Current DC: node2 (2) - partition with quorum
		Version: 1.1.12-a14efad
		2 Nodes configured
		4 Resources configured
		
		
		Online: [ node1 node2 ]
		
		Full list of resources:
		
		 vip-master	(ocf::heartbeat:IPaddr2):	Started node1 
		 vip-slave	(ocf::heartbeat:IPaddr2):	Started node2 
		 Master/Slave Set: msPostgresql [pgsql]
		     Masters: [ node1 ]
		     Slaves: [ node2 ]
		
		Node Attributes:
		* Node node1:
		    + #cluster-name                   	: pgcluster 
		    + #site-name                      	: pgcluster 
		    + master-pgsql                    	: 1000      
		    + pgsql-data-status               	: LATEST    
		    + pgsql-master-baseline           	: 0000000007000250
		    + pgsql-status                    	: PRI       
		* Node node2:
		    + #cluster-name                   	: pgcluster 
		    + #site-name                      	: pgcluster 
		    + master-pgsql                    	: 100       
		    + pgsql-data-status               	: STREAMING|SYNC
		    + pgsql-status                    	: HS:sync   
		
		Migration summary:
		* Node node2: 
		* Node node1: 
		   pgsql: migration-threshold=3 fail-count=1 last-failure='Mon Apr 18 09:14:28 2016'
		
		Failed actions:
		    pgsql_monitor_3000 on node1 'unknown error' (1): call=205, status=complete, exit-reason='none', last-rc-change='Fri Apr 22 02:02:56 2016', queued=0ms, exec=0ms
		
		
		pgsql_REPL_INFO:node1|1|00000000070000D0


3. 再强制杀死Master上的postgres进程2次后检查集群状态。   
    这时已经发生了failover，产生了新的Master，并提升了时间线。

		[root@node1 pha4pgsql]# cls_status
		Last updated: Fri Apr 22 02:07:33 2016
		Last change: Fri Apr 22 02:07:31 2016 by root via crm_resource on node1
		Stack: corosync
		Current DC: node2 (2) - partition with quorum
		Version: 1.1.12-a14efad
		2 Nodes configured
		4 Resources configured
		
		
		Online: [ node1 node2 ]
		
		Full list of resources:
		
		 vip-master	(ocf::heartbeat:IPaddr2):	Started node2 
		 vip-slave	(ocf::heartbeat:IPaddr2):	Stopped 
		 Master/Slave Set: msPostgresql [pgsql]
		     Masters: [ node2 ]
		     Stopped: [ node1 ]
		
		Node Attributes:
		* Node node1:
		    + #cluster-name                   	: pgcluster 
		    + #site-name                      	: pgcluster 
		    + master-pgsql                    	: -INFINITY 
		    + pgsql-data-status               	: DISCONNECT
		    + pgsql-status                    	: STOP      
		* Node node2:
		    + #cluster-name                   	: pgcluster 
		    + #site-name                      	: pgcluster 
		    + master-pgsql                    	: 1000      
		    + pgsql-data-status               	: LATEST    
		    + pgsql-master-baseline           	: 0000000007000410
		    + pgsql-status                    	: PRI       
		
		Migration summary:
		* Node node2: 
		* Node node1: 
		   pgsql: migration-threshold=3 fail-count=3 last-failure='Mon Apr 18 09:18:58 2016'
		
		Failed actions:
		    pgsql_monitor_3000 on node1 'not running' (7): call=237, status=complete, exit-reason='none', last-rc-change='Fri Apr 22 02:07:26 2016', queued=0ms, exec=0ms
		
		
		pgsql_REPL_INFO:node2|2|0000000007000410


4. 修复旧Master

	可通过pg_basebackup修复旧Master

		# su - postgres
		$ rm -rf /data/postgresql/data
		$ pg_basebackup -h 192.168.41.136 -U postgres -D /data/postgresql/data -X stream -P
		$ exit
		# pcs resource cleanup msPostgresql
    
	如果恢复失败，请检查PostgreSQL和Pacemaker日志文件。    

	通过pg_baseback修复旧Master。cls_rebuild_slave是对pg_basebackup的包装，主要多了执行结果状态的检查。

		[root@node1 pha4pgsql]# rm -rf /data/postgresql/data
		[root@node1 pha4pgsql]# cls_rebuild_slave 
		22636/22636 kB (100%), 1/1 tablespace
		All resources/stonith devices successfully cleaned up
		wait for recovery complete
		.....
		slave recovery of node1 successed
		[root@node1 pha4pgsql]# cls_status
		Last updated: Fri Apr 22 02:40:48 2016
		Last change: Fri Apr 22 02:40:36 2016 by root via crm_resource on node1
		Stack: corosync
		Current DC: node2 (2) - partition with quorum
		Version: 1.1.12-a14efad
		2 Nodes configured
		4 Resources configured
		
		
		Online: [ node1 node2 ]
		
		Full list of resources:
		
		 vip-master	(ocf::heartbeat:IPaddr2):	Started node2 
		 vip-slave	(ocf::heartbeat:IPaddr2):	Started node1 
		 Master/Slave Set: msPostgresql [pgsql]
		     Masters: [ node2 ]
		     Slaves: [ node1 ]
		
		Node Attributes:
		* Node node1:
		    + #cluster-name                   	: pgcluster 
		    + #site-name                      	: pgcluster 
		    + master-pgsql                    	: 100       
		    + pgsql-data-status               	: STREAMING|SYNC
		    + pgsql-status                    	: HS:sync   
		* Node node2:
		    + #cluster-name                   	: pgcluster 
		    + #site-name                      	: pgcluster 
		    + master-pgsql                    	: 1000      
		    + pgsql-data-status               	: LATEST    
		    + pgsql-master-baseline           	: 0000000007000410
		    + pgsql-status                    	: PRI       
		
		Migration summary:
		* Node node2: 
		* Node node1: 
		
		pgsql_REPL_INFO:node2|2|0000000007000410 


     9.5以上版本还可以通过pg_rewind修复旧Master

		[root@node1 pha4pgsql]# cls_repair_by_pg_rewind 
		connected to server
		servers diverged at WAL position 0/7000410 on timeline 2
		rewinding from last common checkpoint at 0/7000368 on timeline 2
		reading source file list
		reading target file list
		reading WAL in target
		need to copy 67 MB (total source directory size is 85 MB)
		69591/69591 kB (100%) copied
		creating backup label and updating control file
		syncing target data directory
		Done!
		All resources/stonith devices successfully cleaned up
		wait for recovery complete
		....
		slave recovery of node1 successed



### Master网络故障

1. 故障前的集群状态

    故障前的Master是node1

		[root@node1 pha4pgsql]# cls_status
		Last updated: Fri Apr 22 11:28:26 2016
		Last change: Fri Apr 22 11:25:56 2016 by root via crm_resource on node1
		Stack: corosync
		Current DC: node2 (2) - partition with quorum
		Version: 1.1.12-a14efad
		2 Nodes configured
		4 Resources configured
		
		
		Online: [ node1 node2 ]
		
		Full list of resources:
		
		 vip-master	(ocf::heartbeat:IPaddr2):	Started node1 
		 vip-slave	(ocf::heartbeat:IPaddr2):	Started node2 
		 Master/Slave Set: msPostgresql [pgsql]
		     Masters: [ node1 ]
		     Slaves: [ node2 ]
		
		Node Attributes:
		* Node node1:
		    + #cluster-name                   	: pgcluster 
		    + #site-name                      	: pgcluster 
		    + master-pgsql                    	: 1000      
		    + pgsql-data-status               	: LATEST    
		    + pgsql-master-baseline           	: 0000000009044898
		    + pgsql-status                    	: PRI       
		* Node node2:
		    + #cluster-name                   	: pgcluster 
		    + #site-name                      	: pgcluster 
		    + master-pgsql                    	: 100       
		    + pgsql-data-status               	: STREAMING|SYNC
		    + pgsql-status                    	: HS:sync   
		
		Migration summary:
		* Node node2: 
		* Node node1: 
		
		pgsql_REPL_INFO:node1|12|0000000009044898

2. 阻断Master和其它节点的通信

		[root@node1 pha4pgsql]# iptables -A INPUT -j DROP -s node2
		[root@node1 pha4pgsql]# iptables -A OUTPUT -j DROP -d node2
		[root@node1 pha4pgsql]# iptables -A INPUT -j DROP -s node3
		[root@node1 pha4pgsql]# iptables -A OUTPUT -j DROP -d node3

3. 等10几秒后检查集群状态

    在node1(旧Master)上查看，由于失去分布式锁，node1已经停止了部署在自身上面的所有资源。

		[root@node1 pha4pgsql]# cls_status
		Last updated: Fri Apr 22 11:34:46 2016
		Last change: Fri Apr 22 11:25:56 2016 by root via crm_resource on node1
		Stack: corosync
		Current DC: node1 (1) - partition with quorum
		Version: 1.1.12-a14efad
		2 Nodes configured
		4 Resources configured
		
		
		Online: [ node1 ]
		OFFLINE: [ node2 ]
		
		Full list of resources:
		
		 vip-master	(ocf::heartbeat:IPaddr2):	Stopped 
		 vip-slave	(ocf::heartbeat:IPaddr2):	Stopped 
		 Master/Slave Set: msPostgresql [pgsql]
		     Stopped: [ node1 node2 ]
		
		Node Attributes:
		* Node node1:
		    + #cluster-name                   	: pgcluster 
		    + #site-name                      	: pgcluster 
		    + master-pgsql                    	: -INFINITY 
		    + pgsql-data-status               	: LATEST    
		    + pgsql-status                    	: STOP      
		
		Migration summary:
		* Node node1: 
		   pgsql: migration-threshold=3 fail-count=2 last-failure='Fri Apr 22 11:34:23 2016'
		
		Failed actions:
		    pgsql_promote_0 on node1 'unknown error' (1): call=990, status=complete, exit-reason='none', last-rc-change='Fri Apr 22 11:34:15 2016', queued=0ms, exec=7756ms
		
		
		pgsql_REPL_INFO:node1|12|0000000009044898


    在node2上查看，发现node2已经被提升为新Master，PostgreSQL的时间线也从12增长到了13。

		[root@node2 ~]# cls_status
		Last updated: Sun May  8 01:02:04 2016
		Last change: Sun May  8 00:57:47 2016 by root via crm_resource on node1
		Stack: corosync
		Current DC: node2 (2) - partition with quorum
		Version: 1.1.12-a14efad
		2 Nodes configured
		4 Resources configured
		
		
		Online: [ node2 ]
		OFFLINE: [ node1 ]
		
		Full list of resources:
		
		 vip-master	(ocf::heartbeat:IPaddr2):	Started node2 
		 vip-slave	(ocf::heartbeat:IPaddr2):	Stopped 
		 Master/Slave Set: msPostgresql [pgsql]
		     Masters: [ node2 ]
		     Stopped: [ node1 ]
		
		Node Attributes:
		* Node node2:
		    + #cluster-name                   	: pgcluster 
		    + #site-name                      	: pgcluster 
		    + master-pgsql                    	: 1000      
		    + pgsql-data-status               	: LATEST    
		    + pgsql-master-baseline           	: 0000000009045828
		    + pgsql-status                    	: PRI       
		
		Migration summary:
		* Node node2: 
		
		pgsql_REPL_INFO:node2|13|0000000009045828

    请注意，这时发生了网络分区，node1和node2各自保存的集群状态是不同的。

4. 恢复node1上的网络

		[root@node1 pha4pgsql]# iptables -F

5. 再次在node1上检查集群状态    
    再次在node1上检查集群状态，发现node1和node2两个分区合并后，集群采纳了node2的配置而不是node1，这正是我们想要的（由于node2上的集群配置的版本更高，所以采纳node2而不是node1的配置)。同时，Pacemaker试图重新启动node1上的PostgreSQL进程时，发现它的最近一次checkpoint位置大于等于上次时间线提升的位置，不能作为Slave连到新Master上所以报错并阻止它上线。

		[root@node1 pha4pgsql]# cls_status
		Last updated: Fri Apr 22 11:49:44 2016
		Last change: Sun May  8 00:57:47 2016 by root via crm_resource on node1
		Stack: corosync
		Current DC: node2 (2) - partition with quorum
		Version: 1.1.12-a14efad
		2 Nodes configured
		4 Resources configured
		
		
		Online: [ node1 node2 ]
		
		Full list of resources:
		
		 vip-master	(ocf::heartbeat:IPaddr2):	Started node2 
		 vip-slave	(ocf::heartbeat:IPaddr2):	Started node1 
		 Master/Slave Set: msPostgresql [pgsql]
		     Masters: [ node2 ]
		     Stopped: [ node1 ]
		
		Node Attributes:
		* Node node1:
		    + #cluster-name                   	: pgcluster 
		    + #site-name                      	: pgcluster 
		    + master-pgsql                    	: -INFINITY 
		    + pgsql-data-status               	: DISCONNECT
		    + pgsql-status                    	: STOP      
		* Node node2:
		    + #cluster-name                   	: pgcluster 
		    + #site-name                      	: pgcluster 
		    + master-pgsql                    	: 1000      
		    + pgsql-data-status               	: LATEST    
		    + pgsql-master-baseline           	: 0000000009045828
		    + pgsql-status                    	: PRI       
		
		Migration summary:
		* Node node2: 
		* Node node1: 
		   pgsql: migration-threshold=3 fail-count=1000000 last-failure='Sun May  8 01:12:57 2016'
		
		Failed actions:
		    pgsql_start_0 on node1 'unknown error' (1): call=1022, status=complete, exit-reason='The master's timeline forked off current database system timeline 13 before latest checkpoint location 0000000009045828, REPL_IN', last-rc-change='Fri Apr 22 11:49:35 2016', queued=0ms, exec=2123ms
		
		
		pgsql_REPL_INFO:node2|13|0000000009045828


6. 修复node1(旧Master)
 
    修复node1(旧Master)的方法和前面一样，可使用cls_repair_slave、cls_repair_by_pg_rewind，或者直接使用pg_basebackup、pg_rewind，。

		[root@node1 pha4pgsql]# cls_repair_slave 
		connected to server
		servers diverged at WAL position 0/9045828 on timeline 13
		rewinding from last common checkpoint at 0/9045780 on timeline 13
		reading source file list
		reading target file list
		reading WAL in target
		need to copy 211 MB (total source directory size is 229 MB)
		216927/216927 kB (100%) copied
		creating backup label and updating control file
		syncing target data directory
		Done!
		All resources/stonith devices successfully cleaned up
		wait for recovery complete
		..........
		slave recovery of node1 successed

### Slave上的PostgreSQL进程故障
1. 强制杀死Slave上的postgres进程

		[root@node2 pha4pgsql]# killall postgres

2. 检查集群状态   
    由于设置了migration-threshold="3"，发生一次普通的错误，Pacemaker会在原地重新启动postgres进程。

		[root@node2 ~]# cls_status
		Last updated: Sun May  8 01:34:36 2016
		Last change: Sun May  8 01:33:01 2016 by root via crm_resource on node1
		Stack: corosync
		Current DC: node2 (2) - partition with quorum
		Version: 1.1.12-a14efad
		2 Nodes configured
		4 Resources configured
		
		
		Online: [ node1 node2 ]
		
		Full list of resources:
		
		 vip-master	(ocf::heartbeat:IPaddr2):	Started node1 
		 vip-slave	(ocf::heartbeat:IPaddr2):	Started node2 
		 Master/Slave Set: msPostgresql [pgsql]
		     Masters: [ node1 ]
		     Slaves: [ node2 ]
		
		Node Attributes:
		* Node node1:
		    + #cluster-name                   	: pgcluster 
		    + #site-name                      	: pgcluster 
		    + master-pgsql                    	: 1000      
		    + pgsql-data-status               	: LATEST    
		    + pgsql-master-baseline           	: 00000000090650F8
		    + pgsql-status                    	: PRI       
		* Node node2:
		    + #cluster-name                   	: pgcluster 
		    + #site-name                      	: pgcluster 
		    + master-pgsql                    	: 100       
		    + pgsql-data-status               	: STREAMING|SYNC
		    + pgsql-status                    	: HS:sync   
		
		Migration summary:
		* Node node2: 
		   pgsql: migration-threshold=3 fail-count=1 last-failure='Sun May  8 01:32:44 2016'
		* Node node1: 
		
		Failed actions:
		    pgsql_monitor_4000 on node2 'not running' (7): call=227, status=complete, exit-reason='none', last-rc-change='Sun May  8 01:32:44 2016', queued=0ms, exec=0ms
		
		
		pgsql_REPL_INFO:node1|14|00000000090650F8

3. 再强制杀死Master上的postgres进程2次后检查集群状态。

    fail-count增加到3后，Pacemaker不再启动PostgreSQL，保持其为停止状态。

		[root@node2 ~]# cls_status
		Last updated: Sun May  8 01:36:16 2016
		Last change: Sun May  8 01:36:07 2016 by root via crm_resource on node1
		Stack: corosync
		Current DC: node2 (2) - partition with quorum
		Version: 1.1.12-a14efad
		2 Nodes configured
		4 Resources configured
		
		
		Online: [ node1 node2 ]
		
		Full list of resources:
		
		 vip-master	(ocf::heartbeat:IPaddr2):	Started node1 
		 vip-slave	(ocf::heartbeat:IPaddr2):	Stopped 
		 Master/Slave Set: msPostgresql [pgsql]
		     Masters: [ node1 ]
		     Stopped: [ node2 ]
		
		Node Attributes:
		* Node node1:
		    + #cluster-name                   	: pgcluster 
		    + #site-name                      	: pgcluster 
		    + master-pgsql                    	: 1000      
		    + pgsql-data-status               	: LATEST    
		    + pgsql-master-baseline           	: 00000000090650F8
		    + pgsql-status                    	: PRI       
		* Node node2:
		    + #cluster-name                   	: pgcluster 
		    + #site-name                      	: pgcluster 
		    + master-pgsql                    	: -INFINITY 
		    + pgsql-data-status               	: DISCONNECT
		    + pgsql-status                    	: STOP      
		
		Migration summary:
		* Node node2: 
		   pgsql: migration-threshold=3 fail-count=3 last-failure='Sun May  8 01:36:08 2016'
		* Node node1: 
		
		Failed actions:
		    pgsql_monitor_4000 on node2 'not running' (7): call=240, status=complete, exit-reason='none', last-rc-change='Sun May  8 01:36:08 2016', queued=0ms, exec=0ms
		
		
		pgsql_REPL_INFO:node1|14|00000000090650F8

    同时，Master(node1)上的复制模式被自动切换到异步复制，防止写操作hang住。

		[root@node1 pha4pgsql]# tail /var/lib/pgsql/tmp/rep_mode.conf
		synchronous_standby_names = ''

4. 修复Salve   
    在node2上执行cls_cleanup，清除fail-count后，Pacemaker会再次启动PostgreSQL进程。

		[root@node2 ~]# cls_cleanup 
		All resources/stonith devices successfully cleaned up
		[root@node2 ~]# cls_status 
		Last updated: Sun May  8 01:43:13 2016
		Last change: Sun May  8 01:43:08 2016 by root via crm_resource on node1
		Stack: corosync
		Current DC: node2 (2) - partition with quorum
		Version: 1.1.12-a14efad
		2 Nodes configured
		4 Resources configured
		
		
		Online: [ node1 node2 ]
		
		Full list of resources:
		
		 vip-master	(ocf::heartbeat:IPaddr2):	Started node1 
		 vip-slave	(ocf::heartbeat:IPaddr2):	Started node2 
		 Master/Slave Set: msPostgresql [pgsql]
		     Masters: [ node1 ]
		     Slaves: [ node2 ]
		
		Node Attributes:
		* Node node1:
		    + #cluster-name                   	: pgcluster 
		    + #site-name                      	: pgcluster 
		    + master-pgsql                    	: 1000      
		    + pgsql-data-status               	: LATEST    
		    + pgsql-master-baseline           	: 00000000090650F8
		    + pgsql-status                    	: PRI       
		* Node node2:
		    + #cluster-name                   	: pgcluster 
		    + #site-name                      	: pgcluster 
		    + master-pgsql                    	: 100       
		    + pgsql-data-status               	: STREAMING|SYNC
		    + pgsql-status                    	: HS:sync   
		
		Migration summary:
		* Node node2: 
		* Node node1: 
		
		pgsql_REPL_INFO:node1|14|00000000090650F8

    同时，Master(node1)上的复制模式又自动切换回到同步复制。

		[root@node1 pha4pgsql]# tail /var/lib/pgsql/tmp/rep_mode.conf
		synchronous_standby_names = 'node2'

## 多节点集群的设置

参考pha4pgsql\template\config_muti.ini.sample的例子，编辑config.ini

	pcs_template=muti.pcs.template
	OCF_ROOT=/usr/lib/ocf
	RESOURCE_LIST="msPostgresql vip-master vip-slave"
	pha4pgsql_dir=/opt/pha4pgsql
	writer_vip=192.168.41.136
	reader_vip=192.168.41.137
	node1=node1
	node2=node2
	node3=node3
	vip_nic=eno33554984
	vip_cidr_netmask=24
	pgsql_pgctl=/usr/pgsql-9.5/bin/pg_ctl
	pgsql_psql=/usr/pgsql-9.5/bin/psql
	pgsql_pgdata=/data/postgresql/data
	pgsql_pgport=5433
	pgsql_restore_command=""
	pgsql_rep_mode=sync
	pgsql_repuser=replication
	pgsql_reppassord=replication
	pgsql_enable_distlock=false
	pgsql_distlock_psql_cmd='/usr/bin/psql \\"host=node3 port=5439 dbname=postgres user=postgres connect_timeout=5\\"'
	pgsql_distlock_lockname=pgsql_cls1

然后执行安装和配置

	sh install.sh

生成的资源配置如下，可以根据情况修改：

	[root@node1 pha4pgsql]# cat config.pcs 
	
	pcs cluster cib pgsql_cfg
	
	pcs -f pgsql_cfg property set no-quorum-policy="stop"
	pcs -f pgsql_cfg property set stonith-enabled="false"
	pcs -f pgsql_cfg resource defaults resource-stickiness="1"
	pcs -f pgsql_cfg resource defaults migration-threshold="10"
	
	pcs -f pgsql_cfg resource create vip-master IPaddr2 \
	   ip="192.168.41.136" \
	   nic="eno33554984" \
	   cidr_netmask="24" \
	   op start   timeout="60s" interval="0s"  on-fail="restart" \
	   op monitor timeout="60s" interval="10s" on-fail="restart" \
	   op stop    timeout="60s" interval="0s"  on-fail="block"
	
	pcs -f pgsql_cfg resource create vip-slave IPaddr2 \
	   ip="192.168.41.137" \
	   nic="eno33554984" \
	   cidr_netmask="24" \
	   op start   timeout="60s" interval="0s"  on-fail="restart" \
	   op monitor timeout="60s" interval="10s" on-fail="restart" \
	   op stop    timeout="60s" interval="0s"  on-fail="block"
	   
	pcs -f pgsql_cfg resource create pgsql expgsql \
	   pgctl="/usr/pgsql-9.5/bin/pg_ctl" \
	   psql="/usr/pgsql-9.5/bin/psql" \
	   pgdata="/data/postgresql/data" \
	   pgport="5433" \
	   rep_mode="sync" \
	   node_list="node1 node2 node3 " \
	   restore_command="" \
	   primary_conninfo_opt="user=replication password=replication keepalives_idle=60 keepalives_interval=5 keepalives_count=5" \
	   master_ip="192.168.41.136" \
	   restart_on_promote="false" \
	   enable_distlock="false" \
	   distlock_lock_cmd="/opt/pha4pgsql/tools/distlock '' lock distlock:pgsql_cls1 @owner 9 12" \
	   distlock_unlock_cmd="/opt/pha4pgsql/tools/distlock '' unlock distlock:pgsql_cls1 @owner" \
	   distlock_lockservice_deadcheck_nodelist="node1 node2 node3 " \
	   op start   timeout="60s" interval="0s"  on-fail="restart" \
	   op monitor timeout="60s" interval="4s" on-fail="restart" \
	   op monitor timeout="60s" interval="3s"  on-fail="restart" role="Master" \
	   op promote timeout="60s" interval="0s"  on-fail="restart" \
	   op demote  timeout="60s" interval="0s"  on-fail="stop" \
	   op stop    timeout="60s" interval="0s"  on-fail="block" \
	   op notify  timeout="60s" interval="0s"
	
	pcs -f pgsql_cfg resource master msPostgresql pgsql \
	   master-max=1 master-node-max=1 clone-node-max=1 notify=true \
	   migration-threshold="3" target-role="Master"
	
	pcs -f pgsql_cfg constraint colocation add vip-master with Master msPostgresql INFINITY
	pcs -f pgsql_cfg constraint order promote msPostgresql then start vip-master symmetrical=false score=INFINITY
	pcs -f pgsql_cfg constraint order demote  msPostgresql then stop  vip-master symmetrical=false score=0
	
	pcs -f pgsql_cfg constraint colocation add vip-slave with Slave msPostgresql INFINITY
	pcs -f pgsql_cfg constraint order promote  msPostgresql then start vip-slave symmetrical=false score=INFINITY
	pcs -f pgsql_cfg constraint order stop msPostgresql then stop vip-slave symmetrical=false score=0
	
	pcs cluster cib-push pgsql_cfg

确定资源定义后进行配置

	./setup.sh

## 错误排查
出现故障时，可通过以下方法排除故障

1. 确认集群服务是否OK

		pcs status
   
2. 查看错误日志

		PostgreSQL的错误日志
		/var/log/messages
		/var/log/cluster/corosync.log

	Pacemaker输出的日志非常多，可以进行过滤。

	只看Pacemaker的资源调度（在Current DC节点上执行)：
	
		grep Initiating /var/log/messages 
	
	只查看expgsql RA的输出：
	
		grep expgsql /var/log/messages

##其它故障的处理
### 无Master时的修复

如果切换失败或其它原因导致集群中没有Master，可以参考下面的步骤修复

#### 方法1：使用cleanup修复

	cls_cleanup

大部分情况，cleanup就可以找到Master。而且应该首先使用cleanup。如果不成功，再采用下面的方法

#### 方法2：人工修复复制关系
1. 将资源脱离集群管理

		cls_unmanage

2. 人工修复PostgreSQL，建立复制关系
   至于master的选取，可以选择pgsql_REPL_INFO中的master节点，或根据xlog位置确定。
3. 在所有节点上停止PostgreSQL
4. 清除状态并恢复集群管理

		cls_manage
		cls_reset_master

#### 方法3：快速恢复Master节点再恢复Slave
可以明确指定将哪个节点作为Master，省略则通过xlog位置比较确定master

	cls_reset_master [master]


### 疑难的Pacemaker问题的处理
有时候可能会遇到一些顽固的问题，Pacemaker不按期望的动作，或某个资源处于错误状态却无法清除。
这时最简单的办法就是清除CIB重新设置。可执行下面的命令完成。

	./setup.sh [master]

如果不指定master，并且PostgreSQL进程是活动的，通过当前PostgreSQL进程的主备关系决定谁是master。
如果当前没有处于主的PostgreSQL进程，通过比较xlog位置确定谁作为master。

在PostgreSQL服务启动期间，正常情况下，执行setup.sh不会使服务停止。

setup.sh还可以完全取代前面的cls_reset_master。

### fail-count的清除
如果某个节点上有资源的fail-count不为0，最好将其清除，即使当前资源是健康的。

	cls_cleanup

## 注意事项
1. ./setup.sh会清除CIB，对Pacemaker资源定义的修改应该写到config.pcs里，防止下次执行setup.sh丢失。
2. 有些包装后的脚本容易超时，比如cls_rebuild_slave。此时可能执行还没有完成的，需要通过cls_status或日志进行确认。

 
## 附录1：对pgsql RA的修改
本项目使用的expgsql RA是在Resource Agent 3.9.7中的pgsql RA的基础上做的修改。修改内容如下：

1. 引入分布式锁服务防止双节点集群出现脑裂，并防止在failover过程中丢失数据。   
promote和monitor的同步复制切换为异步复制前都需要先获取锁，因此确保这两件事不能同时发生，也就防止了在同步复制模式下failover出现数据丢失。相应的引入以下参数：

	- enable_distlock   
	    是否启动分布式锁仲裁，对双节集群建议启用。
	- distlock_lock_cmd   
	    分布式锁服务的加锁命令
	- distlock_unlock_cmd   
	    分布式锁服务的解锁命令
	- distlock_lockservice_deadcheck_nodelist   
		无法访问分布式锁服务时，需要做二次检查的节点列表，通过ssh连接到这些节点后再获取锁。如果节点列表中所有节点都无法访问分布式锁服务，认为分布式锁服务失效，按已获得锁处理。如果节点列表中任何一个节点本身无法访问，按未获得锁处理。

    并且内置了一个基于PostgreSQL的分布式锁实现，即tools\distlock。

    在网络不稳定的极端情况下，主从分区后可能一会只有Master可以连上分布式锁服务，一会只有Slave可以连上分布式锁服务，导致在一个很偶然的小时间窗口内出现双主而且是异步复制，当然这种场景发生的概率极低。


2. 根据Master是否发生变更动态采取restart或pg_ctl promote的方式提升Slave为Master。    
	当Master发生变更时采用pg_ctl promote的方式提升Slave为Master；未发生变更时采用restart的方式提升。
	相应地废弃原pgsql RA的restart_on_promote参数。

3. 记录PostgreSQL上次时间线切换前的时间线和xlog位置信息    
	这些信息记录在集群配置变量pgsql_REPL_INFO中。pgsql_REPL_INFO的值由以下3个部分组成,通过‘|’连接在一起。
	
	- Master节点名
	- pg_ctl promote前的时间线
	- pg_ctl promote前的时间线的结束位置
	
	RA启动时，会检查当前节点和pgsql_REPL_INFO中记录的状态是否有冲突，如有报错不允许资源启动。
	因为有这个检查废弃原pgsql RA的PGSQL.lock锁文件。

4. 资源启动时通过pgsql_REPL_INFO中记录的Master节点名，继续沿用原Master。   
   通过这种方式加速集群的启动，并避免不必要的主从切换。集群仅在初始启动pgsql_REPL_INFO的值为空时，才通过xlog比较确定哪个节点作为Master。

关于pgsql RA的原始功能请参考：[PgSQL Replicated Cluster](http://clusterlabs.org/wiki/PgSQL_Replicated_Cluster)

## 附录2：参考
- [PostgreSQL流复制高可用的原理与实践](http://www.postgres.cn/news/viewone/1/124)
- [PgSQL Replicated Cluster](http://clusterlabs.org/wiki/PgSQL_Replicated_Cluster)
- [Pacemaker+Corosync搭建PostgreSQL集群](http://my.oschina.net/aven92/blog/518928)
