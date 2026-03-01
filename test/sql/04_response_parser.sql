-- Test: Response parser
begin;
select plan(10);

-- Full response with tree:relation array
select results_eq(
    $$select has_more from inferal_relay.process_response('{
        "@context": {},
        "@type": ["tree:Node", "ldes:EventStream"],
        "tree:member": [
            {"@id": "urn:entity:1", "relay:eventId": "018f0001", "prov:generatedAtTime": "2026-01-01T00:00:00Z"}
        ],
        "tree:relation": [{
            "@type": "tree:GreaterThanRelation",
            "tree:node": "/streams/acme/snapshots?since=018f0001&_p=3s.abcd",
            "tree:path": {"@id": "relay:eventId"},
            "tree:value": {"@value": "018f0001", "@type": "xsd:string"}
        }]
    }')$$,
    $$values (true)$$,
    'Response with tree:relation has has_more=true'
);

select results_eq(
    $$select next_event_id from inferal_relay.process_response('{
        "@context": {},
        "tree:member": [],
        "tree:relation": [{
            "@type": "tree:GreaterThanRelation",
            "tree:node": "/streams/acme/snapshots?since=018f0001&_p=3s.abcd",
            "tree:path": {"@id": "relay:eventId"},
            "tree:value": {"@value": "018f0001", "@type": "xsd:string"}
        }]
    }')$$,
    $$values ('018f0001'::text)$$,
    'Extracts next_event_id from tree:value'
);

select results_eq(
    $$select next_partition_hint from inferal_relay.process_response('{
        "@context": {},
        "tree:member": [],
        "tree:relation": [{
            "@type": "tree:GreaterThanRelation",
            "tree:node": "/streams/acme/snapshots?since=018f0001&_p=3s.abcd",
            "tree:path": {"@id": "relay:eventId"},
            "tree:value": {"@value": "018f0001", "@type": "xsd:string"}
        }]
    }')$$,
    $$values ('3s.abcd'::text)$$,
    'Extracts partition hint from tree:node URL'
);

-- No relation (last page / caught up)
select results_eq(
    $$select has_more from inferal_relay.process_response('{
        "@context": {},
        "tree:member": [
            {"@id": "urn:entity:1", "relay:eventId": "018f0001"}
        ]
    }')$$,
    $$values (false)$$,
    'Response without tree:relation has has_more=false'
);

-- Empty members
select results_eq(
    $$select jsonb_array_length(members) from inferal_relay.process_response('{
        "@context": {},
        "tree:member": []
    }')$$,
    $$values (0)$$,
    'Empty members array returns 0 elements'
);

-- Missing members key defaults to empty array
select results_eq(
    $$select jsonb_array_length(members) from inferal_relay.process_response('{
        "@context": {}
    }')$$,
    $$values (0)$$,
    'Missing tree:member defaults to empty array'
);

-- Single-object tree:relation (defensive)
select results_eq(
    $$select has_more from inferal_relay.process_response('{
        "@context": {},
        "tree:member": [],
        "tree:relation": {
            "@type": "tree:GreaterThanRelation",
            "tree:node": "/streams/acme/snapshots?since=018f0002",
            "tree:path": {"@id": "relay:eventId"},
            "tree:value": {"@value": "018f0002", "@type": "xsd:string"}
        }
    }')$$,
    $$values (true)$$,
    'Single-object tree:relation handled defensively'
);

-- Partition hint absent from URL
select results_eq(
    $$select next_partition_hint from inferal_relay.process_response('{
        "@context": {},
        "tree:member": [],
        "tree:relation": [{
            "@type": "tree:GreaterThanRelation",
            "tree:node": "/streams/acme/snapshots?since=018f0003",
            "tree:path": {"@id": "relay:eventId"},
            "tree:value": {"@value": "018f0003", "@type": "xsd:string"}
        }]
    }')$$,
    $$values (null::text)$$,
    'NULL partition hint when _p absent from URL'
);

-- Context extraction: object context returned as-is
select results_eq(
    $$select context from inferal_relay.process_response('{
        "@context": {"@vocab": "https://schema.org/", "tree": "https://w3id.org/tree#"},
        "tree:member": []
    }')$$,
    $$values ('{"tree": "https://w3id.org/tree#", "@vocab": "https://schema.org/"}'::jsonb)$$,
    'Context object extracted from response'
);

-- Context extraction: null when no @context
select results_eq(
    $$select context from inferal_relay.process_response('{
        "tree:member": []
    }')$$,
    $$values (null::jsonb)$$,
    'Context is null when @context absent'
);

select * from finish();
rollback;
