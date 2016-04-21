#!/usr/bin/python
import psycopg2
import time

url="host=192.168.41.136 dbname=postgres user=postgres"

conn = psycopg2.connect(url)
conn.autocommit=True
cur = conn.cursor()

cur.execute("CREATE TABLE IF NOT EXISTS pgsql_ha_test(id integer PRIMARY KEY, num integer);")
cur.execute("truncate pgsql_ha_test;")
cur.execute("insert into pgsql_ha_test values(1,0);")
cur.execute("show transaction_read_only")

print "Update process had started,please kill the master..."
i=0
num=-1
try:
    while True:
        i+=1
        cur.execute("UPDATE pgsql_ha_test set num = %s where id=1",(i,))
        num=i
        if i % 1000 == 0:
            print time.time()," current num=",num

except psycopg2.Error as e:
    print time.time()," The master has down, last num=",num
    print e.pgerror
    conn.close()

time1= time.time()
connect_success = False
while connect_success == False:
    try:
        conn = psycopg2.connect(url)
        conn.autocommit=True
        connect_success=True
    except psycopg2.Error as e:
        time.sleep(1)

time2= time.time()
print time.time()," connect success after %f second"%(time2-time1)

cur = conn.cursor()
cur.execute("select num from pgsql_ha_test where id=1;")
newnum = cur.fetchone()[0]
print time.time()," the new num=",newnum

if not (newnum==num or newnum==num+1):
    print "NG: Data lost!"
    conn.close()
    exit(1)

# check if the new master support write
#cur.execute("UPDATE pgsql_ha_test set num = num where id=1")
cur.execute("show transaction_read_only")
read_only  = cur.fetchone()[0]
if "off" != read_only:
    print "NG: failover to a readony node!"
    conn.close()
    exit(1)

cur.close()
conn.close()
print "OK"

