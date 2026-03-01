-- Test: URL builder
begin;
select plan(5);

select inferal_relay.install_mock_adapter();

-- Create test stream
insert into inferal_relay.streams(name, base_url, stream_id, facet, page_limit)
values ('url-test', 'https://relay.inferal.com', 'acme', 'snapshots', 100);

-- Initial URL (no cursor) -- should just have limit
select is(
    inferal_relay.build_next_url('url-test'),
    'https://relay.inferal.com/streams/acme/snapshots?limit=100',
    'Initial URL has no since parameter, only limit'
);

-- With since parameter
select is(
    inferal_relay.build_next_url('url-test', '018f3b3c-4d00-7000-8000-000000000000'),
    'https://relay.inferal.com/streams/acme/snapshots?since=018f3b3c-4d00-7000-8000-000000000000&limit=100',
    'URL with since parameter'
);

-- With since + partition hint
select is(
    inferal_relay.build_next_url('url-test', '018f3b3c-4d00-7000-8000-000000000000', '3s.abcd'),
    'https://relay.inferal.com/streams/acme/snapshots?since=018f3b3c-4d00-7000-8000-000000000000&_p=3s.abcd&limit=100',
    'URL with since and partition hint'
);

-- Trailing slash in base_url is handled
insert into inferal_relay.streams(name, base_url, stream_id, page_limit)
values ('url-test-slash', 'https://relay.inferal.com/', 'acme', 50);

select is(
    inferal_relay.build_next_url('url-test-slash'),
    'https://relay.inferal.com/streams/acme/snapshots?limit=50',
    'Trailing slash in base_url is stripped'
);

-- Non-existent stream raises error
select throws_ok(
    $$select inferal_relay.build_next_url('nonexistent')$$,
    null,
    'Stream "nonexistent" not found',
    'Raises error for unknown stream'
);

select * from finish();
rollback;
