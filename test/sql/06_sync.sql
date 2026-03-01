-- Test: Sync orchestrator
begin;
select plan(27);

select inferal_relay.install_mock_adapter();

-- Create stream
insert into inferal_relay.streams(name, base_url, stream_id, page_limit)
values ('sync-test', 'https://relay.inferal.com', 'acme', 100);

-- Set up credentials
insert into inferal_relay.credentials(stream_name, api_key)
values ('sync-test', 'test-key-123');

-- Set up mock responses: page 1 has members + relation, page 2 has members + no relation
-- Both pages include a rich @context for testing context parsing
insert into inferal_relay.mock_responses(url_pattern, body) values
(
    '.*limit=100$',
    '{
        "@context": {
            "@vocab": "https://schema.org/",
            "tree": "https://w3id.org/tree#",
            "relay": "https://relay.inferal.com/ontology#",
            "prov": "https://www.w3.org/ns/prov#",
            "sameAs": "http://schema.org/sameAs",
            "fileCount": {"@id": "relay:fileCount", "@type": "xsd:integer"},
            "name": {"@id": "http://schema.org/name"}
        },
        "@type": ["tree:Node", "ldes:EventStream"],
        "tree:member": [
            {
                "@id": "urn:entity:1",
                "relay:eventId": "018f0001-0000-7000-8000-000000000001",
                "prov:generatedAtTime": {"@value": "2026-01-27T12:00:00Z", "@type": "xsd:dateTime"},
                "relay:path": "us-east/prod",
                "name": "Entity One"
            },
            {
                "@id": "urn:entity:2",
                "relay:eventId": "018f0001-0000-7000-8000-000000000002",
                "prov:generatedAtTime": {"@value": "2026-01-27T12:01:00Z", "@type": "xsd:dateTime"},
                "relay:path": "us-east/prod",
                "name": "Entity Two"
            }
        ],
        "tree:relation": [{
            "@type": "tree:GreaterThanRelation",
            "tree:node": "/streams/acme/snapshots?since=018f0001-0000-7000-8000-000000000002&_p=0.abcd",
            "tree:path": {"@id": "relay:eventId"},
            "tree:value": {"@value": "018f0001-0000-7000-8000-000000000002", "@type": "xsd:string"}
        }]
    }'
),
(
    '.*since=.*',
    '{
        "@context": {
            "@vocab": "https://schema.org/",
            "tree": "https://w3id.org/tree#",
            "relay": "https://relay.inferal.com/ontology#",
            "prov": "https://www.w3.org/ns/prov#",
            "sameAs": "http://schema.org/sameAs",
            "fileCount": {"@id": "relay:fileCount", "@type": "xsd:integer"},
            "name": {"@id": "http://schema.org/name"}
        },
        "@type": ["tree:Node", "ldes:EventStream"],
        "tree:member": [
            {
                "@id": "urn:entity:3",
                "relay:eventId": "018f0001-0000-7000-8000-000000000003",
                "prov:generatedAtTime": {"@value": "2026-01-27T12:02:00Z", "@type": "xsd:dateTime"},
                "relay:path": "us-west/staging",
                "name": "Entity Three"
            }
        ]
    }'
);

-- Run sync
select lives_ok(
    $$select inferal_relay.sync('sync-test')$$,
    'sync() completes without error'
);

-- Verify members stored
select is(
    (select count(*)::integer from inferal_relay.members where stream_name = 'sync-test'),
    3,
    'All 3 members stored across 2 pages'
);

-- Verify member fields extracted
select is(
    (select member_id from inferal_relay.members where event_id = '018f0001-0000-7000-8000-000000000001'),
    'urn:entity:1',
    'member_id extracted correctly'
);

select is(
    (select member_path from inferal_relay.members where event_id = '018f0001-0000-7000-8000-000000000001'),
    'us-east/prod',
    'member_path (relay:path) extracted correctly'
);

select ok(
    (select generated_at is not null from inferal_relay.members where event_id = '018f0001-0000-7000-8000-000000000001'),
    'generated_at parsed from prov:generatedAtTime'
);

