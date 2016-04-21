#!/usr/bin/python
import os, re, time, MySQLdb

config_file = 'config.ini'
if not os.path.exists(config_file):
    print("file %s does not exist, exit" %(config_file))
    exit(1)

f = open(config_file)
data = re.sub(' *=[ *]', '=', f.read())
CONFIG_INFO = dict([str.strip().split('=') for str in data.split('\n') if re.search('=', str)])

for k in CONFIG_INFO:
    var=CONFIG_INFO[k]
    if (type(var) == type('') and len(var) >=2 and var[0] == '"' and var[len(var)-1] == '"'):
        CONFIG_INFO[k]=var[1:len(var)-1]

host=CONFIG_INFO['writer_vip']
host_read=CONFIG_INFO['reader_vip']
user=CONFIG_INFO['mysql_replication_user']
passwd=CONFIG_INFO['mysql_replication_passwd']
db='test'
port=int(CONFIG_INFO['port'])

conn = MySQLdb.connect(host=host,user=user,passwd=passwd,db=db,port=port)
conn.autocommit(True)
cur = conn.cursor()

cur.execute("CREATE TABLE IF NOT EXISTS mysql_ha_test(id integer PRIMARY KEY, num integer);")
cur.execute("truncate mysql_ha_test;")
#cur.execute("insert into mysql_ha_test values(1,0);")

print "Update process had started,please kill the master..."
i=0
num=-1
try:
    while True:
        i+=1
        #cur.execute("UPDATE mysql_ha_test set num = %s where id=1",(i,))
        cur.execute("insert into mysql_ha_test values(%s,%s)",(i,i,))
        num=i
        if i % 1000 == 0:
            print time.time()," current num=",num

except MySQLdb.Error as e:
    print time.time()," The master has down, last num=",num
    print e
    conn.close()

#check the new master
time1= time.time()
connect_success = False
while connect_success == False:
    try:
        conn = MySQLdb.connect(host=host,user=user,passwd=passwd,db=db,port=port)
        conn.autocommit(True)
        connect_success=True
    except MySQLdb.Error as e:
        time.sleep(1)

time2= time.time()
print time.time()," connect success after %f second"%(time2-time1)

cur = conn.cursor()
cur.execute("select count(*) from mysql_ha_test")
newnum = cur.fetchone()[0]
print time.time()," the new num=",newnum

if not (newnum==num or newnum==num+1):
    print "NG: Data lost in the new master!"
    conn.close()
    exit(1)

cur.close()
conn.close()

#check slave
time1= time.time()
connect_success = False
while connect_success == False:
    try:
        conn = MySQLdb.connect(host=host_read,user=user,passwd=passwd,db=db,port=port)
        conn.autocommit(True)
        connect_success=True
    except MySQLdb.Error as e:
        time.sleep(1)

time2= time.time()
print time.time()," connect to read vip success after %f second"%(time2-time1)

cur = conn.cursor()
cur.execute("select count(*) from mysql_ha_test")
newnum = cur.fetchone()[0]
print time.time()," the new num=",newnum

if not (newnum==num or newnum==num+1):
    print "NG: Data lost in the slave!"
    conn.close()
    exit(1)

cur.close()
conn.close()

print "OK"

