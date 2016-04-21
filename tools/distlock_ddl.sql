create table if not exists distlock(lockname text primary key,owner text not null,ts timestamptz not null,expired_time interval not null);

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
	