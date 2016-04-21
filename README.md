
# Pacemaker High Availability for PostgreSQL

## 简介
原生的基于Pacemaker搭建PostgreSQL HA集群存在设置参数众多，不易使用的问题。本项目在Resource Agent 3.9.7的pgsql RA的基础上进行了增强，并封装了常用的集群操作命令。目的在于简化PostgreSQL流复制HA的部署和使用，并且尽可能确保failover后的数据不丢失。


## 功能特性
1. 秒级故障转移
2. 支持同步复制和异步复制
3. 同步复制下failover零数据丢失
4. 支持双机集群和多机集群
5. 初始启动时自动比较数据新旧确定主备关系
6. 基于VIP的读写分离


## 对pgsql RA的修改
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

2. 根据Master是否发生变更动态采取restart或pg_ctl promote的方式提升Slave为Master。    
	当Master发生变更时采用pg_ctl promote的方式提升Slave为Master；未发生变更时采用restart的方式提升。
	相应地废弃原pgsql RA的restart_on_promote参数

3. 记录PostgreSQL上次时间线切换前的时间线和xlog位置信息    
	这些信息记录在集群配置变量pgsql_REPL_INFO中。
	
	pgsql_REPL_INFO的值由以下3个部分组成,通过‘|’连接在一起。
	
	- Master节点名
	- pg_ctl promote前的时间线
	- pg_ctl promote前的时间线的结束位置
	
	RA启动时，会检查当前节点和pgsql_REPL_INFO中记录的状态是否有冲突，如有报错。
	因为有这个检查废弃原pgsql RA的PGSQL.lock锁文件。

4. 资源启动时通过pgsql_REPL_INFO中记录的Master节点名，继续沿用原Master。   
通过这种方式加速集群的启动，并避免不必要的主从切换。集群仅在初始启动pgsql_REPL_INFO的值为空时，在通过xlog比较确定哪个节点作为Master。

关于pgsql RA的原始功能请参考：[PgSQL Replicated Cluster](http://clusterlabs.org/wiki/PgSQL_Replicated_Cluster)

## 集群操作命令一览
1. cls_start  
   启动集群
2. cls_stop   
   停止集群
3. cls_online_switch      
   在线主从切换
4. cls_master   
   输出当前Master节点名
5. cls_status   
   显示集群状态
6. cls_cleanup   
   清除资源状态和failcount。在某个节点上资源失败次数(failcount)超过3次Pacemaker将不再分配该资源到此节点，人工修复故障后需要调用cleanup让Pacemkaer重新尝试启动资源。
7. cls_recovery_master   
   清除pgsql_REPL_INFO和每个节点的pgsql-data-status，让Pacemaker重新在所有节点中选出xlog位置最新的节点作为Master。仅用于集群中没有任何节点满足Master条件情况下的紧急修复。
8. cls_repair_slave   
   通过pg_rewind修复当前节点，主要用于旧Master的修复，回退超出时间线分叉的那部分更新，并和新Master建立复制关系。
9. cls_rebuild_slave   
   通过pg_basebackup在当前节点重建Slave。执行该命令前需要停止当前节点上的PostgreSQL进程并删除旧的数据目录。
10. cls_unmanage   
   unmanage所有资源脱离Pacemaker的控制。当需要重启Pacemaker和Corosync又不能停止PostgreSQL服务时，可以先调用这个命令，Pacemaker和Corosync重启完成后再用cls_manage恢复管理。
11. cls_manage   
   恢复cls_unmanage产生的资源unmanaged状态。
12. cls_standby_node <nodename>   
   释放某节点上所有资源。可用于特定节点的维护，比如升级。
13. cls_unstandby_node <nodename>   
   恢复cls_standby_node产生的节点standby状态。


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
2. 所有节点设置独立的主机名(node1，node2)
3. 设置对所有节点的域名解析(修改/etc/hosts)
4. 所有节点间设置SSH互信

#### 禁用防火墙 
在所有节点执行：

	setenforce 0
	sed -i.bak "s/SELINUX=enforcing/SELINUX=permissive/g" /etc/selinux/config
	systemctl disable firewalld.service
	systemctl stop firewalld.service
	iptables -F

#### 安装Pacemaker和Corosync及相关软件包
在所有节点执行：

    yum install -y pacemaker pcs psmisc policycoreutils-python

注：如果OS自带的Pacemaker比较旧，建议下载新版的。之前在Pacemaker 1.1.7上遇到了不少Bug，因此不建议使用这个版本或更老的版本。

#### 启用服务
在所有节点执行：

	systemctl start corosync.service
	systemctl enable corosync.service
	systemctl start pacemaker.service
	systemctl enable pacemaker.service
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

注：PostgreSQL 9.3以上版本，应将replication_timeout替换成wal_sender_timeout；PostgreSQL 9.5以上版本，可加上"wal_log_hints = on"，使得可以使用pg_rewind修复旧Master。


4. 修改pg_hba.conf
 
		local   all                 all                              trust
		host    all                 all     192.168.41.0/24          md5
		host    replication         all     192.168.41.0/24          md5

5. 启动

		pg_ctl -D /data/postgresql/data/ start

6. 创建复制用户

		createuser --login --replication -s replication -P

注：9.5以上版本如需要支持pg_rewind，加上“-s”选项。

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

		cluster_type=dual
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
		./setup.sh

   注意，安装过程只需在一个节点上执行即可。

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


## 故障测试

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
通过pg_baseback修复旧Master

		[root@node1 pha4pgsql]# rm -rf /data/postgresql/data/*
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

		[root@node1 pha4pgsql]# cls_repair_slave 
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

## 参考
[PgSQL Replicated Cluster](http://clusterlabs.org/wiki/PgSQL_Replicated_Cluster)
[Pacemaker+Corosync搭建PostgreSQL集群](http://my.oschina.net/aven92/blog/518928)
