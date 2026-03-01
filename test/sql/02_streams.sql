-- Test: Stream management and triggers
begin;
select plan(10);

-- Load mock adapter so callback stubs don't interfere
select inferal_relay.install_mock_adapter();

-- INSERT creates cursor row (trigger)
insert into inferal_relay.streams(name, base_url, stream_id)
values ('test-stream', 'https://relay.inferal.com', 'acme');

select is(
    (select count(*)::integer from inferal_relay.cursors where stream_name = 'test-stream'),
    1,
    'INSERT into streams auto-creates cursor row'
);

select is(
    (select last_event_id from inferal_relay.cursors where stream_name = 'test-stream'),
    null,
    'New cursor has NULL last_event_id'
);

select is(
    (select pages_fetched from inferal_relay.cursors where stream_name = 'test-stream'),
    0::bigint,
    'New cursor has 0 pages_fetched'
);

-- Default values
select is(
    (select facet from inferal_relay.streams where name = 'test-stream'),
    'snapshots',
    'Default facet is snapshots'
);

select is(
    (select page_limit from inferal_relay.streams where name = 'test-stream'),
    100,
    'Default page_limit is 100'
);

-- UPDATE sets updated_at (trigger)
-- First record the original updated_at
select pg_sleep(0.01);  -- Ensure clock advances
update inferal_relay.streams set page_limit = 50 where name = 'test-stream';

select ok(
    (select updated_at > created_at from inferal_relay.streams where name = 'test-stream'),
    'UPDATE trigger sets updated_at > created_at'
);

-- DELETE cascades to cursor
delete from inferal_relay.streams where name = 'test-stream';

select is(
    (select count(*)::integer from inferal_relay.cursors where stream_name = 'test-stream'),
    0,
    'DELETE cascades to cursors'
);

-- CHECK constraint: bad URL
select throws_ok(
    $$insert into inferal_relay.streams(name, base_url, stream_id)
      values ('bad-url', 'ftp://invalid', 'acme')$$,
    '23514',  -- check_violation
    null,
    'Rejects non-HTTP base_url'
);

-- CHECK constraint: page_limit too low
select throws_ok(
    $$insert into inferal_relay.streams(name, base_url, stream_id, page_limit)
      values ('bad-limit-low', 'https://example.com', 'acme', 0)$$,
    '23514',
    null,
    'Rejects page_limit of 0'
);

-- CHECK constraint: page_limit too high
select throws_ok(
    $$insert into inferal_relay.streams(name, base_url, stream_id, page_limit)
      values ('bad-limit-high', 'https://example.com', 'acme', 10001)$$,
    '23514',
    null,
    'Rejects page_limit over 10000'
);

select * from finish();
rollback;
