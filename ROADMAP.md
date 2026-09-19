# Darkwood — Current State, Gaps & Roadmap

Audience: engineers picking up this project. Last updated: 2026-09-19.
Branch: `feat/darkwood-mvp`. Gate: `mix precommit` (compile `--warnings-as-errors` + format + test). CI: `.github/workflows/ci.yml` — currently green (38 tests).

---

## 1. What Darkwood is

Real-time collaborative incident workspace. Phoenix 1.8 + LiveView 1.2 + Postgres + PubSub + Presence. MVP scope: display-name session, incident list/create, incident detail with read-only event timeline, general + event-specific annotations, status changes, real-time annotation/status updates, connected-user presence. One seed incident (`Checkout API 500 spike`).

No auth/accounts, no tenancy, no external integrations. That's intentional for the MVP — see gaps before adding any.

## 2. Current state — what works now

The machinery hardening pass is done and CI is green. Concretely:

| Area | State |
|---|---|
| Ingest API | `POST /api/v1/incidents/:id/ingest` persists synchronously via `Incidents.ingest_event` (atomic dedup under advisory lock, broadcast after commit). `202` means the event or its aggregation is **durable in PostgreSQL** and accepted for downstream processing. Fail-closed `occurred_at` validation; malformed/out-of-range timestamps return 422 and persist nothing. |
| Dedup | Atomic per `(incident, fingerprint)` 5s window via `pg_advisory_xact_lock` + `FOR UPDATE`. Aggregates bump `metadata.count/first_seen/last_seen` and broadcast `event_updated`; new rows broadcast `event_created`. Persist first, broadcast second (after commit). |
| Validation | Ingest rejects blank/oversized messages (>5000), bad kind/level, oversized metadata (>50 keys / 32KB), long fingerprints (>128). Schema changesets enforce lengths + FK constraints. |
| API | `POST /api/v1/incidents/:id/ingest` → 202/404/422/429. Optional API key (`INGEST_API_KEY`, header-only ideally), per-IP sliding-window limiter (120/min), malformed IDs return 404 not 500. Rate-limit 429s come from the limiter (no in-memory queue overload path exists anymore). |
| Realtime | Show view streams events/annotations incrementally (no full reload per event), handles `event_created/event_updated/annotation_created/incident_updated/presence_diff`. Index view live-inserts `incident_created`. Presence is per-tab keyed, deduped by display name. |
| Session | Display name 1–80 chars, `client_id` must be a UUID (forged sessions bounced to `/join`), logout clears session. |
| Ops | `GET /health` (DB check + buffer depth, excluded from force-SSL), Dockerfile (multi-stage release), `.dockerignore`, CI gate. |
| Data bounds | All list queries capped (incidents 100, events/annotations 500). Dedup index `(incident_id, fingerprint, inserted_at)`. |

## 3. Gaps — ranked by risk

### P0 — correctness / data loss
1. ~~Accepted ≠ persisted~~ — **resolved by the durable slice.** `202` now means the event or its deduplicated aggregation has committed to PostgreSQL; the in-memory Broadway queue was removed from the HTTP path. DB/transaction failure raises (→ 5xx) or returns an error tuple (→ 4xx) — never success.
2. **`occurred_at` fail-open.** Invalid timestamps silently default to `now` instead of being rejected.
3. **No retention.** `incident_events` grows forever. No cleanup job, partitioning, or archival policy.
4. **Dedup unproven under parallelism.** The advisory lock serializes correctly in theory, but no concurrency test pins it, and the lock is a throughput choke under real flood.

### P1 — security
5. **Auth is opt-in.** Unset `INGEST_API_KEY` = open endpoint. Nothing fails closed at boot in prod.
6. **Key via query/body params** leaks into logs. Accept headers only.
7. **Rate limiter is per-node ETS**, resets on restart, IP-keyed with no proxy handling — behind a LB all clients share one bucket.
8. **No roles.** Any display-name session can change incident status.

### P2 — realtime / distributed
9. **Presence splits across nodes.** `DNSCluster` is wired but there is no real clustering setup — multi-node deploys get divergent responder lists.
10. **Broadcast failures silent.** `PubSub.broadcast` returns are ignored; a down PubSub fails without a trace.
11. **No reconnect backfill test.** Mount reload covers it in practice, but nothing pins the behavior.

### P3 — tests / quality / ops
12. No tests for overload path, ingest auth, `event_updated` rendering, or invalid `occurred_at`. Weak producer test. No load/property tests.
13. `precommit` is compile + format + test only. No Credo, Dialyzer, Sobelow.
14. One Dockerfile + CI. No compose/k8s manifests, backup/restore runbook, log aggregation, dashboards/alerts, or SLOs. Pool sizes are static guesses.

