-- Test: JSON-LD helper functions
begin;
select plan(10);

-- _extract_typed_value: typed value object
select is(
    inferal_relay._extract_typed_value('{"@value": "2026-01-27T12:00:00Z", "@type": "xsd:dateTime"}'::jsonb),
    '2026-01-27T12:00:00Z',
    '_extract_typed_value extracts @value from typed object'
);

-- _extract_typed_value: plain string
select is(
    inferal_relay._extract_typed_value('"hello"'::jsonb),
    'hello',
    '_extract_typed_value extracts plain JSON string'
);

-- _extract_typed_value: null input
select is(
    inferal_relay._extract_typed_value(null),
    null,
    '_extract_typed_value returns NULL for NULL input'
);

-- _extract_typed_value: object without @value
select is(
    inferal_relay._extract_typed_value('{"foo": "bar"}'::jsonb),
    null,
    '_extract_typed_value returns NULL for object without @value'
);

-- _extract_typed_value: xsd:string typed value
select is(
    inferal_relay._extract_typed_value('{"@value": "018f3b3c-4d00-7000-8000-000000000000", "@type": "xsd:string"}'::jsonb),
    '018f3b3c-4d00-7000-8000-000000000000',
    '_extract_typed_value extracts xsd:string typed value'
);

-- _extract_event_id
select is(
    inferal_relay._extract_event_id(
        '{"@id": "urn:entity:123", "relay:eventId": "018f3b3c-4d00-7000-8000-000000000000"}'::jsonb
    ),
    '018f3b3c-4d00-7000-8000-000000000000',
    '_extract_event_id returns relay:eventId'
);

-- _extract_event_id: missing field
select is(
    inferal_relay._extract_event_id('{"@id": "urn:entity:123"}'::jsonb),
    null,
    '_extract_event_id returns NULL when field missing'
);

-- _extract_generated_at: typed value
select is(
    inferal_relay._extract_generated_at(
        '{"prov:generatedAtTime": {"@value": "2026-01-27T12:00:00Z", "@type": "xsd:dateTime"}}'::jsonb
    ),
    '2026-01-27T12:00:00Z'::timestamptz,
    '_extract_generated_at parses ISO8601 typed value'
);

-- _extract_generated_at: plain string
select is(
    inferal_relay._extract_generated_at(
        '{"prov:generatedAtTime": "2026-01-27T12:00:00Z"}'::jsonb
    ),
    '2026-01-27T12:00:00Z'::timestamptz,
    '_extract_generated_at parses plain string timestamp'
);

-- _extract_member_id
select is(
    inferal_relay._extract_member_id('{"@id": "urn:entity:123"}'::jsonb),
    'urn:entity:123',
    '_extract_member_id returns @id'
);

select * from finish();
rollback;