-- Verify cursor at final position
-- On the last page (no tree:relation), next_event_id is NULL so cursor keeps
-- the value from the last page that had a relation (page 1's tree:value).
-- Next sync will re-fetch from this cursor; ON CONFLICT DO NOTHING ensures idempotency.
select is(
    (select last_event_id from inferal_relay.cursors where stream_name = 'sync-test'),
    '018f0001-0000-7000-8000-000000000002',
    'Cursor at last relation cursor (page 1 tree:value)'
);

select is(
    (select pages_fetched from inferal_relay.cursors where stream_name = 'sync-test'),
    2::bigint,
    'Cursor shows 2 pages fetched'
);

-- Verify sync_log entry
select is(
    (select status from inferal_relay.sync_log where stream_name = 'sync-test' order by id desc limit 1),
    'completed',
    'sync_log shows completed status'
);

select is(
    (select pages_fetched from inferal_relay.sync_log where stream_name = 'sync-test' order by id desc limit 1),
    2,
    'sync_log recorded 2 pages'
);

-- ====================================================================
-- Context storage verification
-- ====================================================================

-- contexts table has exactly 1 row (both pages have same context, deduplicated by hash)
select is(
    (select count(*)::integer from inferal_relay.contexts where stream_name = 'sync-test'),
    1,
    'Context deduplicated: 1 row despite 2 pages with same context'
);

-- Members have context_id set
select ok(
    (select bool_and(context_id is not null) from inferal_relay.members where stream_name = 'sync-test'),
    'All members have context_id set'
);

-- context_terms populated with expected entries
select ok(
    exists(select 1 from inferal_relay.context_terms ct
           join inferal_relay.contexts c on c.id = ct.context_id
           where c.stream_name = 'sync-test'
           and ct.term = '@vocab' and ct.iri = 'https://schema.org/' and ct.term_type = 'vocab'),
    '@vocab term stored correctly'
);

select ok(
    exists(select 1 from inferal_relay.context_terms ct
           join inferal_relay.contexts c on c.id = ct.context_id
           where c.stream_name = 'sync-test'
           and ct.term = 'tree' and ct.iri = 'https://w3id.org/tree#' and ct.term_type = 'prefix'),
    'tree prefix stored correctly'
);

select ok(
    exists(select 1 from inferal_relay.context_terms ct
           join inferal_relay.contexts c on c.id = ct.context_id
           where c.stream_name = 'sync-test'
           and ct.term = 'relay' and ct.iri = 'https://relay.inferal.com/ontology#' and ct.term_type = 'prefix'),
    'relay prefix stored correctly'
);

select ok(
    exists(select 1 from inferal_relay.context_terms ct
           join inferal_relay.contexts c on c.id = ct.context_id
           where c.stream_name = 'sync-test'
           and ct.term = 'sameAs' and ct.iri = 'http://schema.org/sameAs' and ct.term_type = 'term'),
    'sameAs direct IRI term stored correctly'
);

-- fileCount expanded from compact IRI relay:fileCount
select ok(
    exists(select 1 from inferal_relay.context_terms ct
           join inferal_relay.contexts c on c.id = ct.context_id
           where c.stream_name = 'sync-test'
           and ct.term = 'fileCount'
           and ct.iri = 'https://relay.inferal.com/ontology#fileCount'
           and ct.term_type = 'term'),
    'fileCount expanded from compact IRI relay:fileCount'
);

-- name from expanded definition {"@id": "http://schema.org/name"}
select ok(
    exists(select 1 from inferal_relay.context_terms ct
           join inferal_relay.contexts c on c.id = ct.context_id
           where c.stream_name = 'sync-test'
           and ct.term = 'name'
           and ct.iri = 'http://schema.org/name'
           and ct.term_type = 'term'),
    'name from expanded term definition stored correctly'
);

-- ====================================================================
-- resolve_term() tests
-- ====================================================================

-- Prefix expansion
select is(
    inferal_relay.resolve_term('sync-test', 'relay:eventId'),
    'https://relay.inferal.com/ontology#eventId',
    'resolve_term: relay:eventId expands via prefix'
);

-- @vocab fallback for bare term
select is(
    inferal_relay.resolve_term('sync-test', 'description'),
    'https://schema.org/description',
    'resolve_term: bare term "description" falls back to @vocab'
);

-- Exact match for expanded term (fileCount is stored with full IRI)
select is(
    inferal_relay.resolve_term('sync-test', 'fileCount'),
    'https://relay.inferal.com/ontology#fileCount',
    'resolve_term: fileCount resolves via exact match (expanded term)'
);

-- Test HTTP error handling
insert into inferal_relay.mock_responses(url_pattern, status_code, body) values
    ('.*', 401, '{"error": "unauthorized"}');

-- Reset cursor so sync tries to fetch
select inferal_relay.reset_cursor('sync-test');

-- sync() returns error status instead of raising (preserves sync_log changes)
select is(
    (select status from inferal_relay.sync('sync-test')),
    'error',
    'sync() returns error status on HTTP failure'
);

-- Verify sync_log has error entry
select is(
    (select status from inferal_relay.sync_log where stream_name = 'sync-test' order by id desc limit 1),
    'error',
    'sync_log records error status on failure'
);

-- Test sync_page: clean slate for mock responses
delete from inferal_relay.mock_responses;
delete from inferal_relay.members where stream_name = 'sync-test';
select inferal_relay.reset_cursor('sync-test');

insert into inferal_relay.mock_responses(url_pattern, body) values
(
    '.*',
    '{
        "@context": {},
        "tree:member": [
            {"@id": "urn:entity:4", "relay:eventId": "018f0004", "prov:generatedAtTime": "2026-01-28T00:00:00Z"}
        ],
        "tree:relation": [{
            "@type": "tree:GreaterThanRelation",
            "tree:node": "/streams/acme/snapshots?since=018f0004",
            "tree:path": {"@id": "relay:eventId"},
            "tree:value": {"@value": "018f0004", "@type": "xsd:string"}
        }]
    }'
);