## 4. Product roadmap

- [x] **Phase 0 — Make ingestion durable.** Synchronous persist on the HTTP path, atomic dedup, live aggregation updates, fail-closed timestamps. Broadway removed from the correctness path (deleted, not replaced — no queue, no DLQ). *Done, CI green.*
- [ ] **Phase 1 — Harden the boundary.** Fail-closed auth (raise at boot if `INGEST_API_KEY` missing in prod); header-only keys; retention job (e.g. drop raw events older than N days, keep aggregates). Deliberately no DLQ: there is no async stage left to drain.
- [ ] **Phase 2 — Trust & roles.** Status-change roles/confirmation, distributed-safe rate limiting (or gateway-level), reconnect-backfill tests, concurrency test for dedup window.
- [ ] **Phase 3 — Run it for real.** Cluster setup + presence verification across nodes, k8s manifests, backup/restore docs, dashboards/alerts on `ingestion.drop` + buffer depth, SLOs (ingest p99, LiveView update latency), Credo/Dialyzer in CI.
- [ ] **Phase 4 — Intelligence (Jev).** See §5. Deliberately last: automate triage only once the pipeline doesn't lose data.

Exit criteria per phase: `mix precommit` green + the new behavior covered by a test that fails without the change.

## 5. Jev implementation plan (TypeSafe AI)

Jev (System One model) returns **typed decisions with calibrated confidence** — not text. Primitives: `Choice` (pick an option), `Score` (rubric score), `Noul` (statement truth 0–1). Fast and cheap enough for per-event use. The architectural fit: **model proposes with confidence, humans confirm, code gates autonomy on thresholds.**

### 5.1 Mappings to Darkwood

| Need today | Primitive | Question (atomic, one factor each) |
|---|---|---|
| Severity is manual | `Choice` over `minor/major/critical` | Per event, from payload + recent timeline |
| Dedup is fixed 5s + fingerprint | `Score` on `actionable`, `customer_impact` | Stretch/shrink aggregation window per fingerprint; suppress noise from timeline |
| No escalation signal | `Noul`: "this burst is a customer-facing outage" | Gate auto-escalation (`→ identified`, page) on high `noul` |

Never let model output write `status` directly. Suggestions only; responders confirm in the UI.

### 5.2 Architecture

```
IngestController (202 = durable) → Incidents.ingest_event (persist + broadcast after commit)
                                         └→ Triage.score_async (post-persist, non-blocking, future)
                                                              → Jev API via Req (short timeout, fail open)
                                                              → persist suggestion → broadcast {:triage_updated}
                                                              → LiveView badge (suggestion + confidence + confirm/dismiss)
```

- New `Darkwood.Triage` context; migration adds `suggested_severity`, `triage_confidence`, `triage_model_version` (nullable — absence means "not scored").
- Call Jev **post-persist, async**. On timeout/error: keep current behavior, emit `[:darkwood, :triage, :error]` telemetry. The 202 path must never block on the model.
- Thresholds in `config/runtime.exs` (e.g. auto-apply severity at confidence ≥ 0.9, suggest-only below). Tune from data, not guesswork.
- Strip PII/secrets from metadata before sending anything to a third party.

### 5.3 Rollout

1. **Offline spike.** Score the seed incident's 5 events + a synthetic flood. Confirm output shape, latency, cost. No pipeline code yet.
2. **Suggest-only.** Persist + render suggestions; humans confirm/dismiss; log every decision + outcome for calibration review.
3. **Calibrate.** Backtest on historical floods; set per-question thresholds from measured precision/recall.
4. **Gated autonomy.** Auto-apply only high-confidence severity suggestions; everything else stays human-confirmed. Keep a kill switch (single config flag).

### 5.4 Tests

- `Req` stubbed in tests; assert mapping logic, threshold gating, and fail-open behavior (Jev down → ingest still works).
- Eval set: fixed fixtures with expected decisions; re-run on model version bump.
- Contract test on the transformer output shape (`choice/probabilities/confidence`).

### 5.5 Risks (read before building)

- Jev is v0.01 early access: pin versions, expect API churn, keep it behind an interface you can swap.
- Calibration is only valid **on our distribution** — validate on our incidents before auto-applying.
- Third-party data exposure: confirm retention/privacy terms; minimize payload.
- New vendor + latency dependency on the hot path; fail-open is non-negotiable.

## 6. Open questions for engineers

1. Retention target for raw events (30/90 days?) and who owns the cleanup job?
2. Should `INGEST_API_KEY` be mandatory in prod starting Phase 1 (breaking change for current clients)?
3. Single-node or clustered deployment — does presence need to work across nodes in the next milestone?
4. Jev spike: who owns the eval set, and what precision bar gates auto-apply?
