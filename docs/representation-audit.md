# Darkwood Representation Audit

Scope: the system as it exists at `a1f77a4` (durable-ingestion baseline: `HTTP 202` ⇒ event or aggregation committed to PostgreSQL). Analysis only — no code changed for this document.

Established pattern (quality bar, already done): `HTTP accepted → in-memory queue → Broadway → persistence` became `HTTP accepted = PostgreSQL commit`, and the queue, processors, failure semantics, and prospective DLQ disappeared. Every candidate below is judged against that shape: **different representation → less system**, never system + smarter component.

## 1. Mechanism map (as built)

| Mechanism | Concept represented | Current representation | Machinery required by it |
|---|---|---|---|
| Event ingestion | "evidence arrived" | Synchronous `POST` → `Incidents.ingest_event/2` → transaction → `202` | Controller validation duplicated in context, `safe_get`, changeset→422 mapping, rate limiter + ETS table |
| Event identity | "same occurrence" | `fingerprint = sha256(kind:message)`, computed or client-supplied | Fingerprint normalization, length validation, `(incident_id, fingerprint)` index |
| 5s dedup | "flood = one fact" | `recent_event` lookup (`inserted_at >= now-5s`) insideTx advisory lock + `FOR UPDATE` | Advisory-lock call, `recent_event` query, `FOR UPDATE`, aggregate-vs-insert branch, `@aggregation_window_seconds` threading |
| `metadata.count` | "how many times" | Integer inside schemaless `metadata` map, string-key normalized, whole-map rewrite per duplicate | Key stringification, count-default-1 fallback, read-modify-write update, metadata size validation (partly exists for this) |
| `first_seen`/`last_seen` | "over what interval" | ISO strings inside `metadata`, derived-fallback to `inserted_at` | `first_seen` fallback derivation, ISO encode/decode, range display in `aggregation_badge` |
| Chronology | "what happened, in order" | `occurred_at` column + fail-closed parsing + `ORDER BY occurred_at` | Column, bounds validation (5min skew / 30d), 422 paths, `occurred_at` index, backfill/out-of-order handling |
| Incident state | "a container for investigation" | `incidents` row (title/summary) + `Multi` sample insert + FK parent for events/annotations | Table, sample-creation transaction, `get/list` functions, partial unique title index, FK constraints |
| Severity | "how bad, by human judgment" | Stored enum (`minor/major/critical`) set at creation | Column, cast validation, form select input, display branch, severity index |
| Status | "where the response stands" | Stored enum + `status_changeset` + `incident_updated` broadcast + badge/buttons | Column, changeset, `update_incident_status`, `handle_info`, status-button UI, status index |
| Annotations | "responder notes, optionally anchored" | `annotations` table + nullable `event_id` FK + cross-incident validation + `preload(:event)` | Table, 3 indexes, schema/changeset, `event_belongs_to_incident` check, preload, event-select options, two forms/streams |
| PubSub | "something changed" | 3 typed messages (`event_created`, `event_updated`, `annotation_created`, `incident_updated`) per `incident:<id>` topic | Per-type `handle_info` clauses, `append_event_option` bookkeeping, reload-vs-insert decisions |
| LiveView projections | "current view" | Streams (`:events`, `:annotations`) + assigns (`incident`, `users`) updated incrementally | Stream inserts, empty-state handling, present-user mapping, per-item DOM ids |
| Presence | "who is here now" | `Phoenix.Presence` track with `client_id:socket` compound key, `presence_diff` → deduped user list | `presence.ex`, track call, `present_users` (first-meta + uniq + sort), `phx_ref` pill ids |

## 2. Candidates

### Candidate: idempotency-key dedup

**Existing representation**

Duplicates are *recognized*: `fingerprint = sha256(kind:message)` plus a 5-second recency window defines "same occurrence". Recognition happens in application code (`recent_event` SELECT), serialized by a transaction-scoped advisory lock plus `FOR UPDATE`, followed by a read-modify-write branch (aggregate vs insert).

**Alternative representation**

Duplicates are *impossible*: a `dedupe_key` (deterministic content hash over kind/message/truncated-timestamp-bucket, or client-supplied idempotency key) with `UNIQUE(incident_id, dedupe_key)` and a single `INSERT … ON CONFLICT DO UPDATE count = count + 1, last_seen = now`. The database, not the application, owns identity.