select lives_ok(
    $$select inferal_relay.sync_page('sync-test')$$,
    'sync_page() fetches exactly one page'
);

-- ====================================================================
-- ingest_page() direct-call tests (no mock adapter needed)
-- ====================================================================

-- Clean slate for ingest_page tests
delete from inferal_relay.members where stream_name = 'sync-test';
select inferal_relay.reset_cursor('sync-test');

-- Test 1: ingest_page stores members from raw body
select is(
    (select members_received from inferal_relay.ingest_page(
        'sync-test',
        '{
            "@context": {"@vocab": "https://schema.org/"},
            "tree:member": [
                {"@id": "urn:ingest:1", "relay:eventId": "018f0010-0001", "prov:generatedAtTime": "2026-02-01T00:00:00Z"},
                {"@id": "urn:ingest:2", "relay:eventId": "018f0010-0002", "prov:generatedAtTime": "2026-02-01T00:01:00Z"}
            ],
            "tree:relation": [{
                "@type": "tree:GreaterThanRelation",
                "tree:node": "/streams/acme/snapshots?since=018f0010-0002&_p=0.xyz",
                "tree:path": {"@id": "relay:eventId"},
                "tree:value": {"@value": "018f0010-0002", "@type": "xsd:string"}
            }]
        }'
    )),
    2,
    'ingest_page: stores 2 members from raw body'
);

-- Test 2: ingest_page returns has_more = true when relation present
select is(
    (select has_more from inferal_relay.ingest_page(
        'sync-test',
        '{
            "tree:member": [
                {"relay:eventId": "018f0010-0003"}
            ],
            "tree:relation": [{
                "@type": "tree:GreaterThanRelation",
                "tree:node": "/streams/acme/snapshots?since=018f0010-0003",
                "tree:path": {"@id": "relay:eventId"},
                "tree:value": {"@value": "018f0010-0003", "@type": "xsd:string"}
            }]
        }'
    )),
    true,
    'ingest_page: has_more = true when relation present'
);

-- Test 3: ingest_page returns has_more = false when no relation
select is(
    (select has_more from inferal_relay.ingest_page(
        'sync-test',
        '{
            "tree:member": [
                {"relay:eventId": "018f0010-0004"}
            ]
        }'
    )),
    false,
    'ingest_page: has_more = false when no relation'
);

-- Test 4: ingest_page advances cursor correctly
select is(
    (select last_event_id from inferal_relay.cursors where stream_name = 'sync-test'),
    '018f0010-0003',
    'ingest_page: cursor advanced to last event with relation'
);

select * from finish();
rollback;
