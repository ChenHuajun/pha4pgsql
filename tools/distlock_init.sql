
delete from distlock where lockname = :'lockname';

insert into distlock(lockname, owner, ts, expired_time, allow_failover) values(:'lockname', '', now(), interval '-1 second', false);