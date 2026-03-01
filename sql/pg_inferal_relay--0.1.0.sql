-- pg_inferal_relay 0.1.0
-- Consume LDES streams from Inferal Relay in PostgreSQL
--
-- Can be installed via:
--   CREATE EXTENSION pg_inferal_relay;    (PGXS)
--   \i pg_inferal_relay--0.1.0.sql        (copy-paste)
--   pgtle.install_extension(...)           (TLE, use scripts/build-tle.sh)

create schema if not exists inferal_relay;
set search_path to inferal_relay;

-- ============================================================================
-- Tables
-- ============================================================================

create table inferal_relay.streams (
    name        text primary key,
    base_url    text not null,
    stream_id   text not null,
    facet       text not null default 'snapshots',
    page_limit  integer not null default 100,
    enabled     boolean not null default true,
    created_at  timestamptz not null default now(),
    updated_at  timestamptz not null default now(),
    constraint streams_page_limit_check
        check (page_limit > 0 and page_limit <= 10000),
    constraint streams_base_url_check
        check (base_url ~ '^https?://')
);

create table inferal_relay.cursors (
    stream_name         text primary key
                        references inferal_relay.streams(name) on delete cascade,
    last_event_id       text,
    partition_hint      text,
    last_synced_at      timestamptz,
    pages_fetched       bigint not null default 0,
    members_received    bigint not null default 0
);

create table inferal_relay.contexts (
    id           bigint generated always as identity primary key,
    stream_name  text not null
                 references inferal_relay.streams(name) on delete cascade,
    context_hash text not null,
    context      jsonb not null,
    first_seen   timestamptz not null default now(),
    constraint contexts_stream_hash_unique unique (stream_name, context_hash)
);

create table inferal_relay.context_terms (
    context_id  bigint not null
                references inferal_relay.contexts(id) on delete cascade,
    term        text not null,
    iri         text not null,
    term_type   text not null,
    primary key (context_id, term)
);

create table inferal_relay.members (
    id                  bigint generated always as identity primary key,
    stream_name         text not null
                        references inferal_relay.streams(name) on delete cascade,
    event_id            text not null,
    member_id           text,
    generated_at        timestamptz,
    member_path         text,
    data                jsonb not null,
    fetched_at          timestamptz not null default now(),
    context_id          bigint references inferal_relay.contexts(id),
    constraint members_unique_event
        unique (stream_name, event_id)
);

create index idx_members_stream_generated
    on inferal_relay.members(stream_name, generated_at);
create index idx_members_member_id
    on inferal_relay.members(member_id);

create table inferal_relay.sync_log (
    id                  bigint generated always as identity primary key,
    stream_name         text not null
                        references inferal_relay.streams(name) on delete cascade,
    started_at          timestamptz not null default now(),
    finished_at         timestamptz,
    pages_fetched       integer not null default 0,
    members_received    integer not null default 0,
    last_event_id       text,
    status              text not null default 'running',
    error_message       text
);

create index idx_sync_log_stream_time
    on inferal_relay.sync_log(stream_name, started_at desc);

-- ============================================================================
-- Triggers on streams
-- ============================================================================

create function inferal_relay._on_stream_insert()
returns trigger
language plpgsql as $$
begin
    insert into inferal_relay.cursors(stream_name)
    values (new.name);
    return new;
end;
$$;

create trigger _trg_stream_insert
    after insert on inferal_relay.streams
    for each row
    execute function inferal_relay._on_stream_insert();

create function inferal_relay._on_stream_update()
returns trigger
language plpgsql as $$
begin
    new.updated_at := clock_timestamp();
    return new;
end;
$$;

create trigger _trg_stream_update
    before update on inferal_relay.streams
    for each row
    execute function inferal_relay._on_stream_update();

-- ============================================================================
-- JSON-LD helpers (private)
-- ============================================================================

-- Extract value from {"@value": "...", "@type": "..."} or plain JSON string
create function inferal_relay._extract_typed_value(val jsonb)
returns text
language sql immutable as $$
    select case
        when val is null then null
        when jsonb_typeof(val) = 'string' then val #>> '{}'
        when val ? '@value' then val ->> '@value'
        else null
    end;
$$;

-- Extract relay:eventId from a member (always a plain string)
create function inferal_relay._extract_event_id(member jsonb)
returns text
language sql immutable as $$
    select member ->> 'relay:eventId';
$$;

-- Extract prov:generatedAtTime as timestamptz
create function inferal_relay._extract_generated_at(member jsonb)
returns timestamptz
language sql immutable as $$
    select inferal_relay._extract_typed_value(
        member -> 'prov:generatedAtTime'
    )::timestamptz;
$$;

-- Extract @id from a member
create function inferal_relay._extract_member_id(member jsonb)
returns text
language sql immutable as $$
    select member ->> '@id';
$$;

