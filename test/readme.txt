MySQL HA 故障恢复回归测试集使用说明

yum install python-psycopg2

环境准备
1. 配置3节点HA集群
2. 准备专门的测试机，并分别配置3个HA节点对测试机的ssh信任
3. 在测试机的/etc/hosts中追加3台HA节点的名称解析
4. 拷贝测试脚本到测试机的测试目录(比如/opt/mysql_ha_test)
5. 设置测试脚本的执行权限
    chmod +x *.sh *.py
6. 从某个HA节点上拷贝/opt/mysql_ha/config.ini到测试机的测试目录

使用方法
执行故障恢复的全体回归测试
test_failover.sh

长时间运行测试
nohup ./rt.sh 测试次数 &
查看日志了解测试结果
tail -f rt.log 
tail -f monitor_dataloss.log

列出所有测试case
test_failover.sh -h

执行故障恢复的单个测试
test_failover.sh 测试case名
比如:
test_failover.sh test_master_mysql_crash

为更好的模拟真实场景，在回归测试过程中，可同时使用sysbench等工具对MySQL进行压测，并启动monitor_dataloss.sh脚本，检查failover前后有无数据丢失。



辅助脚本
check_1m1s.sh
  检查当前HA集群是否处于1主1从的健康状态。
  
check_1m2s.sh
  检查当前HA集群是否处于1主2从的健康状态。

check_dataloss_during_failover.py
  通过写VIP不间断更新数据测量故障转移的时间以及是否有数据丢失。
  
check_dataloss_during_failover_by_read.py
  通过写VIP不间断读取数据检查故障转移后有无数据丢失。必须在failover_test_MySQL.py运行期间并发执行该脚本。
注：低于MySQL 5.7的版本是不能保证不丢数据的。
  
monitor_dataloss.sh
  对check_dataloss_during_failover.py的循环调用，用于RT时不间断监视failover是否会导致数据丢失。

monitor_vip.sh
  监视通过写VIP和读VIP访问HA集群的健康状况。

fire_fault.sh
  用于手动触发指定HA节点故障

  

故障排查
测试集运行的输出中如果包含"NG"的case，需要调查原因。可考虑以下手段进行调查

1. 检查Paceamker的输出日志
vi /var/log/messages
或
vi /var/log/cluster/corosync.log

但是Pacemaker的输出非常多，作为概要可在当前DC节点上检查Paceamker发出的所有指令
tail -f /var/log/messages |grep Initiating

"当前DC节点"是哪一个，可通过crm status输出中的"Current DC"查看。
比如:
[root@srdsdevapp71 ~]# crm status
============
Last updated: Tue Jan 19 14:56:18 2016
Last change: Tue Jan 19 12:02:37 2016 via crm_resource on srdsdevapp73
Stack: openais
Current DC: srdsdevapp73 - partition with quorum
Version: 1.1.7-6.el6-148fccfd5985c5590cc601123c6c16e966b85d14
3 Nodes configured, 3 expected votes
9 Resources configured.
============

Online: [ srdsdevapp71 srdsdevapp73 srdsdevapp69 ]

 vip-write	(ocf::heartbeat:IPaddr2):	Started srdsdevapp69
 lvsdr	(ocf::heartbeat:lvsdr):	Started srdsdevapp73
 vip-read	(ocf::heartbeat:IPaddr2):	Started srdsdevapp73
 Master/Slave Set: msMysql [mysql]
     Masters: [ srdsdevapp69 ]
     Slaves: [ srdsdevapp71 srdsdevapp73 ]
 Clone Set: clone-lvsdr-realsvr [lvsdr-realsvr]
     Started: [ srdsdevapp73 srdsdevapp71 ]
     Stopped: [ lvsdr-realsvr:2 ]

2. 检查MHA切换日志
/opt/mha/log/manager.log
/opt/mha/log/online_switch.log

3. 检查MySQL错误日志

4. 检查mysql 资源代理的debug输出
预先打开mysql 资源代理的debug输出
mkdir -p /tmp/mysql.ocf.ra.debug
touch /tmp/mysql.ocf.ra.debug/log
chmod a+w /tmp/mysql.ocf.ra.debug/log

然后检查debug输出文件
vi /tmp/mysql.ocf.ra.debug/log