**Machinery that could disappear**

`pg_advisory_xact_lock` call, `recent_event` query, `FOR UPDATE`, the aggregate-vs-insert branch in `do_ingest`, `first_seen` fallback derivation, `@aggregation_window_seconds` threading through validation/transaction code, and arguably the `(incident_id, fingerprint, inserted_at)` lookup index (replaced by the uniqueness index doing double duty).

**Why this might be wrong**

Time-bucketing reintroduces edge duplicates (same burst split across adjacent buckets); a uniqueness index grows with every distinct key and turns the flood problem into index bloat; `ON CONFLICT DO UPDATE` still takes a row lock per duplicate, so the serialization cost moves rather than vanishes; client-supplied keys push identity discipline onto every emitter.

**Smallest falsification experiment**

Replace the `do_ingest` transaction body with `Repo.insert(on_conflict: …)` against a new unique index, keep the public API identical, and run the existing 200-flood test plus a parallel `Task.async_stream` flood asserting exactly one row with `count == 200`.

### Candidate: immutable rows with read-time grouping

**Existing representation**

A burst is *one row that mutates*: the first event is inserted, later duplicates rewrite its `metadata` (`count`, `first_seen`, `last_seen`) in place.

**Alternative representation**

A burst is *many immutable rows*: every ingest inserts; the timeline groups by `fingerprint` at read time (`GROUP BY` count + `MIN/MAX(occurred_at)`), in a view or query. Rows are never updated.

**Machinery that could disappear**

The entire `aggregate_existing` path, the advisory lock, `metadata` count/range bookkeeping and its string-key normalization, the `event_updated` broadcast path and its LiveView handler, and metadata size validation motivated by rewrite amplification.

**Why this might be wrong**

Floods become row explosions (100k rows for one burst), timeline queries pay grouping cost on every load, retention gets strictly worse, and per-event DOM rendering would need the grouping to happen before streaming anyway.

**Smallest falsification experiment**

Seed 100k duplicate rows for one incident and `EXPLAIN ANALYZE` the grouped timeline query against the current aggregated read; compare p50/p99 and decide whether any flood size keeps grouping cheaper than the write-path lock it removes.

### Candidate: insertion-ordered timeline

**Existing representation**

Order is *claimed occurrence time*: `occurred_at` column, fail-closed ISO parsing, 5-minute future skew / 30-day retention bounds, `ORDER BY occurred_at`, separate `inserted_at`.

**Alternative representation**

Order is *arrival order*: timeline renders `ORDER BY id`; `occurred_at` is dropped entirely and late/out-of-order delivery is accepted as ordering noise.

**Machinery that could disappear**

The `occurred_at` column, its parsing/validation/bounds code and 422 paths, the `occurred_at` index, the `first_seen`/`last_seen` distinction (both become row positions), and all backfill handling.

**Why this might be wrong**

