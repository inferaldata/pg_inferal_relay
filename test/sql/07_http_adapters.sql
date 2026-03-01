-- Test: HTTP adapters against live endpoints (integration, requires network)
begin;
select plan(9);

-- ====================================================================
-- pgsql-http adapter
-- ====================================================================

select inferal_relay.install_pgsql_http_adapter();

select is(
    ((inferal_relay.http_get('https://www.example.com')) ->> 'status')::integer,
    200,
    'pgsql-http: GET example.com returns 200'
);

select ok(
    (inferal_relay.http_get('https://www.example.com')) ->> 'body' like '%Example Domain%',
    'pgsql-http: response body contains expected content'
);

-- Non-existent path returns 404
select is(
    ((inferal_relay.http_get('https://httpbin.org/status/404')) ->> 'status')::integer,
    404,
    'pgsql-http: 404 status propagated correctly'
);

-- ====================================================================
-- pg_net adapter (uses dblink bridge)
-- ====================================================================

select inferal_relay.install_pg_net_adapter();

select is(
    ((inferal_relay.http_get('https://www.example.com')) ->> 'status')::integer,
    200,
    'pg_net: GET example.com returns 200'
);

select ok(
    (inferal_relay.http_get('https://www.example.com')) ->> 'body' like '%Example Domain%',
    'pg_net: response body contains expected content'
);

select is(
    ((inferal_relay.http_get('https://httpbin.org/status/404')) ->> 'status')::integer,
    404,
    'pg_net: 404 status propagated correctly'
);

-- ====================================================================
-- pg_curl adapter
-- ====================================================================

select inferal_relay.install_pg_curl_adapter();

select is(
    ((inferal_relay.http_get('https://www.example.com')) ->> 'status')::integer,
    200,
    'pg_curl: GET example.com returns 200'
);

select ok(
    (inferal_relay.http_get('https://www.example.com')) ->> 'body' like '%Example Domain%',
    'pg_curl: response body contains expected content'
);

select is(
    ((inferal_relay.http_get('https://httpbin.org/status/404')) ->> 'status')::integer,
    404,
    'pg_curl: 404 status propagated correctly'
);

select * from finish();
rollback;
