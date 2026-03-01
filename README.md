# pg_inferal_relay

PostgreSQL extension for consuming [LDES](https://w3id.org/ldes/specification) streams from [Inferal Relay](https://relay.inferal.com).

Pure SQL/PL/pgSQL: works as a PGXS extension, copy-paste SQL, or Trusted Language Extension (TLE).

## Install

### Option A: PGXS

```bash
make install
```

```sql
CREATE EXTENSION pg_inferal_relay;
```

### Option B: Copy-paste

```sql
\i sql/pg_inferal_relay--0.1.0.sql
```

### Option C: Trusted Language Extension (TLE)

```bash
./scripts/build-tle.sh > /tmp/pg_inferal_relay_tle.sql
```

```sql
SELECT pgtle.install_extension(
    'pg_inferal_relay', '0.1.0',
    'Consume LDES streams from Inferal Relay',
    pg_read_file('/tmp/pg_inferal_relay_tle.sql')
);
CREATE EXTENSION pg_inferal_relay SCHEMA inferal_relay;
```

## Configure adapters

The extension uses an `http_get` callback that raises an exception by default. Install an HTTP adapter before syncing.

### pgsql-http adapter (production HTTP)

Requires the [pgsql-http](https://github.com/pramsey/pgsql-http) extension:

```sql
CREATE EXTENSION http;
SELECT inferal_relay.install_pgsql_http_adapter();
```

### pg_net adapter (Supabase / async HTTP)

Requires [pg_net](https://github.com/supabase/pg_net) and [dblink](https://www.postgresql.org/docs/current/dblink.html):

```sql
CREATE EXTENSION pg_net;
CREATE EXTENSION dblink;
SELECT inferal_relay.install_pg_net_adapter();
```

pg_net is async (requests are sent after transaction commit). The adapter uses dblink to bridge this by executing pg_net calls in a separate transaction, making it compatible with the synchronous `sync()` workflow. Responses are polled for up to 5 seconds.

**Note:** This adapter is slower than pgsql-http due to the async-to-sync bridge overhead (dblink connection, transaction round-trips, polling). Prefer pgsql-http when available.

### pg_curl adapter

Requires [pg_curl](https://github.com/RekGRpth/pg_curl):

```sql
CREATE EXTENSION pg_curl;
SELECT inferal_relay.install_pg_curl_adapter();
```

pg_curl binds libcurl directly into PostgreSQL. Synchronous like pgsql-http.

### Credentials

The extension includes a built-in credential store. Store API keys per stream:

```sql
INSERT INTO inferal_relay.credentials(stream_name, api_key)
VALUES ('my-stream', 'your-api-key');
```

For Supabase, you can replace the built-in store with the Vault adapter. Requires `vault.decrypted_secrets`. Store credentials in Vault with the name `inferal_relay_{stream_name}`:

```sql
SELECT inferal_relay.install_vault_adapter();
```

To switch back to the built-in store:

```sql
SELECT inferal_relay.install_credential_store_adapter();
```

### External sync (no HTTP extension)

For environments without C HTTP extensions (TLE installs, managed PostgreSQL), drive the sync loop from an external client:

```sql
-- Get the URL to fetch
SELECT inferal_relay.build_next_url('my-stream');

-- Fetch externally (curl, CF Worker, cron script, etc.)
-- Then push the response body into PostgreSQL:
SELECT * FROM inferal_relay.ingest_page('my-stream', $body);
-- Returns: members_received, next_event_id, next_partition_hint, has_more

-- Repeat while has_more = true
```

`ingest_page()` handles parsing, member storage, context upsert, and cursor advancement. No HTTP adapter is needed.

### Mock HTTP adapter (testing)

Replaces `http_get` with a table-driven mock. No prerequisites:

```sql
SELECT inferal_relay.install_mock_adapter();
```

Queue mock HTTP responses (consumed in insertion order):

```sql
INSERT INTO inferal_relay.mock_responses(url_pattern, status_code, body)
VALUES ('.*', 200, '{"tree:member": []}');
```

## Usage

### Create a stream

```sql
INSERT INTO inferal_relay.streams(name, base_url, stream_id, facet)
VALUES ('my-stream', 'https://relay.inferal.com', 'acme', 'snapshots');
```

A cursor row is automatically created by the trigger.

### Sync data

```sql
-- Sync until caught up (or max 100 pages)
SELECT inferal_relay.sync('my-stream');

-- Sync with custom page limit
SELECT inferal_relay.sync('my-stream', max_pages := 10);

-- Fetch exactly one page (for manual/cron workflows)
SELECT inferal_relay.sync_page('my-stream');
```

### Query members

```sql
-- Latest members
SELECT member_id, generated_at, member_path, data
FROM   inferal_relay.members
WHERE  stream_name = 'my-stream'
ORDER BY generated_at DESC
LIMIT 10;

-- Extract fields from member data
SELECT data ->> 'name' AS name,
       member_path,
       generated_at
FROM   inferal_relay.members
WHERE  stream_name = 'my-stream';
```

### Resolve compact IRIs

After syncing, the `@context` from each response is parsed into term mappings. Use `resolve_term()` to expand compact IRIs to full URIs:

```sql
-- Expand a prefixed term
SELECT inferal_relay.resolve_term('my-stream', 'relay:eventId');
-- → 'https://relay.inferal.com/ontology#eventId'

-- Bare terms fall back to @vocab
SELECT inferal_relay.resolve_term('my-stream', 'name');
-- → 'https://schema.org/name'

-- Resolve against a specific context version
SELECT inferal_relay.resolve_term('my-stream', 'fileCount', m.context_id)
FROM   inferal_relay.members m
WHERE  m.stream_name = 'my-stream'
LIMIT  1;
```

### Check status

```sql
SELECT inferal_relay.get_stream_status('my-stream');
```

Returns:
```json
{
  "name": "my-stream",
  "enabled": true,
  "pages_fetched": 42,
  "members_received": 4200,
  "last_event_id": "018f3b3c-4d00-7000-8000-000000000000",
  "last_synced_at": "2026-01-27T12:00:00Z"
}
```

### Manage streams

```sql
-- Disable
UPDATE inferal_relay.streams SET enabled = false WHERE name = 'my-stream';

-- Change page size
UPDATE inferal_relay.streams SET page_limit = 50 WHERE name = 'my-stream';

-- Delete (cascades to cursor, members, sync_log)
DELETE FROM inferal_relay.streams WHERE name = 'my-stream';

-- Reset cursor (re-sync from beginning, keeps existing members)
SELECT inferal_relay.reset_cursor('my-stream');
```

### View sync history

```sql
SELECT started_at, finished_at, pages_fetched, members_received, status, error_message
FROM   inferal_relay.sync_log
WHERE  stream_name = 'my-stream'
ORDER BY started_at DESC
LIMIT 5;
```

## Tables

| Table | Purpose |
|-------|---------|
| `inferal_relay.streams` | Stream endpoint configuration |
| `inferal_relay.cursors` | Pagination state (1:1 with streams) |
| `inferal_relay.members` | Stored LDES members with extracted index columns |
| `inferal_relay.contexts` | Deduplicated JSON-LD contexts per stream (by hash) |
| `inferal_relay.context_terms` | Parsed term-to-IRI mappings from contexts |
| `inferal_relay.sync_log` | Audit trail of sync operations |
| `inferal_relay.credentials` | API keys per stream (built-in credential store) |

## Writing custom adapters

### HTTP adapter

Implement `inferal_relay.http_get(url text, headers jsonb) RETURNS jsonb` returning:

```json
{"status": 200, "body": "<response body>", "headers": {}}
```

### Credentials adapter

Implement `inferal_relay.get_credentials(stream_name text) RETURNS jsonb` returning:

```json
{"api_key": "your-api-key"}
```

Return `NULL` for unauthenticated streams.

## Testing

Tests use [pgTAP](https://pgtap.org/) with the mock adapter (no network needed):

```bash
make test PG=18
```

## Requirements

- PostgreSQL 14+
- PL/pgSQL (included with PostgreSQL)
- An HTTP adapter (pgsql-http recommended, pg_curl, or pg_net + dblink)

## License

PostgreSQL License