External emitters deliver delayed and out-of-order evidence (the seed incident's payment-upstream 503 *causes* the checkout 500s that arrive earlier in wall time); insertion order then lies about causality, which is the one thing an incident timeline must not do.

**Smallest falsification experiment**

Ingest the five seed events shuffled (valid `occurred_at` preserved) and diff the rendered timeline against the canonical order; one visible causality inversion falsifies arrival-order sufficiency.

### Candidate: status changes as annotation-typed entries

**Existing representation**

Response state is *a column*: `status` enum on `incidents`, mutated via `status_changeset`, announced via a dedicated `incident_updated` broadcast, rendered as badge + buttons.

**Alternative representation**

Response state is *the latest entry*: status changes are rows in `annotations` (or a unified entries table) with a `kind = :status` marker; current status = most recent status entry; the `status` column disappears.

**Machinery that could disappear**

The `status` column + migration, `status_changeset`, the `update_incident_status` branch, the `incident_updated` message path and its handler, and the status index — status flows through the already-built annotation broadcast/stream machinery, and the status history (currently lost on every overwrite) comes for free.

**Why this might be wrong**

Every incident load and every list row needs "current status" — a latest-row subquery per incident (or join) on the hottest read paths; the list page would pay it N times; status transitions lose their explicit state-machine shape and admit invalid jumps unless re-validated at the entry layer.

**Smallest falsification experiment**

Implement `current_status(incident)` as a latest-status-entry query behind the existing context API without touching LiveViews, and compare query count/latency on the index page (N incidents) versus the column read.

### Candidate: derived-or-dropped severity

**Existing representation**

Badness is *stored human judgment*: `severity` enum chosen at incident creation, validated, indexed, displayed.

**Alternative representation**

Badness is *derived or absent*: `severity = f(max(event.level))` (any `error` ⇒ critical-ish), or the field is dropped and only status + timeline exist.

**Why this might be wrong**

This is the strongest counterargument in the audit: severity records *business impact as judged by a human*, which is not a function of log levels — the seed incident is critical while most of its events are `info`/`warning`. Deriving it from levels confuses signal noisiness with customer harm; dropping it removes the only field that says "how much should we care" as opposed to "what happened".

**Machinery that could disappear**

The `severity` column/validation/form input/display branch and its index — if the experiment below shows nobody acts on it.

**Smallest falsification experiment**

Repository evidence only: the seed incident already falsifies pure derivation (critical incident, non-error events). For the drop variant, check whether any code path *branches* on severity (alerting, sorting, filtering) — currently none does; it is display-only, which bounds the removal cost to the form + column.

### Candidate: incident as tag, not container

**Existing representation**

An incident is *a parent row*: `incidents` table owns title/summary, parents events and annotations via FKs, requires a creation transaction and a sample-data `Multi`.

**Alternative representation**

An incident is *a key*: events carry an `incident_key` string with no FK; the "incident" is the set of rows sharing a key, with title/summary as first-class rows or derived from the first entry. Creation is just the first insert.

**Machinery that could disappear**

The `incidents` table, the sample-creation `Multi` (+1 transaction), `get/list` incident functions, the partial unique title index, FK constraints and their changeset counterparts, and the incident-creation form/LiveView round-trip.

**Why this might be wrong**

Referential integrity evaporates (orphaned events, key typos fork incidents silently); listing/pagination/sorting incidents becomes `GROUP BY` over the events table; status/severity/title have nowhere canonical to live and each regrow their own storage — the container table likely re-emerges under a new name.

**Smallest falsification experiment**

Reimplement `list_incidents` as `SELECT DISTINCT incident_key … ORDER BY MIN(inserted_at)` over the events table and measure it against the current indexed read at 100k-row scale; a 10x regression or any orphaned-key anomaly ends the experiment.

### Candidate: join/leave broadcasts instead of Presence

**Existing representation**

"Who is here" is *reconciled distributed state*: `Phoenix.Presence` tracks `client_id:socket` keys with heartbeats/CRDT merge, and LiveViews map metas on every `presence_diff`.

**Alternative representation**

"Who is here" is *a local set*: mount broadcasts `{:responder_joined, name}`, `terminate` broadcasts `{:responder_left, name}`; each LiveView holds a `MapSet` in assigns. No Presence process, no metas, no diff mapping.

**Machinery that could disappear**

`presence.ex`, the track call with compound keys, `present_users` (first-meta/uniq/sort), `phx_ref` pill ids, and the multi-tab dedup special-casing.

**Why this might be wrong**

This is what Presence exists to defeat: crashed browsers, killed nodes, and net splits never send `terminate`, so ghosts accumulate with no heartbeat to reap them and no CRDT to reconcile partitions. Correctness of "who is here" under failure is the entire product of the current machinery.

**Smallest falsification experiment**

Kill -9 a browser equivalent mid-session (terminate a LiveView process with `:kill`, trapping nothing) and observe whether the responder list converges back to truth within the heartbeat window under both implementations.

## 3. Assumptions needing external research (not repo-provable)

- Whether responders act on `severity` vs `status` in real incidents (decides the severity candidate; needs operator observation, not code).
- Whether emitters can supply idempotency keys (decides the dedup-key candidate; needs emitter contracts).
- Whether timeline consumers tolerate arrival-order noise (decides chronology; needs UX evidence).
- Whether multi-node deployment is ever planned (decides how much Presence complexity is load-bearing vs speculative).