-- ============================================================================
-- Context management
-- ============================================================================

-- Upsert a JSON-LD @context for a stream.
-- Returns context id, or null if context is null/string (remote URL).
create function inferal_relay._upsert_context(
    p_stream_name text,
    p_context     jsonb
)
returns bigint
language plpgsql as $$
declare
    v_normalized jsonb;
    v_hash       text;
    v_ctx_id     bigint;
    v_key        text;
    v_val        jsonb;
    v_val_text   text;
    v_id_val     text;
    v_prefixes   jsonb := '{}'::jsonb;
    v_keys       text[];
begin
    -- Null or JSON null
    if p_context is null or jsonb_typeof(p_context) = 'null' then
        return null;
    end if;

    -- String = remote context URL, cannot fetch in PG
    if jsonb_typeof(p_context) = 'string' then
        return null;
    end if;

    -- Array: merge inline objects, skip string elements
    if jsonb_typeof(p_context) = 'array' then
        v_normalized := '{}'::jsonb;
        for v_val in select * from jsonb_array_elements(p_context)
        loop
            if jsonb_typeof(v_val) = 'object' then
                v_normalized := v_normalized || v_val;
            end if;
            -- skip strings (remote context URLs)
        end loop;
        if v_normalized = '{}'::jsonb then
            return null;
        end if;
    elsif jsonb_typeof(p_context) = 'object' then
        v_normalized := p_context;
    else
        return null;
    end if;

    -- Compute hash for deduplication
    v_hash := md5(v_normalized::text);

    -- Look up existing
    select id into v_ctx_id
    from   inferal_relay.contexts
    where  stream_name = p_stream_name
    and    context_hash = v_hash;

    if found then
        return v_ctx_id;
    end if;

    -- Insert new context
    insert into inferal_relay.contexts(stream_name, context_hash, context)
    values (p_stream_name, v_hash, v_normalized)
    returning id into v_ctx_id;

    -- Collect keys for iteration (need two passes)
    select array_agg(k) into v_keys
    from   jsonb_object_keys(v_normalized) as k;

    if v_keys is null then
        return v_ctx_id;
    end if;

    -- Pass 1: collect @vocab, @base, and prefixes
    for i in 1..array_length(v_keys, 1) loop
        v_key := v_keys[i];
        v_val := v_normalized -> v_key;

        if v_key = '@vocab' and jsonb_typeof(v_val) = 'string' then
            v_val_text := v_val #>> '{}';
            insert into inferal_relay.context_terms(context_id, term, iri, term_type)
            values (v_ctx_id, '@vocab', v_val_text, 'vocab');
            v_prefixes := v_prefixes || jsonb_build_object('@vocab', v_val_text);

        elsif v_key = '@base' and jsonb_typeof(v_val) = 'string' then
            v_val_text := v_val #>> '{}';
            insert into inferal_relay.context_terms(context_id, term, iri, term_type)
            values (v_ctx_id, '@base', v_val_text, 'base');

        elsif v_key like '@%' then
            -- Skip other JSON-LD keywords
            continue;

        elsif jsonb_typeof(v_val) = 'string' then
            v_val_text := v_val #>> '{}';
            -- Full URI ending in # or / → prefix
            if (v_val_text like 'http://%' or v_val_text like 'https://%' or v_val_text like 'urn:%')
               and (v_val_text like '%#' or v_val_text like '%/') then
                insert into inferal_relay.context_terms(context_id, term, iri, term_type)
                values (v_ctx_id, v_key, v_val_text, 'prefix');
                v_prefixes := v_prefixes || jsonb_build_object(v_key, v_val_text);
            end if;
            -- Other string values handled in pass 2
        end if;
    end loop;

    -- Pass 2: terms (direct IRIs, compact IRIs, expanded definitions)
    for i in 1..array_length(v_keys, 1) loop
        v_key := v_keys[i];
        v_val := v_normalized -> v_key;

        -- Skip keywords (already handled)
        if v_key like '@%' then
            continue;
        end if;

        if jsonb_typeof(v_val) = 'string' then
            v_val_text := v_val #>> '{}';

            -- Already inserted as prefix in pass 1
            if (v_val_text like 'http://%' or v_val_text like 'https://%' or v_val_text like 'urn:%')
               and (v_val_text like '%#' or v_val_text like '%/') then
                continue;
            end if;

            -- Full URI (not ending in # or /) → direct term mapping
            if v_val_text like 'http://%' or v_val_text like 'https://%' or v_val_text like 'urn:%' then
                insert into inferal_relay.context_terms(context_id, term, iri, term_type)
                values (v_ctx_id, v_key, v_val_text, 'term');

            -- Compact IRI (contains :, not a full URI) → expand using known prefixes
            elsif position(':' in v_val_text) > 0 then
                declare
                    v_prefix text;
                    v_suffix text;
                    v_prefix_iri text;
                begin
                    v_prefix := split_part(v_val_text, ':', 1);
                    v_suffix := substring(v_val_text from position(':' in v_val_text) + 1);
                    v_prefix_iri := v_prefixes ->> v_prefix;
                    if v_prefix_iri is not null then
                        insert into inferal_relay.context_terms(context_id, term, iri, term_type)
                        values (v_ctx_id, v_key, v_prefix_iri || v_suffix, 'term');
                    else
                        -- Prefix not known, store compact IRI as-is
                        insert into inferal_relay.context_terms(context_id, term, iri, term_type)
                        values (v_ctx_id, v_key, v_val_text, 'term');
                    end if;
                end;

            else
                -- Other string value (keyword alias, etc.) → term
                insert into inferal_relay.context_terms(context_id, term, iri, term_type)
                values (v_ctx_id, v_key, v_val_text, 'term');
            end if;

        elsif jsonb_typeof(v_val) = 'object' then
            -- Expanded term definition: {"@id": "...", "@type": "..."}
            v_id_val := v_val ->> '@id';
            if v_id_val is not null then
                -- Expand compact IRI in @id if possible
                if position(':' in v_id_val) > 0
                   and v_id_val not like 'http://%'
                   and v_id_val not like 'https://%'
                   and v_id_val not like 'urn:%' then
                    declare
                        v_prefix text;
                        v_suffix text;
                        v_prefix_iri text;
                    begin
                        v_prefix := split_part(v_id_val, ':', 1);
                        v_suffix := substring(v_id_val from position(':' in v_id_val) + 1);
                        v_prefix_iri := v_prefixes ->> v_prefix;
                        if v_prefix_iri is not null then
                            v_id_val := v_prefix_iri || v_suffix;
                        end if;
                    end;
                end if;
                insert into inferal_relay.context_terms(context_id, term, iri, term_type)
                values (v_ctx_id, v_key, v_id_val, 'term');
            end if;
            -- No @id → skip (type coercion only)
        end if;
    end loop;

    return v_ctx_id;
end;
$$;

-- ============================================================================
-- Term resolution
-- ============================================================================

-- Resolve a compact IRI or bare term to a full IRI using a stream's context.
-- If p_context_id is null, uses the latest context for the stream.
create function inferal_relay.resolve_term(
    p_stream_name text,
    p_term        text,
    p_context_id  bigint default null
)
returns text
language plpgsql stable as $$
declare
    v_ctx_id    bigint;
    v_iri       text;
    v_prefix    text;
    v_suffix    text;
    v_vocab     text;
begin
    -- Determine context to use
    if p_context_id is not null then
        v_ctx_id := p_context_id;
    else
        select id into v_ctx_id
        from   inferal_relay.contexts
        where  stream_name = p_stream_name
        order by first_seen desc
        limit 1;

        if v_ctx_id is null then
            return null;
        end if;
    end if;

    -- 1. Exact match (handles direct IRI mappings, expanded terms)
    select ct.iri into v_iri
    from   inferal_relay.context_terms ct
    where  ct.context_id = v_ctx_id
    and    ct.term = p_term;

    if v_iri is not null then
        return v_iri;
    end if;

    -- 2. Prefix expansion: split on first colon
    if position(':' in p_term) > 0 then
        v_prefix := split_part(p_term, ':', 1);
        v_suffix := substring(p_term from position(':' in p_term) + 1);

        select ct.iri into v_iri
        from   inferal_relay.context_terms ct
        where  ct.context_id = v_ctx_id
        and    ct.term = v_prefix
        and    ct.term_type = 'prefix';

        if v_iri is not null then
            return v_iri || v_suffix;
        end if;
    end if;

    -- 3. @vocab fallback (for bare terms)
    select ct.iri into v_vocab
    from   inferal_relay.context_terms ct
    where  ct.context_id = v_ctx_id
    and    ct.term = '@vocab';

    if v_vocab is not null then
        return v_vocab || p_term;
    end if;

    return null;
end;
$$;

-- ============================================================================
-- URL builder
-- ============================================================================

create function inferal_relay.build_next_url(
    stream_name         text,
    since_event_id      text default null,
    partition_hint      text default null
)
returns text
language plpgsql stable as $$
declare
    v_base_url   text;
    v_stream_id  text;
    v_facet      text;
    v_page_limit integer;
    v_url        text;
    v_sep        text;
begin
    select s.base_url, s.stream_id, s.facet, s.page_limit
    into   v_base_url, v_stream_id, v_facet, v_page_limit
    from   inferal_relay.streams s
    where  s.name = stream_name;

    if not found then
        raise exception 'Stream "%" not found', stream_name;
    end if;

    -- Strip trailing slash from base_url
    v_base_url := rtrim(v_base_url, '/');

    -- Build path: {base_url}/streams/{stream_id}/{facet}
    v_url := v_base_url || '/streams/' || v_stream_id || '/' || v_facet;

    v_sep := '?';

    -- Add since parameter if we have a cursor
    if since_event_id is not null then
        v_url := v_url || v_sep || 'since=' || since_event_id;
        v_sep := '&';

        -- Add partition hint only when since is present
        if partition_hint is not null then
            v_url := v_url || '&_p=' || partition_hint;
        end if;
    end if;

    -- Always add limit
    v_url := v_url || v_sep || 'limit=' || v_page_limit::text;

    return v_url;
end;
$$;

-- ============================================================================
-- Response parser
-- ============================================================================

create function inferal_relay.process_response(response_body text)
returns table(
    members             jsonb,
    next_event_id       text,
    next_partition_hint text,
    has_more            boolean,
    context             jsonb
)
language plpgsql immutable as $$
declare
    v_doc       jsonb;
    v_relations jsonb;
    v_relation  jsonb;
    v_node_url  text;
    v_match     text[];
begin
    v_doc := response_body::jsonb;

    -- Extract @context
    context := v_doc -> '@context';

    -- Extract members (default to empty array)
    members := coalesce(v_doc -> 'tree:member', '[]'::jsonb);

    -- Extract tree:relation
    v_relations := v_doc -> 'tree:relation';

    if v_relations is null or jsonb_typeof(v_relations) = 'null' then
        -- No relation = caught up, no more pages
        next_event_id := null;
        next_partition_hint := null;
        has_more := false;
        return next;
        return;
    end if;

    -- Handle both array and single-object forms defensively
    if jsonb_typeof(v_relations) = 'object' then
        v_relation := v_relations;
    elsif jsonb_typeof(v_relations) = 'array' then
        -- Find the GreaterThanRelation
        select r into v_relation
        from   jsonb_array_elements(v_relations) as r
        where  r ->> '@type' = 'tree:GreaterThanRelation'
        limit  1;
    end if;

    if v_relation is null then
        next_event_id := null;
        next_partition_hint := null;
        has_more := false;
        return next;
        return;
    end if;

    -- Extract cursor value from tree:value
    next_event_id := inferal_relay._extract_typed_value(v_relation -> 'tree:value');

    -- Extract partition hint from tree:node URL
    v_node_url := v_relation ->> 'tree:node';
    if v_node_url is not null then
        v_match := regexp_match(v_node_url, '[?&]_p=([^&]+)');
        if v_match is not null then
            next_partition_hint := v_match[1];
        else
            next_partition_hint := null;
        end if;
    else
        next_partition_hint := null;
    end if;

    has_more := true;
    return next;
    return;
end;
$$;

-- ============================================================================
-- Member storage
-- ============================================================================

create function inferal_relay._store_members(
    p_stream_name text,
    members       jsonb,
    p_context_id  bigint default null
)
returns integer
language plpgsql as $$
declare
    v_inserted integer;
begin
    insert into inferal_relay.members(
        stream_name, event_id, member_id, generated_at, member_path, data, context_id
    )
    select
        p_stream_name,
        inferal_relay._extract_event_id(m.value),
        inferal_relay._extract_member_id(m.value),
        inferal_relay._extract_generated_at(m.value),
        m.value ->> 'relay:path',
        m.value,
        p_context_id
    from jsonb_array_elements(members) as m(value)
    where inferal_relay._extract_event_id(m.value) is not null
    on conflict (stream_name, event_id) do nothing;

    get diagnostics v_inserted = row_count;
    return v_inserted;
end;
$$;

-- ============================================================================
-- Cursor management
-- ============================================================================

create function inferal_relay._advance_cursor(
    p_stream_name    text,
    event_id         text,
    p_partition_hint text,
    member_count     integer
)
returns void
language plpgsql as $$
begin
    update inferal_relay.cursors
    set    last_event_id    = event_id,
           partition_hint   = p_partition_hint,
           last_synced_at   = now(),
           pages_fetched    = pages_fetched + 1,
           members_received = members_received + member_count
    where  stream_name = p_stream_name;
end;
$$;

create function inferal_relay.reset_cursor(stream text)
returns void
language plpgsql as $$
begin
    update inferal_relay.cursors
    set    last_event_id    = null,
           partition_hint   = null,
           last_synced_at   = null,
           pages_fetched    = 0,
           members_received = 0
    where  stream_name = stream;

    if not found then
        raise exception 'Cursor for stream "%" not found', stream;
    end if;
end;
$$;

-- ============================================================================
-- HTTP stub (replaced by adapters)
-- ============================================================================

create function inferal_relay.http_get(
    url     text,
    headers jsonb default '{}'::jsonb
)
returns jsonb
language plpgsql as $$
begin
    raise exception
        'inferal_relay.http_get() is not configured. '
        'Install an adapter: SELECT inferal_relay.install_pgsql_http_adapter()';
end;
$$;

-- ============================================================================
-- Adapter installers
-- ============================================================================

-- Install credential store adapter (no prerequisites)
-- Built-in table-based credential storage; installed by default
create function inferal_relay.install_credential_store_adapter()
returns void
language plpgsql as $installer$
begin
    create table if not exists inferal_relay.credentials (
        stream_name text primary key,
        api_key     text not null
    );

    execute $adapter$
        create or replace function inferal_relay.get_credentials(p_stream_name text)
        returns jsonb
        language plpgsql stable as $fn$
        declare
            v_api_key text;
        begin
            select api_key
            into   v_api_key
            from   inferal_relay.credentials
            where  stream_name = p_stream_name;

            if v_api_key is null then
                return null;
            end if;

            return jsonb_build_object('api_key', v_api_key);
        end;
        $fn$;
    $adapter$;
end;
$installer$;

-- Install pgsql-http adapter (requires: CREATE EXTENSION http)
create function inferal_relay.install_pgsql_http_adapter()
returns void
language plpgsql as $installer$
begin
    -- Check prerequisite: http extension must be loaded
    if not exists (select 1 from pg_extension where extname = 'http') then
        raise exception 'pgsql-http adapter requires the http extension. Run: CREATE EXTENSION http;';
    end if;

    execute $adapter$
        create or replace function inferal_relay.http_get(
            url     text,
            headers jsonb default '{}'::jsonb
        )
        returns jsonb
        language plpgsql as $fn$
        declare
            v_headers   http_header[];
            v_request   http_request;
            v_response  http_response;
            v_resp_hdrs jsonb;
            v_key       text;
            v_val       text;
        begin
            -- Convert jsonb headers to http_header array
            v_headers := array[]::http_header[];
            for v_key, v_val in select * from jsonb_each_text(headers)
            loop
                v_headers := v_headers || row(v_key, v_val)::http_header;
            end loop;

            -- Build and execute request
            v_request := row('GET', url, v_headers, null, null)::http_request;
            v_response := http(v_request);

            -- Convert response headers to jsonb
            v_resp_hdrs := '{}'::jsonb;
            if v_response.headers is not null then
                select jsonb_object_agg(h.field, h.value)
                into   v_resp_hdrs
                from   unnest(v_response.headers) as h(field, value);
            end if;

            return jsonb_build_object(
                'status',  v_response.status,
                'body',    v_response.content,
                'headers', coalesce(v_resp_hdrs, '{}'::jsonb)
            );
        end;
        $fn$;
    $adapter$;
end;
$installer$;

-- Install pg_curl adapter (requires: CREATE EXTENSION pg_curl)
-- pg_curl binds libcurl directly into PostgreSQL (synchronous).
create function inferal_relay.install_pg_curl_adapter()
returns void
language plpgsql as $installer$
begin
    -- Check prerequisite
    if not exists (select 1 from pg_extension where extname = 'pg_curl') then
        raise exception 'pg_curl adapter requires the pg_curl extension. '
            'See: https://github.com/RekGRpth/pg_curl';
    end if;

    execute $adapter$
        create or replace function inferal_relay.http_get(
            url     text,
            headers jsonb default '{}'::jsonb
        )
        returns jsonb
        language plpgsql as $fn$
        declare
            v_status     bigint;
            v_body       text;
            v_key        text;
            v_val        text;
            v_resp_hdrs  jsonb;
        begin
            -- Reset + set URL
            perform curl_easy_reset();
            perform curl_easy_setopt_url(url);

            -- Append headers from jsonb
            for v_key, v_val in select * from jsonb_each_text(headers)
            loop
                perform curl_header_append(v_key, v_val);
            end loop;

            -- Execute request
            perform curl_easy_perform();

            -- Collect results
            v_status := curl_easy_getinfo_response_code();
            v_body   := convert_from(curl_easy_getinfo_data_in(), 'utf-8');

            -- Parse response headers from raw header text
            select coalesce(jsonb_object_agg(s[1], s[2]), '{}'::jsonb)
            into   v_resp_hdrs
            from   regexp_matches(
                       curl_easy_getinfo_header_in(),
                       E'([^ \\t\\r\\n\\f]+): ?([^\\t\\r\\n\\f]+)', 'g'
                   ) as s;

            return jsonb_build_object(
                'status',  v_status,
                'body',    v_body,
                'headers', coalesce(v_resp_hdrs, '{}'::jsonb)
            );
        end;
        $fn$;
    $adapter$;
end;
$installer$;

-- Install Supabase Vault adapter (requires: vault.decrypted_secrets)
-- Store credentials in Vault with name: inferal_relay_{stream_name}
-- Value should be the API key (plain text)
create function inferal_relay.install_vault_adapter()
returns void
language plpgsql as $installer$
begin
    -- Check prerequisite: vault.decrypted_secrets must exist
    if not exists (
        select 1 from information_schema.tables
        where table_schema = 'vault' and table_name = 'decrypted_secrets'
    ) then
        raise exception 'Vault adapter requires vault.decrypted_secrets (Supabase platform).';
    end if;

    execute $adapter$
        create or replace function inferal_relay.get_credentials(p_stream_name text)
        returns jsonb
        language plpgsql stable as $fn$
        declare
            v_secret_name text;
            v_api_key     text;
        begin
            v_secret_name := 'inferal_relay_' || p_stream_name;

            select decrypted_secret
            into   v_api_key
            from   vault.decrypted_secrets
            where  name = v_secret_name;

            if v_api_key is null then
                return null;
            end if;

            return jsonb_build_object('api_key', v_api_key);
        end;
        $fn$;
    $adapter$;
end;
$installer$;

-- Install pg_net adapter (requires: pg_net + dblink)
-- pg_net is async (requests sent after commit), so dblink bridges
-- the gap by executing pg_net calls in a separate transaction.
create function inferal_relay.install_pg_net_adapter()
returns void
language plpgsql as $installer$
begin
    if not exists (select 1 from pg_extension where extname = 'pg_net') then
        raise exception 'pg_net adapter requires the pg_net extension. Run: CREATE EXTENSION pg_net;';
    end if;

    if not exists (select 1 from pg_extension where extname = 'dblink') then
        raise exception 'pg_net adapter requires the dblink extension for synchronous bridging. Run: CREATE EXTENSION dblink;';
    end if;

    execute $adapter$
        create or replace function inferal_relay.http_get(
            url     text,
            headers jsonb default '{}'::jsonb
        )
        returns jsonb
        language plpgsql as $fn$
        declare
            v_conn text := 'pg_net_bridge_' || pg_backend_pid();
            v_request_id bigint;
            v_status_code integer;
            v_body text;
            v_resp_headers jsonb;
            v_timed_out boolean;
            v_error text;
        begin
            -- Reuse or open a dblink connection to same database
            if not coalesce(v_conn = any(dblink_get_connections()), false) then
                perform dblink_connect(v_conn,
                    format($q$dbname=%s port=%s$q$, current_database(), current_setting('port')));
            end if;

            begin
                -- Queue HTTP request via pg_net (commits immediately via dblink)
                select rid into v_request_id
                from dblink(v_conn,
                    format($q$select net.http_get(%L, headers := %L)$q$, url, headers)
                ) as t(rid bigint);

                -- Poll for response (pg_net background worker processes after commit)
                for i in 1..50 loop  -- max ~5 seconds at 100ms intervals
                    select r.status_code, r.content, r.timed_out, r.error_msg, r.headers
                    into   v_status_code, v_body, v_timed_out, v_error, v_resp_headers
                    from dblink(v_conn,
                        format($q$select status_code, content, timed_out, error_msg, headers
                                 from net._http_response where id = %s$q$, v_request_id)
                    ) as r(status_code integer, content text, timed_out boolean, error_msg text, headers jsonb);

                    exit when v_status_code is not null or v_timed_out or v_error is not null;
                    perform pg_sleep(0.1);
                end loop;

                -- Clean up response row
                perform dblink_exec(v_conn,
                    format($q$delete from net._http_response where id = %s$q$, v_request_id));

            exception when others then
                begin
                    perform dblink_disconnect(v_conn);
                exception when others then
                    null;
                end;
                raise;
            end;

            if v_timed_out then
                raise exception 'HTTP request timed out for URL: %', url;
            end if;

            if v_error is not null then
                raise exception 'HTTP request failed: %', v_error;
            end if;

            if v_status_code is null then
                raise exception 'pg_net response not received within 5s for URL: %', url;
            end if;

            return jsonb_build_object(
                'status',  v_status_code,
                'body',    coalesce(v_body, ''),
                'headers', coalesce(v_resp_headers, '{}'::jsonb)
            );
        end;
        $fn$;
    $adapter$;
end;
$installer$;

-- Install mock HTTP adapter for testing (no prerequisites)
-- Creates mock_responses table and replaces http_get
create function inferal_relay.install_mock_adapter()
returns void
language plpgsql as $installer$
begin
    create table if not exists inferal_relay.mock_responses (
        id          serial primary key,
        url_pattern text,
        status_code integer not null default 200,
        body        text not null,
        headers     jsonb not null default '{}'::jsonb
    );

    execute $adapter$
        create or replace function inferal_relay.http_get(
            url     text,
            headers jsonb default '{}'::jsonb
        )
        returns jsonb
        language plpgsql as $fn$
        declare
            v_mock record;
        begin
            -- Find first matching mock response (ordered by id for deterministic sequence)
            delete from inferal_relay.mock_responses
            where  id = (
                select id
                from   inferal_relay.mock_responses
                where  url_pattern is null or url ~ url_pattern
                order by id
                limit 1
            )
            returning * into v_mock;

            if not found then
                return jsonb_build_object(
                    'status',  404,
                    'body',    '{"error": "No mock response matched URL: ' || url || '"}',
                    'headers', '{}'::jsonb
                );
            end if;

            return jsonb_build_object(
                'status',  v_mock.status_code,
                'body',    v_mock.body,
                'headers', v_mock.headers
            );
        end;
        $fn$;
    $adapter$;
end;
$installer$;

-- ============================================================================
-- Status helper
-- ============================================================================

create function inferal_relay.get_stream_status(stream text)
returns jsonb
language plpgsql stable as $$
declare
    v_result jsonb;
begin
    select jsonb_build_object(
        'name',             s.name,
        'base_url',         s.base_url,
        'stream_id',        s.stream_id,
        'facet',            s.facet,
        'page_limit',       s.page_limit,
        'enabled',          s.enabled,
        'created_at',       s.created_at,
        'updated_at',       s.updated_at,
        'last_event_id',    c.last_event_id,
        'partition_hint',   c.partition_hint,
        'last_synced_at',   c.last_synced_at,
        'pages_fetched',    c.pages_fetched,
        'members_received', c.members_received
    )
    into v_result
    from inferal_relay.streams s
    join inferal_relay.cursors c on c.stream_name = s.name
    where s.name = stream;

    if v_result is null then
        raise exception 'Stream "%" not found', stream;
    end if;

    return v_result;
end;
$$;

-- ============================================================================
-- Page ingestion (parse + store + advance)
-- ============================================================================

-- Ingest a pre-fetched LDES response body into a stream.
-- Parses the JSON-LD, stores members, updates context, and advances cursor.
-- Callers (sync, sync_page, external scripts) handle HTTP themselves.
create function inferal_relay.ingest_page(
    p_stream_name   text,
    response_body   text
)
returns table(
    members_received    integer,
    next_event_id       text,
    next_partition_hint text,
    has_more            boolean
)
language plpgsql as $$
declare
    v_cursor     record;
    v_parsed     record;
    v_context_id bigint;
    v_inserted   integer;
begin
    -- Load cursor (need last_event_id for coalesce fallback in _advance_cursor)
    select * into v_cursor
    from inferal_relay.cursors
    where stream_name = p_stream_name;

    -- Parse response
    select * into v_parsed
    from inferal_relay.process_response(response_body);

    -- Upsert context (deduplicates by hash)
    v_context_id := inferal_relay._upsert_context(
        p_stream_name,
        v_parsed.context
    );

    -- Store members
    v_inserted := inferal_relay._store_members(
        p_stream_name,
        v_parsed.members,
        v_context_id
    );

    -- Advance cursor
    perform inferal_relay._advance_cursor(
        p_stream_name,
        coalesce(v_parsed.next_event_id, v_cursor.last_event_id),
        v_parsed.next_partition_hint,
        v_inserted
    );

    members_received := v_inserted;
    next_event_id := v_parsed.next_event_id;
    next_partition_hint := v_parsed.next_partition_hint;
    has_more := v_parsed.has_more;
    return next;
    return;
end;
$$;

-- ============================================================================
-- Sync orchestrator
-- ============================================================================

create function inferal_relay.sync(
    p_stream_name text,
    max_pages     integer default 100
)
returns table(
    stream           text,
    pages_fetched    integer,
    members_received integer,
    last_event_id    text,
    has_more         boolean,
    status           text,
    error            text
)
language plpgsql as $$
declare
    v_sub           record;
    v_cursor        record;
    v_creds         jsonb;
    v_headers       jsonb;
    v_log_id        bigint;
    v_url           text;
    v_response      jsonb;
    v_http_status   integer;
    v_body          text;
    v_ingest        record;
    v_total_pages   integer := 0;
    v_total_members integer := 0;
    v_last_event_id text;
    v_has_more      boolean := true;
begin
    -- Load stream
    select * into v_sub
    from inferal_relay.streams
    where name = p_stream_name;

    if not found then
        raise exception 'Stream "%" not found', p_stream_name;
    end if;

    if not v_sub.enabled then
        raise exception 'Stream "%" is disabled', p_stream_name;
    end if;

    -- Load cursor
    select * into v_cursor
    from inferal_relay.cursors
    where stream_name = p_stream_name;

    -- Get credentials and build headers
    begin
        v_creds := inferal_relay.get_credentials(p_stream_name);
    exception when others then
        v_creds := null;
    end;

    v_headers := jsonb_build_object('Accept', 'application/ld+json');
    if v_creds is not null and v_creds ->> 'api_key' is not null then
        v_headers := v_headers || jsonb_build_object(
            'Authorization', 'Bearer ' || (v_creds ->> 'api_key')
        );
    end if;

    -- Create sync log entry
    insert into inferal_relay.sync_log(stream_name)
    values (p_stream_name)
    returning id into v_log_id;

    -- Initialize cursor state for URL building
    v_last_event_id := v_cursor.last_event_id;

    begin
        while v_has_more and v_total_pages < max_pages loop
            -- Build URL from current cursor state
            v_url := inferal_relay.build_next_url(
                p_stream_name,
                v_last_event_id,
                v_cursor.partition_hint
            );

            -- Fetch page
            v_response := inferal_relay.http_get(v_url, v_headers);
            v_http_status := (v_response ->> 'status')::integer;

            if v_http_status <> 200 then
                raise exception 'HTTP % from %', v_http_status, v_url;
            end if;

            v_body := v_response ->> 'body';

            -- Ingest page (parse + store + advance cursor)
            select * into v_ingest
            from inferal_relay.ingest_page(p_stream_name, v_body);

            v_total_pages := v_total_pages + 1;
            v_total_members := v_total_members + v_ingest.members_received;

            if v_ingest.next_event_id is not null then
                v_last_event_id := v_ingest.next_event_id;
                v_cursor.partition_hint := v_ingest.next_partition_hint;
            end if;

            v_has_more := v_ingest.has_more;
        end loop;

        -- Update sync log as completed
        update inferal_relay.sync_log
        set    finished_at      = now(),
               pages_fetched    = v_total_pages,
               members_received = v_total_members,
               last_event_id    = v_last_event_id,
               status           = 'completed'
        where  id = v_log_id;

    exception when others then
        -- Update sync log with error
        update inferal_relay.sync_log
        set    finished_at      = now(),
               pages_fetched    = v_total_pages,
               members_received = v_total_members,
               last_event_id    = v_last_event_id,
               status           = 'error',
               error_message    = sqlerrm
        where  id = v_log_id;

        stream := p_stream_name;
        pages_fetched := v_total_pages;
        members_received := v_total_members;
        last_event_id := v_last_event_id;
        has_more := false;
        status := 'error';
        error := sqlerrm;
        return next;
        return;
    end;

    stream := p_stream_name;
    pages_fetched := v_total_pages;
    members_received := v_total_members;
    last_event_id := v_last_event_id;
    has_more := v_has_more;
    status := 'completed';
    error := null;
    return next;
    return;
end;
$$;

-- ============================================================================
-- Single-page sync
-- ============================================================================

create function inferal_relay.sync_page(p_stream_name text)
returns table(
    stream           text,
    pages_fetched    integer,
    members_received integer,
    last_event_id    text,
    has_more         boolean,
    status           text,
    error            text
)
language plpgsql as $$
declare
    v_sub           record;
    v_cursor        record;
    v_creds         jsonb;
    v_headers       jsonb;
    v_url           text;
    v_response      jsonb;
    v_http_status   integer;
    v_body          text;
    v_ingest        record;
begin
    -- Load stream
    select * into v_sub
    from inferal_relay.streams
    where name = p_stream_name;

    if not found then
        raise exception 'Stream "%" not found', p_stream_name;
    end if;

    if not v_sub.enabled then
        raise exception 'Stream "%" is disabled', p_stream_name;
    end if;

    -- Load cursor
    select * into v_cursor
    from inferal_relay.cursors
    where stream_name = p_stream_name;

    -- Get credentials and build headers
    begin
        v_creds := inferal_relay.get_credentials(p_stream_name);
    exception when others then
        v_creds := null;
    end;

    v_headers := jsonb_build_object('Accept', 'application/ld+json');
    if v_creds is not null and v_creds ->> 'api_key' is not null then
        v_headers := v_headers || jsonb_build_object(
            'Authorization', 'Bearer ' || (v_creds ->> 'api_key')
        );
    end if;

    -- Build URL
    v_url := inferal_relay.build_next_url(
        p_stream_name,
        v_cursor.last_event_id,
        v_cursor.partition_hint
    );

    -- Fetch page
    v_response := inferal_relay.http_get(v_url, v_headers);
    v_http_status := (v_response ->> 'status')::integer;

    if v_http_status <> 200 then
        raise exception 'HTTP % from %', v_http_status, v_url;
    end if;

    v_body := v_response ->> 'body';

    -- Ingest page (parse + store + advance cursor)
    select * into v_ingest
    from inferal_relay.ingest_page(p_stream_name, v_body);

    stream := p_stream_name;
    pages_fetched := 1;
    members_received := v_ingest.members_received;
    last_event_id := v_ingest.next_event_id;
    has_more := v_ingest.has_more;
    status := 'completed';
    error := null;
    return next;
    return;
end;
$$;

-- ============================================================================
-- Default adapters
-- ============================================================================

select inferal_relay.install_credential_store_adapter();
