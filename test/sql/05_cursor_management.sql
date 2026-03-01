-- Test: Cursor management
begin;
select plan(7);

select inferal_relay.install_mock_adapter();

-- Create test stream (trigger creates cursor)
insert into inferal_relay.streams(name, base_url, stream_id)
values ('cursor-test', 'https://relay.inferal.com', 'acme');

-- _advance_cursor updates fields
select inferal_relay._advance_cursor('cursor-test', '018f0001', '3s.abcd', 5);

select is(
    (select last_event_id from inferal_relay.cursors where stream_name = 'cursor-test'),
    '018f0001',
    '_advance_cursor sets last_event_id'
);

select is(
    (select partition_hint from inferal_relay.cursors where stream_name = 'cursor-test'),
    '3s.abcd',
    '_advance_cursor sets partition_hint'
);

select ok(
    (select last_synced_at is not null from inferal_relay.cursors where stream_name = 'cursor-test'),
    '_advance_cursor sets last_synced_at'
);

select is(
    (select pages_fetched from inferal_relay.cursors where stream_name = 'cursor-test'),
    1::bigint,
    '_advance_cursor increments pages_fetched'
);

-- Counter accumulation: advance again
select inferal_relay._advance_cursor('cursor-test', '018f0002', '3s.efgh', 10);

select is(
    (select pages_fetched from inferal_relay.cursors where stream_name = 'cursor-test'),
    2::bigint,
    '_advance_cursor accumulates pages_fetched'
);

select is(
    (select members_received from inferal_relay.cursors where stream_name = 'cursor-test'),
    15::bigint,
    '_advance_cursor accumulates members_received (5 + 10)'
);

-- reset_cursor clears state
select inferal_relay.reset_cursor('cursor-test');

select is(
    (select last_event_id from inferal_relay.cursors where stream_name = 'cursor-test'),
    null,
    'reset_cursor clears last_event_id'
);

select * from finish();
rollback;
