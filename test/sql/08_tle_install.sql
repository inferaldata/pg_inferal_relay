-- Test: TLE installation path (pgtle.install_extension)
begin;
select plan(5);

-- Install under a different name; TLE SQL has schema remapped to inferal_relay_tle
select lives_ok(
    $$select pgtle.install_extension(
        'pg_inferal_relay_tle_test',
        '0.1.0',
        'Consume LDES streams from Inferal Relay',
        pg_read_file('/tmp/pg_inferal_relay_tle.sql')
    )$$,
    'pgtle.install_extension() succeeds'
);

-- Schema is created by the extension SQL itself (CREATE SCHEMA IF NOT EXISTS)
select lives_ok(
    $$create extension pg_inferal_relay_tle_test version '0.1.0'$$,
    'CREATE EXTENSION with TLE succeeds'
);

-- Core table exists
select has_table(
    'inferal_relay_tle', 'streams',
    'streams table exists in TLE schema'
);

-- Core function exists (sync takes text + integer default)
select has_function(
    'inferal_relay_tle', 'sync', array['text', 'integer'],
    'sync(text,integer) function exists in TLE schema'
);

-- Clean up
select lives_ok(
    $$drop extension pg_inferal_relay_tle_test cascade$$,
    'DROP EXTENSION CASCADE succeeds'
);

select * from finish();
rollback;
