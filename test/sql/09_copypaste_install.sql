-- Test: copy-paste installation path (\i pg_inferal_relay--0.1.0.sql)
begin;
select plan(8);

-- Run the copy-paste SQL (schema remapped to inferal_relay_cp).
-- Suppress DDL notices so they don't corrupt TAP output.
\o /dev/null
\i /tmp/pg_inferal_relay_copypaste.sql
\o

-- Restore search_path so pgTAP functions are visible
set search_path to public;

-- 1. Schema created
select has_schema(
    'inferal_relay_cp',
    'copy-paste creates inferal_relay_cp schema'
);

-- 2. Core table: streams
select has_table(
    'inferal_relay_cp', 'streams',
    'streams table exists in copy-paste schema'
);

-- 3. Dependent table: cursors
select has_table(
    'inferal_relay_cp', 'cursors',
    'cursors table exists in copy-paste schema'
);

-- 4. credentials table (canary: proves install_credential_store_adapter() ran)
select has_table(
    'inferal_relay_cp', 'credentials',
    'credentials table exists (install_credential_store_adapter ran)'
);

-- 5. Core function: sync(text, integer)
select has_function(
    'inferal_relay_cp', 'sync', array['text', 'integer'],
    'sync(text,integer) function exists in copy-paste schema'
);

-- 6. Adapter function: get_credentials(text)
select has_function(
    'inferal_relay_cp', 'get_credentials', array['text'],
    'get_credentials(text) function exists in copy-paste schema'
);

-- 7. Trigger bound correctly
select has_trigger(
    'inferal_relay_cp', 'streams', '_trg_stream_insert',
    '_trg_stream_insert trigger exists on streams'
);

-- 8. PGXS installation unaffected
select has_table(
    'inferal_relay', 'streams',
    'PGXS inferal_relay.streams still exists'
);

select * from finish();
rollback;
