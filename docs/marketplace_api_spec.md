# Marketplace API Spec — Off-chain Migration Implementation Plan

Two phases plus an optional third. Phase 1 builds every piece of code we need. Phase 2 rolls it out without leaving an analytics gap. Phase 3 is deferred scaling.

This document is the marketplace-side API and rollout spec for moving mech requests off the public chain rails. The analytics ETL sub-phase has its own document at `docs/mech_analytics_etl_spec.md`; the x402 payment family proposal lives in `docs/x402_spec.md`.

## Phases at a glance

| Phase | What ships | Contract changes |
|-------|------------|------------------|
| **Phase 1 — Build** | All code: enhanced offchain HTTP path, commit-reveal privacy, structured 402, mech failover via client retry, wildcard schema additions for mech request/response rows, mech-side write path into wildcard, analytics ETL service, metrics Postgres + public Wildcard API, olas-website rewrites, historical IPFS ETL. Nothing flipped on in production. | None |
| **Phase 2 — Rollout** | Staged rollout: backfill the wildcard data lake from IPFS for gnosis/base/polygon plus legacy mech contracts on Gnosis, dual-write window for parity, cut olas-website to the new Wildcard API, flip mechs to offchain HTTP per deployment, flip the default to offchain last. | None |
| **Phase 3 — Optional scaling (deferred)** | Cumulative voucher, multi-requester batching, fail-soft batching, optional 503 backpressure, cross-path runtime fallback. Build only when volume justifies. | Yes (audit-needed) |

## Why this shape

We want privacy, low cost, and good analytics. The marketplace already exposes an offchain HTTP path; most consumers don't use it. Phase 1 enhances it (privacy via commit-reveal, structured 402, failover via client retry, full analytics surface) and builds everything dark behind feature flags. Phase 2 is the cutover. Phase 3 is held in reserve for when offchain volume crosses a contract-changing-is-worth-it threshold.

## What we are explicitly NOT doing

- No requester withdrawal entry. Money committed to the marketplace stays committed.
- No new escrow contract.
- No new cryptography. Privacy is achieved by not publishing, not by encryption.
- The existing on-chain path with IPFS pinning stays available across all apps. We don't remove it. The change is the default: today's default is "publish everything to IPFS", the new default is "keep everything private offchain". Both modes are config-flag selectable per consumer.
- No MPP or x402 wire compatibility on day one. Design leaves a short path to it later.
- No coordination registry, no mech-to-mech P2P, no on-chain runtime fallback for failover. Client-side retry with the contract's nonce mutex is enough.
- No new database for raw request/response data. Wildcard's Postgres is the data lake — all mech request/response rows live there. A separate analytics service runs ETL on top, writes computed metrics to its own metrics Postgres, and serves them via a public Cloudflare-protected API.
- No reworked mech selection algorithm. Existing `_calc_score` ranking stays unchanged in Phase 1.

---

# Phase 1 — Build everything

## TL;DR

Land every piece of code: HTTP request path, privacy via commit-reveal, structured 402 + Payment-Receipt, failover via client-side retry, wildcard schema additions for the full request/response rows, a mech-side write path into wildcard, an analytics ETL service, a metrics Postgres with a public Wildcard API in front of it, olas-website rewrites to call that API, and the historical IPFS ETL ready to run. Nothing goes live to users in Phase 1 — the existing IPFS flow still serves production while Phase 1 work merges behind feature flags.

## What changes, module by module

Sixteen workstreams. One-liner each before the detail further down.

- **Mech server (CODE)** — Skip the IPFS upload on the offchain path, compute the CID locally, persist preimages to disk via `valory/kv_store`, add structured 402 + `Payment-Receipt` headers.
- **Mech-client (CODE)** — Drop the IPFS upload on the offchain path, compute the CID locally, parse the structured 402 (optional auto-deposit).
- **Mech-interact (DOMINANT COST)** — New HTTP request/response path, mech failover retry (re-sign at same on-chain nonce on timeout), per-mech URL from manifest, iterate the existing ranked list.
- **Agent config (CODE)** — One `use_offchain` feature flag added to each consuming service's `service.yaml`, per-deployment rollback path.
- **Wildcard schema additions (SCHEMA)** — Add `mech_requests`, `mech_responses`, `mech_migration_failures` tables to the existing wildcard Postgres alongside pearl-mini predictions. The auth-swap follow-up additionally drops `mech_operator_keys` without replacement (signature-based auth needs no per-operator table; see auth section).
- **Mech write client (CODE)** — Posts ONE event to `POST /mech/events` on the wildcard server per settled delivery (right after on-chain settlement confirms). Local replay buffer on failure.
- **Analytics ETL service (NEW)** — Incremental ETL over the wildcard data lake; computes metrics for olas-website plus scoring metrics (Brier, calibration, edge, directional accuracy, log loss, ECE, no-signal rate, BSS) so mech-predict reads precomputed scores.
- **Metrics Postgres (NEW)** — Small dedicated instance holding only computed metrics, one table per metric family.
- **Wildcard API (NEW)** — Public, Cloudflare-protected FastAPI in front of the metrics Postgres. One endpoint shape: `GET /metrics/agent-economy/{agent_name}` returns a unified JSON of all metrics for that agent.
- **olas-website rewrites (CODE)** — Three metric files call the Wildcard API instead of fuzzy-matching the subgraph. Verify links become curl invocations of the same API. Output shape unchanged.
- **Historical IPFS ETL (CODE)** — One-time backfill of every past request and response from IPFS. Covers new marketplace subgraphs (gnosis, base, polygon) AND legacy `agent_mech` subgraphs on Gnosis. Built now, runs in Phase 2.
- **Auth & rate limits (CODE)** — EIP-712 signature auth on the `POST /mech/events` write side, designed for batched writes. Each batch (1 to N delivered events from one settled FSM round) is signed once by an operator EOA that owns the mech's Safe. The signed typed-data carries the Safe address plus a `batch_hash = keccak256(canonical_json(events))`, so the signature covers the actual row payloads, not just metadata. Server side: `ecrecover` the operator EOA, confirm it is an owner of the declared `mech_service_multisig` via `Safe.getOwners` (cached), confirm the multisig is a registered mech via `checkMech` (cached), recompute and compare the batch hash, insert all rows in one transaction. Replay safety comes from `mech_requests.request_id` PK with `ON CONFLICT DO NOTHING`, so no nonce table is needed. Per-signer sliding-window rate limit (~200 writes/sec). Read API is public behind Cloudflare. No bearer tokens, no key distribution, no rotation. The mech's existing on-chain identity is the credential.
- **Operator retention (OPS)** — Persistent preimage buffer on the mech's disk via `valory/kv_store` (SQLite-backed, WAL mode), default 24h retention, configurable.
- **Staking compatibility (NEW)** — Deploy `RequesterActivityCheckerV2`, redeploy every affected staking program wired to it, governance vote to add new programs to OLAS rewards, parallel-run during user migration, second governance vote to retire old programs.
- **townhall-kpis rewrite (CODE)** — Two metric paths swap from subgraph to the Wildcard API. ROI math unchanged.
- **mech-predict benchmark rewrite (CODE)** — Daily report reads precomputed scores from the Wildcard API. Recompute path (prompt sweeps, tournament mode) uses direct read-only SQL against the wildcard data lake. `production_log_xxxx` CI artifacts dropped.
- **market-resolver rewrite (CODE)** — Drop the per-cycle mech subgraph cache query, use a local on-disk SQLite store on the agent's PVC. Late-delivery semantics preserved via existing on-chain settlement polling.
- **Marketplace subgraph (NO CHANGE)** — Already handles `MarketplaceDeliveryWithSignatures` and increments discovery counters for offchain settlements (`autonolas-subgraph/.../mech-marketplace.ts:270-278`). Trader's mech ranking keeps working unchanged. The `ParsedRequest` entity stops being populated for offchain rows (IPFS-sourced content goes empty) — that's expected; the consumers that read it migrate to the data lake.

## Tasks at a glance

**Privacy (commit-reveal):**
- [ ] Add `is_offchain` flag to the mech task struct
- [ ] Mech: when `is_offchain=true`, skip IPFS upload of request metadata; when `false`, publish to IPFS as today
- [ ] Mech: when `is_offchain=true`, skip IPFS upload of response; when `false`, publish as today
- [ ] Mech: compute content hash locally instead of uploading (offchain mode)
- [ ] Mech-client: drop the IPFS upload step on the offchain path
- [ ] Mech-client: compute the content hash locally before posting

**Mech-interact offchain branch:**
- [ ] Build new offchain request behaviour (HTTP POST)
- [ ] Build new offchain response behaviour (polling)
- [ ] Trader and other consuming agents: add one config flag in `service.yaml`

**Improved 402 challenge + receipt headers:**
- [ ] Mech: emit `WWW-Authenticate: Payment` header on 402
- [ ] Mech: replace empty 402 body with structured JSON (scheme, payTo, currentBalance, required, depositInstructions)
- [ ] Mech: emit `Payment-Receipt` header on 200
- [ ] Mech-client: parse structured 402, optional auto-deposit + retry, log receipt
- [ ] Mech-interact: parse 402, build multisend (approve + depositFor), retry after deposit, log receipt

**Mech failover (client-side retry with contract nonce mutex):**
- [ ] Mech-interact: configurable per-tool HTTP timeout (default 60s)
- [ ] Mech-interact: on HTTP timeout, sign a fresh request for the next priority mech at the same on-chain nonce
- [ ] Mech-interact: cap on retries (default 2 — three mechs total)
- [ ] Confirm `MechMarketplace.sol:222-263` nonce monotonicity prevents double-billing
- [ ] Document the residual operator-side LLM-cost race as accepted trade-off — note that this is NOT step-in; step-in remains an on-chain-only mechanism

**Mech selection (offchain + onchain):**
- [ ] Read per-mech HTTP URL from existing IPFS manifest and store on `MechInfo`; keep `_calc_score` ranking algorithm unchanged
- [ ] Consume the existing ranked list (`ranked_mechs_addresses`) in the offchain branch; iterate via `offchain_attempted_mechs` set on synchronized_data
- [ ] Dispatch on `use_offchain` flag in `MechMarketplaceConfig` — `false` keeps today's on-chain selection bit-for-bit unchanged, `true` engages the offchain iteration
- [ ] Extend `last_failure_reason` enum with offchain-specific values (`offchain_all_failed`, `offchain_402_insufficient`, `offchain_timeout_all_mechs`)

**Wildcard schema additions (data lake):**
- [ ] Add `mech_requests` table to the existing wildcard Postgres (raw request rows)
- [ ] Add `mech_responses` table (raw response rows, FK to `mech_requests`)
- [ ] Add `mech_migration_failures` audit table for the ETL
- [ ] Drop `mech_operator_keys` in the auth-swap follow-up. No replacement table is added (no nonce table either): replay safety comes from `mech_requests.request_id` PK with `ON CONFLICT DO NOTHING`, and tamper safety comes from the signature binding the batch payload hash.
- [ ] Same indexes and monthly partitioning as designed in the schema section below; migrations land in `wildcard/server/alembic/versions/`
- [ ] No new database for raw data — rows live next to pearl-mini predictions

**Mech-side write client (writes to wildcard):**
- [ ] HTTP client to `POST /mech/events` on the wildcard server, with retry + backoff
- [ ] Fire ONCE per settled FSM round as a single batched POST that carries every offchain delivery settled in that round, right after the on-chain `deliverMarketplaceWithSignatures` confirms
- [ ] Populate `requested_at` from the timestamp inside the requester's signed authorization header (signed by requester; mech echoes through, no mech-clock trust)
- [ ] Local replay buffer for write failures; never refuse the original request
- [ ] Sign each batch with one operator EOA (a Safe owner). Typed data covers `(mech_service_multisig, batch_hash)` where `batch_hash = keccak256(canonical_json(events))`, so tampering with any row payload invalidates the signature. No API key, no env-var secret.

**Analytics ETL service (new):**
- [ ] Incremental ETL over `mech_requests` + `mech_responses` (and pearl-mini predictions where relevant)
- [ ] Compute the metrics olas-website needs; pull resolutions from Omen / Polymarket subgraphs
- [ ] Compute the scoring metrics mech-predict tracks today (Brier, calibration, edge, directional accuracy, log loss, ECE, no-signal rate, BSS); persist per-row in the metrics Postgres
- [ ] Compute the per-tool / per-platform / per-category / per-horizon aggregations the agent<>env loop needs; expose via the Wildcard API
- [ ] Write computed metrics to its own dedicated metrics Postgres
- [ ] Scheduled refresh (default every 15 minutes; configurable per metric)
- [ ] Drop `production_log_xxxx` CI artifacts. mech-predict reads precomputed scores from the metrics server for normal use; pulls raw rows from the data lake (SQL) for recompute paths

**Metrics Postgres + Wildcard API (new):**
- [ ] Stand up a small dedicated metrics Postgres (computed metrics only, one table per metric family)
- [ ] Build the Wildcard API: FastAPI in front of the metrics Postgres
- [ ] Single read endpoint: `GET /metrics/agent-economy/{agent_name}` → all metrics for that agent as one JSON
- [ ] Public, Cloudflare-protected; no per-caller auth on the read side
- [ ] Schema agility via versioned response keys; never breaking removal

**olas-website rewrites:**
- [ ] Rewrite `tool-accuracy.ts`, `omenstrat-roi.ts`, `polystrat-roi.ts` to call the Wildcard API (`GET /metrics/agent-economy/{agent_name}`)
- [ ] Pick the relevant fields from the unified JSON response; drop `matchBetToMechRequest` entirely
- [ ] Replace each existing "verify" link on the website with a curl invocation of the matching API endpoint — preserves the verify pattern, points at the new public source
- [ ] Keep existing output shapes so dashboard consumers don't change

**Historical IPFS ETL (ready to run; runs in Phase 2):**
- [ ] Enumerate all historical request_ids + CIDs from BOTH:
  - New marketplace subgraphs on gnosis, base, polygon (`MARKETPLACE_GRAPH_CLIENTS`)
  - Legacy mech subgraphs on Gnosis (`predictAgentsGraphClient`, `legacyMechFeesGraphClient`, the original `agent_mech` contracts)
- [ ] IPFS fetcher with retries, dedup, rate limits
- [ ] Bulk insert into `mech_requests` and `mech_responses` with `source='ipfs_historical'`
- [ ] Failure log to `mech_migration_failures` table
- [ ] Validation harness (row counts vs subgraph totals, sample-row comparison)

**Staking compatibility:**
- [ ] Deploy a new `RequesterActivityCheckerV2` that reads `mapRequestCounts` from the marketplace
- [ ] Drop the `diffRequestsCounts <= diffNonces` check
- [ ] Score on `mapRequestCounts` alone: pass when `(diffRequestsCounts × 1e18) / ts >= livenessRatio`
- [ ] Audit the new checker
- [ ] Redeploy each affected staking program wired to V2 (`activityChecker` is immutable on existing `StakingTokens` — verified at `StakingBase.sol:332`, no setter exists)
- [ ] Olas DAO governance proposal to add new programs to OLAS rewards distribution
- [ ] Run old and new programs in parallel for 4-8 weeks during user migration
- [ ] Communicate to users via Pearl to unstake from old programs and restake into new
- [ ] Second governance vote to retire old programs

**townhall-kpis rewrite:**
- [ ] Replace `NewMechFeesQuery` + `LegacyMechFeesQuery` with one call to the Wildcard API (mech-fees: `{gnosis_new, gnosis_legacy, base_new}` USD totals)
- [ ] Replace the mech-requests slice of `PredictTradesQuery` with `GET /metrics/agent-economy/{agent}` (per-agent mech requests for the same time window)
- [ ] Keep the FPMM trades source unchanged (still the Predict subgraph)
- [ ] Preserve the existing `questionTitle` substring join — same field name and shape, no math change
- [ ] Update env vars (drop the mech-fees subgraph URLs, add `NEXT_PUBLIC_WILDCARD_API_URL`)

**mech-predict benchmark rewrite:**
- [ ] Daily report path: thin client reads precomputed scores from the Wildcard API (no production data fetched, no local scoring)
- [ ] Recompute path (prompt sweeps, tournament mode, `--code-change`): direct read-only SQL against `mech_requests JOIN mech_responses` in the wildcard data lake (no `POST /mech/query` HTTP layer — internal consumers use SQL with a read-only DB role)
- [ ] Read `source_content` from `mech_responses.raw_content.metadata.params.source_content` instead of the IPFS gateway
- [ ] Drop the sample-and-binary-search strategy for source_content (all rows available locally, no per-CID latency)
- [ ] Drop the `production_log_xxxx` CI artifact generation entirely; the data lake is the source of truth
- [ ] Per-platform cursor state stays for the recompute path; default lookback window stays 7 days
- [ ] Keep IPFS as a fallback for pre-migration rows during the Phase 2 dual-write window

**market-resolver rewrite:**
- [ ] Replace `MECH_CACHE_QUERY_TEMPLATE` with reads from a local on-disk store (SQLite) inside market-resolver
- [ ] Key the local store by `(safe_address, market_id)`; index on `market_closing_timestamp`
- [ ] Preserve the in-code `tool == "resolve-market-jury-v1"` filter at read time
- [ ] Keep the unbounded deliveries-per-request shape so late deliveries stay visible
- [ ] Keep the existing on-chain settlement polling — when a delivery lands after the previous cycle, the next cycle picks it up from the chain and writes the response into the local store
- [ ] Update `skill.yaml`: drop the `mech_gnosis_subgraph` model
- [ ] Persistence on the agent's PVC (Propel provisions PVCs automatically)

**Operator retention (preimage buffer):**
- [ ] Write the in-flight (request, response) preimage buffer to a persistent path on disk, not in process memory
- [ ] Use the existing `valory/kv_store` connection (SQLite-backed, WAL mode, already used in optimus and meme-ooorr). Key = `request_id`, value = JSON-encoded `(request_bytes, response_bytes, accepted_at, settled_at, settlement_status)`
- [ ] Default retention 24 hours, operator-configurable
- [ ] Prune entries older than the retention window via a background sweeper
- [ ] Persistent disk auto-provisioned on Propel via PVCs (`propel/services/agent_manager/src/k8s/state_detector.py:13-18`)
- [ ] Verify the persistent write succeeded before returning a success to the client; buffer-write failure is a hard error

## API surface in Phase 1

**Mech-side HTTP — additive to existing routes, no new routes, no body-shape changes on 200:**

| Change | Where | Backwards compatible? |
|--------|-------|------------------------|
| 402 response body goes from empty → structured JSON | `POST /send_signed_requests` 402 path | Yes |
| New `WWW-Authenticate: Payment` header on 402 | `POST /send_signed_requests` 402 path | Yes |
| New `Payment-Receipt` header on 200 | `POST /send_signed_requests` 200 path | Yes |

**Analytics write + read — new endpoints:**

| Endpoint | Purpose | Auth |
|----------|---------|------|
| `POST /mech/events` (on the wildcard server) | Mech writes a batch of settled request/response events into the wildcard data lake (1 to N per FSM round, one signature per POST) | EIP-712 signature from one Safe owner EOA. Server verifies the EOA is an owner of the declared mech multisig via `Safe.getOwners` (cached), the multisig is registered via `checkMech` (cached), and `batch_hash` recomputed from the row payload matches the signed value. Replay protected by `mech_requests.request_id` PK idempotency. |
| `GET /metrics/agent-economy/{agent_name}` (Wildcard API) | All available metrics for the given agent, returned as one JSON | Public, Cloudflare-protected |

`agent_name` is `optimus`, `omenstrat`, `polystrat`, etc. The single JSON response includes every metric currently computed for that agent (tool accuracy, ROI, activity counts, anything added later) — extensible by adding keys, never by adding routes.

## Mech failover design

Step-in stays an on-chain-only mechanism. The marketplace contract supports it via autonomous mech polling (`task_execution/behaviours.py:545`). It works exactly as today for on-chain requests, unchanged.

The offchain HTTP path doesn't have step-in and isn't getting it. Instead we ship a client-side **failover** that gives the same practical outcome — a failing mech is bypassed and the requester isn't double-charged — using only the contract's existing nonce mutex. We're explicit that failover is not step-in: there is no on-chain karma penalty, no autonomous mech pickup, no contract-level coordination.

### The mutex we already have

`MechMarketplace.sol:222` reads `mapNonces[requester]` at the start of every settlement call. `:232` derives the request_id from `(msg.sender, requester, requestData, deliveryRate, paymentType, nonce)`. `:236` verifies the requester's signature over that exact request_id. `:263` advances `mapNonces` after each settled request. The requester has a single monotonic nonce on-chain; whichever mech consumes nonce N first wins, the other's signature for nonce N becomes invalid because `mapNonces` has advanced.

### Two pieces, both stateless

1. **Existing subgraph-based mech selection** (`mech-interact request.py:572-576`). Priority list ranked by historical delivery performance. No new polling.
2. **Client retry on timeout.** Mech-interact uses a generous HTTP timeout (default 60s, configurable per-tool). On timeout, signs a fresh request for the next priority mech at the same on-chain nonce. Retry cap (default 2).

### Operator-side residual

In the rare case where both mechs complete the LLM call in overlapping windows, the losing mech is out the LLM cost (typically $0.01–$0.10). The same hazard exists today on-chain via `AlreadyRequested` revert (`MechMarketplace.sol:242-244`). Accepted as Phase 1-2 trade-off.

### Accepted Phase 1-2 constraints

These are real limitations we accept as part of the Phase 1-2 design. None block any current consumer.

- **One in-flight request per nonce per requester.** Same-nonce signatures are the failover pattern (only one wins by design). Consecutive-nonce concurrent requests technically work but require mech-side retry on out-of-order settlement, which we're not building in Phase 1. All current consumers (trader, market-creator, meme-ooorr, iekit) are single-in-flight FSMs by construction.
- **Settlement-ordering liveness.** A mech that returns HTTP fast but is slow to settle on-chain blocks the requester's subsequent requests from settling until the stalled settlement lands. User-facing HTTP latency isn't affected. Since we operate the mechs, settlement cadence is a knob we control. Phase 3 may add a contract-level cancel mechanism if this hurts in production.
- **No cross-path runtime fallback.** On-chain and offchain share `mapNonces`. Phase 1-2 makes `use_offchain` a per-consumer config choice made up-front, not a per-request runtime alternative. On "clean failure round" the failure surfaces to the FSM as a request failure; the consumer does not automatically retry on the other path because doing so risks voiding a still-pending offchain settlement.

### What we considered and rejected

- **Coordination registry** (a service that holds content + brokers handoff) — content + trust cost on every request, not just on failure
- **On-chain runtime fallback** — pays gas + leaks to IPFS on every failure, introduces cross-path nonce hazard
- **Mech-to-mech P2P forwarding** — privacy regression + trust requirements with no gain over client-retry
- **`/health` polling, self-reported ETA, pre-LLM nonce RPC, best-effort cancel** — each adds per-request state or chain coupling; doesn't scale
- **503 backpressure in Phase 1** — deferred to Phase 3. HTTP timeout + failover already handles overload, just slower

## Detailed implementation

### Mech-side changes (server)

- Add `is_offchain` flag to task struct; when `true` skip IPFS upload and store JSON locally; when `false` publish to IPFS as today
- Skip IPFS upload of response in offchain mode; keep in `offchain_request_responses` dict
- Compute the content CID locally; pass through as `delivery_data` at settlement
- Add the existing `valory/kv_store` connection to the mech's `aea-config.yaml`; write preimages keyed by `request_id` with JSON-encoded value; schedule a sweeper to delete entries past the retention window (default 24h, configurable)
- Build 402 challenge helper (`scheme`, `payTo`, `asset`, `chainId`, `currentBalance`, `required`, `depositInstructions`, `error`)
- Emit `WWW-Authenticate: Payment` + structured body on 402
- Emit `Payment-Receipt` header on 200
- Build write client to `POST /mech/events` on the wildcard server; fire ONCE per settled delivery, right after the on-chain `deliverMarketplaceWithSignatures` confirms; populate `requested_at` from the signed authorization header timestamp; local replay buffer if the write fails (settlement already landed, the row just lands a bit later)

Files touched: `mech/.../task_execution/handlers.py`, `behaviours.py`; `task_submission_abci/behaviours.py`; new helper module for the wildcard write client.

### Mech-client changes

- Skip `fetch_ipfs_hash` on offchain path; build request metadata locally
- Compute content CID locally (same hash format as a real IPFS CID)
- Send JSON inline in existing `ipfs_data` body field
- Parse structured 402; surface `InsufficientBalanceError`; optional auto-deposit + retry
- Log `Payment-Receipt` header on 200

Files: `mech-client/mech_client/services/marketplace_service.py`.

### Mech-interact changes (the dominant cost)

- `OffchainMechRequestBehaviour`: sign `request_id` with Safe key, POST via existing AEA HTTP connection
- `OffchainMechResponseBehaviour`: poll `GET /fetch_offchain_info` until ready or timeout
- Wire new behaviours into round/state machine
- Update `MechToolsSpecs.process_response` (`models.py:56-69`) to return both `tools` and `url`; add `http_url: str` to `MechInfo` (`states/base.py:173-277`); `populate_tools` (`mech_info.py:77-143`) sets the URL on each MechInfo in the manifest's CID group
- Add `get_ranked_mech_addresses_for_offchain()` in `request.py` that returns the existing ranked list, excluding mechs in `offchain_attempted_mechs` for this cycle
- On HTTP timeout: pick next mech from ranked list; sign fresh request at same on-chain nonce; send to next mech; add the failed mech to `offchain_attempted_mechs`
- Retry cap default 2 (three mechs total); transition to clean failure round on exhaustion
- On structured 402: build multisend (`USDC.approve` + `BalanceTracker.depositFor`) via Safe path; submit; retry
- On 200: read `Payment-Receipt`, log via standard agent logger
- Add `use_offchain: bool = False` to `MechMarketplaceConfig` (`models.py:224-240`)
- In `request.py`, branch on `use_offchain`: `false` keeps the existing on-chain submission path; `true` engages the offchain iteration
- In `response.py`, mirror the branch: `false` polls on-chain via `mapRequestIdInfos`; `true` polls `GET /fetch_offchain_info` on the responding mech
- Extend `last_failure_reason` enum (`models.py:409`) with `offchain_all_failed`, `offchain_402_insufficient`, `offchain_timeout_all_mechs`
- The existing `_calc_score` algorithm stays unchanged. The `delivered_ratio` signal degrades under offchain (collapses toward 1.0) but the algo still produces a stable ordering and failover handles "wrong mech at top" at runtime. Reweighting is a follow-up if observed behaviour warrants it.

Files: new `offchain_request.py` and `offchain_response.py`; minor edits to `base.py`, `round_behaviour.py`, `states/base.py`, `payloads.py`, `models.py`.

### Agent / library config changes

- Add `use_offchain: ${USE_OFFCHAIN:bool:true}` in each consuming service's `service.yaml`
- Feature-flag fallback so we can roll back per-deployment

Repos: trader, market-creator, meme-ooorr, iekit, any other consumers of mech-interact.

### Wildcard schema additions (data lake)

All mech request/response rows live in the existing wildcard Postgres alongside pearl-mini predictions. No new database for raw data.

**Schema — `mech_requests` (one row per settled request, added to wildcard):**

| Column | Type | Notes |
|--------|------|-------|
| `request_id` | TEXT | PK |
| `chain_id` | INTEGER | NOT NULL |
| `marketplace_address` | TEXT | NOT NULL |
| `requester` | TEXT | NOT NULL |
| `priority_mech` | TEXT | NOT NULL |
| `delivery_mech` | TEXT | NULL until delivered |
| `payment_type` | TEXT | hex |
| `delivery_rate` | NUMERIC | |
| `nonce` | NUMERIC | |
| `content_cid` | TEXT | Locally-computed CID; same as contract sees |
| `prompt` | TEXT | NOT NULL |
| `tool` | TEXT | NOT NULL |
| `model` | TEXT | NULL |
| `tool_params` | JSONB | NULL |
| `raw_content` | JSONB | NOT NULL. Full IPFS payload for forward compat |
| `requested_at` | TIMESTAMPTZ | from the requester's signed authorization header, echoed by the mech at settlement-write time |
| `source` | TEXT | enum: `mech_offchain`, `ipfs_historical` |
| `created_at` | TIMESTAMPTZ | row insert time |

Indexes: PK; `(chain_id, requested_at DESC)`; `(tool, requested_at DESC)`; `(requester, requested_at DESC)`; `(priority_mech, requested_at DESC)`. Partitioned by `requested_at` monthly past ~10M rows.

**Schema — `mech_responses` (one row per delivered response):**

| Column | Type | Notes |
|--------|------|-------|
| `request_id` | TEXT | PK + FK → `mech_requests` |
| `delivery_mech` | TEXT | NOT NULL |
| `schema_version` | TEXT | From IPFS payload |
| `result` | TEXT | NOT NULL |
| `status` | TEXT | enum: `complete`, `failed` |
| `error` | TEXT | NULL unless failed |
| `executed_at` | TIMESTAMPTZ | |
| `cost_dict` | JSONB | NULL. Token counts |
| `is_offchain` | BOOLEAN | NOT NULL |
| `tool_hash` | TEXT | NULL. IPFS CID of the tool package |
| `execution_latency_ms` | INTEGER | NULL |
| `params_used` | JSONB | NULL |
| `raw_content` | JSONB | NOT NULL. Full IPFS payload |
| `response_cid` | TEXT | NULL on offchain path; set for historical rows |
| `delivered_at` | TIMESTAMPTZ | block timestamp at on-chain settlement |
| `source` | TEXT | enum: `mech_offchain`, `ipfs_historical` |
| `created_at` | TIMESTAMPTZ | row insert time |

Indexes: PK; `(delivery_mech, delivered_at DESC)`; `(executed_at DESC)`. Partitioned by `delivered_at` monthly.

`mech_migration_failures`: audit table for the ETL (`chain_id`, `request_id`, `cid`, `error`, `attempted_at`).

Computed prediction fields (`p_yes`, `p_no`, `market_id`, `platform`, `confidence`, `cost_usd`) are derived by the analytics ETL service, not stored as a wildcard view.

### What we preserve that the subgraph drops today

The marketplace subgraph extracts `prompt`, `tool`, `questionTitle` (requests) and `model`, `result`, `content` (deliveries). The new schema additionally preserves `schema_version`, `executed_at`, `cost_dict`, `is_offchain`, `tool_hash`, `execution_latency_ms`, `metadata.params`. The migration is a fidelity upgrade, not just a relocation.

### On blocking inserts (why writing to wildcard is fine)

At current and projected scale, blocking inserts on `/predict` and `/predict/free` are fine. A modern Postgres comfortably handles thousands of inserts/sec on a single table, each sub-millisecond when indexes are sized correctly. The current pool (min 2 / max 20) allows up to 20 concurrent inserts; even at peak we're at low single-digit predictions/sec from pearl-mini plus low tens/sec from mech writes. Pool saturation isn't realistic at our volume. For mech writes specifically we already write asynchronously from the mech's point of view — the mech doesn't block tool execution on the wildcard write because of the local replay buffer. The only sync write left is pearl-mini's own `/predict`, where a 1-2ms insert is dwarfed by the LLM call that follows. Revisit if observability shows pool saturation or p99 insert latency above ~50ms.

### Analytics ETL service (new)

Runs incremental ETL on the wildcard data lake. Reads `mech_requests` + `mech_responses` (and pearl-mini predictions where relevant). Computes:

- Metrics olas-website needs (tool accuracy, ROI, transactions, fees per chain)
- Scoring metrics mech-predict tracks (Brier, calibration, edge, directional accuracy, log loss, ECE, no-signal rate, BSS) per-row and per-aggregation

Writes computed metrics to its own dedicated metrics Postgres. Scheduled refresh, default every 15 minutes, configurable per metric.

### Metrics Postgres (new, small)

Dedicated instance holding only computed metrics, not raw rows. Schema mirrors the API surface — one table per metric family. Small, can be replicated freely.

### Wildcard API (new public service)

FastAPI service in front of the metrics Postgres. Public, Cloudflare-protected (no per-caller auth on the read side). One endpoint shape:

`GET /metrics/agent-economy/{agent_name}` → JSON with all metrics for that agent.

The public read endpoints also serve as the verifiability surface for metrics on olas-website. Today's "verify" links (which point at subgraph code / queries) become curl invocations of the corresponding Wildcard API endpoint. Keeps the verify pattern intact, points at the new public source.

**Why a separate service** (not direct Postgres reads from olas-website):

- Schema agility — re-shape the metrics store without breaking the website
- The analytics ETL service is the sole writer to the metrics Postgres; its schema is owned end-to-end
- Raw request/response content stays in wildcard — we only expose computed analytics fields
- Future consumers (Pearl mode-tracker, internal dashboards) hit the same public API
- Public read side fronted by Cloudflare; no per-caller auth to manage

### olas-website metric rewrites

- Rewrite `tool-accuracy.ts`, `omenstrat-roi.ts`, `polystrat-roi.ts` to call the Wildcard API and pick the relevant fields from the unified JSON response
- Drop `matchBetToMechRequest` entirely
- Keep existing output shapes so downstream consumers don't change
- Replace each existing "verify" link on the website with a curl invocation of the matching API endpoint

Files that don't change: `omenstrat-brier.ts`, `omenstrat-success-rate.ts`, `polystrat-success-rate.ts`, `index.ts` — all use Omen / Polymarket / registry subgraphs only.

### Historical IPFS ETL (ready to run; executes in Phase 2)

Goal: backfill every historical mech request and response into the wildcard data lake, for both new marketplace contracts (gnosis, base, polygon) AND legacy `agent_mech` contracts on Gnosis.

- Enumerate all historical request_ids + CIDs from BOTH source sets above
- Build a master enumeration table keyed by `(chain_id, request_id)`
- Fetch IPFS content for each `(request_cid, delivery_cid)` pair from `gateway.autonolas.tech` (plus fallback gateway)
- Rate-limit per gateway-friendly limits; N parallel workers; dedup by content hash
- Bulk insert via `COPY` with `source='ipfs_historical'`
- Log gateway failures, non-JSON content, schema drift to `mech_migration_failures`; don't block on these
- Trigger the analytics ETL to compute metrics for the backfilled prediction tools after the backfill completes
- Validation: row counts vs subgraph totals; spot-check 1000 random rows against subgraph `ParsedRequest`

Resource needs: one ETL workstream, IPFS gateway capacity (paid tier or self-hosted IPFS node), storage TBD pending enumeration. Legacy mech contracts on Gnosis have years of history with high request volume — bulk of historical mech traffic lives there. Rough order: multi-million rows, ~10-20 GB on disk after JSONB compression and partitioning. Timeline once enumerated: 4-6 weeks elapsed for fetch + insert + validation.

### Authentication and rate limits

Auth on `POST /mech/events` is signature-based, not bearer-token, and works one-batch-at-a-time so a settlement that produces N delivered events still costs one signature on the mech side and one `ecrecover` on the server side.

- The mech assembles all offchain deliveries from one settled FSM round into an `events` array, computes `batch_hash = keccak256(canonical_json(events))`, and signs an EIP-712 typed message containing `(mech_service_multisig, batch_hash)`. The domain separator binds chainId + the verifying contract address (the marketplace deployment for that chain).
- The POST body carries `{ typed_data, signature, events }`. Each `events[i]` is the full row payload for one delivery (the same shape that the existing `mech_requests` + `mech_responses` writer uses), and the signature covers the hash of the whole array.
- Server side (implementation moved from on-chain reads to a hardcoded operator registry as the architecture matured; the original on-chain design is preserved below for reference):
  - `ecrecover` the operator EOA from the signature
  - Validate `typed_data.domain.verifyingContract` is in the per-chain marketplace allowlist (sourced from `autonolas-marketplace/docs/configuration.json`)
  - Look up the declared mech in the hardcoded `mech_operators_by_chain` registry (`config.py`); a missing entry surfaces as 403 `MECH_NOT_REGISTERED`. The registry stores `(multisig, owners)` for every mech the deployment authorises and is updated by Git PR when a new mech onboards or a Safe owner rotates. Replaces the original on-chain `IMechMarketplace.checkMech(mech_address)` + `Safe.getOwners()` read pair (predict-api #162); the change shipped as predict-api #164. Rationale: every production mech is operated by Valory, so the on-chain registry is a strict superset of what the server needs to know, and the RPC dependency on the write path (with its 503 `CHAIN_RPC_UNAVAILABLE` failure mode) was load-bearing for nothing.
  - Confirm the recovered EOA is in the mech's owner set; surface as 401 `SIGNER_NOT_AUTHORIZED` otherwise
  - Recompute `batch_hash` from `events` and compare with the signed value; reject on mismatch
  - Insert all `mech_requests` and `mech_responses` rows in one transaction; idempotent via `ON CONFLICT (request_id) DO NOTHING` on each table
- Why the EOA + owner check pattern. The "mech" in the marketplace contract is the Safe itself (`MechMarketplace.checkMech(address mech) returns (address multisig)` at `contracts/MechMarketplace.sol:913`), not an EOA. `ecrecover` recovers the operator EOA that produced the signature. The owner check ties the EOA back to the registered Safe, so the auth chain reads as "this signature came from an EOA that the registered mech Safe authorises".
- Why no nonce. Replay of a verbatim POST hits `mech_requests.request_id` as the PK; `ON CONFLICT DO NOTHING` makes it a no-op and the server returns 200 `recorded: "duplicate"`. Because the signature covers `batch_hash`, an attacker cannot substitute the row payload either, so there is no class of replay that the DB idempotency does not already cover. The earlier "monotonic per-mech nonce" plan pre-dated binding the payload hash into the signature; it is no longer needed.
- No bearer tokens, no `mech_operator_keys` table, no `mech_event_nonces` table, no key issuance, no rotation. The mech's existing on-chain identity is the credential.
- Onboarding for a new mech is one config PR: append a row to `mech_operators_by_chain[chain_id]` with the mech's Safe address and the owner EOA set, ship the release. The original "automatic via on-chain reads" property was traded for simpler ops (no RPC dependency on the write path, no cache TTL choices) given the Valory-operated production reality.
- Revocation is one config PR: drop the mech's row (or rotate the owner set). Same cadence as onboarding.
- Rate limit: per-signer sliding window (default 200 writes/sec/EOA). Keyed on the recovered EOA.
- The read API (`GET /metrics/agent-economy/{agent_name}`) remains public behind Cloudflare.

### Why signature-based and not bearer-token

The mech already has cryptographic identity that the marketplace contract itself trusts for settlement. Inventing a parallel bearer-token system means issuing, distributing, storing hashed, rotating, and revoking secrets that the mech's owner EOAs already provide for free. Steady-state cost per batch is one `ecrecover` plus one dict lookup, regardless of how many delivered events the batch carries. Onboarding moved from a manual key-issuance flow to a Git PR appending a row to the operator registry.

### Operator preimage retention

- Persistent disk via the existing `valory/kv_store` connection (SQLite-backed, WAL mode). Auto-provisioned on Propel via PVCs (`propel/services/agent_manager/src/k8s/state_detector.py:13-18`)
- Default retention 24 hours, operator-configurable
- Background sweeper deletes entries past the retention window
- Buffer write must succeed before the mech acknowledges the client; buffer-write failure is a hard error
- Monitoring: disk usage, backup freshness, buffer-write failure rate

### Staking compatibility — RequesterActivityCheckerV2 (system-wide)

**The problem**: Today's `RequesterActivityChecker` enforces `diffRequestsCounts <= diffNonces` inside `isRatioPass`. Under offchain, mech request count advances at settlement but the Safe nonce doesn't advance per request. Constraint fails. Activity is not credited. Staked agents don't earn rewards.

**Solution**: deploy `RequesterActivityCheckerV2` that reads `mapRequestCounts` alone with no nonce parity check. The activity signal is `mapRequestCounts` alone; the ratio passes when `(diffRequestsCounts × 1e18) / ts >= livenessRatio`. Confirmed with the contract author this is safe for both on-chain and offchain — the constraint was belt-and-suspenders, not load-bearing. Every increment to `mapRequestCounts` goes through `_deliverMarketplaceWithSignatures`, which verifies the Safe signature, consumes a monotonic per-requester nonce that prevents replay, and charges real USDC at settlement. Cryptographically and economically gated regardless of path.

**Migration shape**: `activityChecker` is immutable on existing `StakingToken` deployments (verified at `StakingBase.sol:332` — set once in `_initialize`, no setter anywhere). Existing programs cannot be repointed. The migration is:

1. Deploy `RequesterActivityCheckerV2` on gnosis, base, polygon
2. Audit
3. Redeploy each affected staking program wired to V2 — every program currently using `RequesterActivityChecker`. From `olas-operate-app/frontend/config/activityCheckers.ts`:
   - **Gnosis**: PearlBeta6, PearlBetaMechMarketplace, PearlBetaMechMarketplace1-8
   - **Base**: AgentsFun1-3
   - **Polygon**: PolygonBeta1-3
4. Olas DAO governance proposal to add the new staking programs to the rewards distribution (`Voting` contract at `0x95418b46d5566D3d1ea62C12Aea91227E566c5c1`)
5. Governance vote passes
6. Update `olas-operate-app/frontend/config/activityCheckers.ts` and per-chain `stakingPrograms/*.ts` to expose new programs in Pearl
7. Run old and new programs in parallel for 4-8 weeks during user migration so currently-staked users aren't disrupted mid-epoch
8. Communicate to users: "the program you're staked in is being replaced, unstake from the old and restake into the new"
9. Second governance proposal to remove old programs from rewards
10. Old programs sunset

**Timeline estimate**: 12-16 weeks elapsed. Engineering is small. Audit (~4 weeks) + governance vote + comms + user migration window (4-8 weeks) are the long poles.

### townhall-kpis rewrite

- Replace `NewMechFeesQuery` and `LegacyMechFeesQuery` calls (`pages/api/metrics.ts:106-140`) with a single Wildcard API call returning `{gnosis_new, gnosis_legacy, base_new}` USD totals
- Replace the mech requests slice of `PredictTradesQuery` (`lib/predict-metrics/predict-trades.graphql:23-36`) with a call to `GET /metrics/agent-economy/{agent}` for the same time window
- Keep the FPMM trades source unchanged (still the Predict subgraph)
- Preserve the existing `questionTitle` substring join in `roi.ts:54-56` — same field name and shape, no math change
- Update env vars: drop `NEXT_PUBLIC_NEW_MECH_FEES_*` and `NEXT_PUBLIC_LEGACY_MECH_FEES_*`, add `NEXT_PUBLIC_WILDCARD_API_URL`

Where: `townhall-kpis/pages/api/metrics.ts:106-140`, `townhall-kpis/lib/predict-metrics/sources/roi.ts`, `townhall-kpis/lib/predict-metrics/predict-trades.graphql`, `townhall-kpis/.graphclientrc.yml`, `townhall-kpis/.env.example`.

Tests: snapshot test ROI by day output matches today's shape; mech fees aggregation matches the pre-migration value for a known date.

### mech-predict benchmark rewrite

Two paths now, depending on what the benchmark is doing.

**Normal scoring path**: reads precomputed metrics (Brier scores, calibration, edge, directional accuracy, etc.) from the Wildcard API. Metrics are computed in the analytics ETL and stored in the metrics Postgres. The daily report queries the Wildcard API for per-tool, per-platform, and per-category aggregations. No production data is fetched and no scoring is run locally.

**Recompute path**: reads raw rows directly from the wildcard data lake over SQL for prompt sweeps, tournament mode, or `--code-change` scoring. Replaces subgraph and IPFS reads with direct read-only SQL against `mech_requests JOIN mech_responses`. Accesses `source_content` via the `raw_content` JSONB column in `mech_responses`, eliminating separate IPFS fetches.

Steps:

- Replace `DELIVERS_QUERY` (subgraph) in `fetch_production.py:653-677` with a direct SQL query against `mech_requests JOIN mech_responses` filtered by tool / platform / time window
- Replace `DELIVERS_BY_IDS_QUERY` (`:679-691`) with a `WHERE request_id IN (...)` SQL query for batch lookups
- Replace `fetch_ipfs_metadata` and `fetch_ipfs_source_content` (`:940-994`) with reads from `mech_responses.raw_content.metadata.params.source_content`
- Drop the sample-and-binary-search strategy for source_content (`:1646-1709`) — every row is available locally
- Drop the `production_log_xxxx` CI artifact generation entirely; the data lake is now the source of truth
- Add a thin client that reads precomputed scores from the Wildcard API for the daily report path; recompute path stays SQL-only
- Per-platform cursor state in `.fetch_state.json` stays for the recompute path
- Default lookback window stays 7 days
- Keep IPFS as a fallback for any pre-migration rows during the Phase 2 dual-write window

### market-resolver rewrite

Today market-resolver uses the mech subgraph to remember its own past jury responses across cycles — it reads `parsedRequest.prompt` and the matching `tool_response` from the subgraph to check whether the safe has already evaluated a given market. Under the offchain path that doesn't work anymore: `parsedRequest.prompt` and the response body come from IPFS at subgraph indexing time, and IPFS uploads are gone for offchain rows. So the subgraph still shows the delivery happened but the content fields are empty.

Switch market-resolver to a local on-disk store (SQLite) for its own past responses. The on-chain settlement event keeps the late-delivery polling working as today; the local store covers the content fields the subgraph no longer has.

Steps:

- Add a local on-disk store (SQLite) inside market-resolver for `(market_id, request_id, tool_response, delivered_at)` keyed by `(safe_address, market_id)`
- When firing a mech jury request: write the request immediately, update with the response when it arrives
- Late-delivery handling: market-resolver's existing polling for `delivery_mech` against the on-chain settlement events still works — when a delivery shows up on-chain after a previous cycle gave up, the next cycle picks it up, reads the response, and writes it to the local store
- Cache lookup at the start of each cycle: "has my safe already evaluated this market?" answered from the local store, not from a remote query
- Persistence: store lives on the agent's PVC (Propel provisions it automatically)
- Remove the existing mech Gnosis subgraph cache query (`market_resolution_manager_abci/behaviours/base.py:64-88`) and the `mech_gnosis_subgraph` model from `skill.yaml`

Where: `market-resolver/.../market_resolution_manager_abci/behaviours/base.py`, `skill.yaml`, new local-store helper module.

### Marketplace subgraph (no change)

This is the only "module" that does NOT need code changes. The marketplace subgraph already handles `MarketplaceDeliveryWithSignatures` (`autonolas-subgraph/subgraphs/marketplace/src/marketplace/mech-marketplace.ts:270-298`) and increments `receivedRequests`, `selfDeliveredFromReceived`, and `totalDeliveriesTransactions` on offchain settlements. Trader's mech ranking (`mech-interact/.../graph_tooling/queries/mechs_info.py:24-57`) continues to work without any change.

What stops working is the subgraph's `ParsedRequest` entity, which is populated via `ipfs.cat()` at indexing time. `parsedRequest.prompt`, `parsedRequest.tool`, `parsedRequest.questionTitle` become empty for offchain rows. Consumers that read those fields (townhall-kpis, mech-predict, market-resolver) migrate to the data lake (covered by their own workstreams). Worth a one-line note in operator runbooks so people don't debug "empty ParsedRequest" as a bug — it's expected for offchain rows.

## Phase 1 contract changes

Zero. The existing `deliverMarketplaceWithSignatures` already accepts arbitrary bytes for `paymentData` and `deliveryData`, and the contract's nonce mutex (`mapNonces`) gives us the failover guarantee without contract work.

## Phase 1 trade-offs

- Operator residual LLM-cost waste on the rare overlapping-completion race (same hazard as today's on-chain step-in via `AlreadyRequested` revert)
- The on-chain + IPFS path stays available as opt-out. Consumers that need it for any reason (auditing, legacy integrations, third-party indexers) can run with `use_offchain=false` and behave exactly as today.
- One-in-flight-per-nonce constraint per requester (FSM consumers satisfy this naturally)
- Settlement-ordering liveness (slow-to-settle mech blocks subsequent settlements until it lands; we operate the mechs so cadence is in our control)
- No cross-path runtime fallback in Phase 1-2 (consumers don't mix paths within a request lifecycle)

---

# Phase 2 — Rollout

## TL;DR

Cut over to the offchain path without leaving an analytics gap. Backfill the wildcard data lake from historical IPFS first, dual-write for parity, switch olas-website to the new Wildcard API, then flip mechs to offchain HTTP per deployment, and flip the default to offchain last.

## Tasks at a glance

- [ ] Step 1: run historical IPFS backfill for gnosis, base, polygon (new marketplace) AND legacy `agent_mech` contracts on Gnosis. Validate row counts and sample rows.
- [ ] Step 2: turn on mech writes to the wildcard data lake in parallel with IPFS publication. Reconciler job compares.
- [ ] Step 3: cut olas-website over to the Wildcard API. Confirm dashboards match. Replace verify links with curl invocations.
- [ ] Step 4: flip mechs to offchain HTTP mode (`use_offchain=true`) per deployment, staged.
- [ ] Step 5: flip the default to offchain. The on-chain + IPFS path stays available via `use_offchain=false`; no code removed.

## Rollout sequence (no analytics gap by construction)

| Step | Detail |
|------|--------|
| **1 — Historical backfill** | Run the ETL across new marketplace subgraphs (gnosis, base, polygon) and legacy `agent_mech` subgraphs on Gnosis. Validate row counts ≥99% of subgraph totals. Sample 1000 random rows; assert tool, prompt, market_id match subgraph's `ParsedRequest`. |
| **2 — Dual-write parallel run** | Mechs publish to BOTH IPFS and the wildcard data lake. Reconciler job runs continuously. Cut-over criteria (open question for thresholds): 99.9% of IPFS deliveries in last 24h have matching wildcard row; matched rows agree on tool, prompt, model, result, p_yes (within float tolerance); median write latency under 5s. |
| **3 — Switch olas-website to the Wildcard API** | Deploy new metric files. Compare values against IPFS-based dashboard within tolerance. Replace the existing "verify" links with curl invocations of the matching Wildcard API endpoints. No user-visible change at this step beyond the verify-link target. |
| **4 — Flip mechs to offchain HTTP per deployment** | Stage by deployment via the `use_offchain` flag in `service.yaml`. For each: enable, monitor, leave on if clean. Rollback path: flip the flag back; existing IPFS pipeline still works. |
| **5 — Flip the default to offchain** | The on-chain + IPFS path remains available across all consumers via the `use_offchain=false` flag. Consumers that need the legacy behaviour (or want to mirror to IPFS for any reason) keep it. No code is removed. |

## Phase 2 contract changes

Zero. Pure operational work.

## Phase 2 trade-offs

- Dual-write window costs IPFS storage + wildcard data lake storage during the overlap period
- Cutover order is mandatory: backfill before website switch, website switch before mech flip, mech flip before flipping the default
- If anything regresses at any step, fall back to the previous step. No data is lost because the old IPFS pipeline keeps running and stays available as opt-out.

---

# Phase 3 — Optional scaling (deferred)

## TL;DR

Independent contract-level improvements. None ship by default. Each is evaluated on its own merits when a specific volume threshold is crossed. They share the property that they need contract changes and an audit.

## Tasks at a glance

- [ ] Define the volume thresholds at which each item moves to "build" status
- [ ] Identify the first concrete client that justifies starting
- [ ] If green-lit: bundle the items into a single audit cycle
- [ ] Build new BalanceTracker subclass for cumulative vouchers
- [ ] Add new marketplace function for batched, fail-soft settlement
- [ ] Add OlasMech forwarder
- [ ] Update mech-client and mech-interact for voucher signing
- [ ] Audit, then mainnet rollout

## Items

**Item A — One signature per batch.** Today's settlement verifies every request's signature on-chain. 50 requests in a batch from one client = 50 verifications. Item A replaces them with one cumulative voucher signed per session. Worth it at 50+ requests per session (~$2.50 gas today → ~$0.05).

**Item B — One transaction covers all clients in a window.** Today's settlement function takes one client per call. 50 active clients in a window = 50 transactions. Item B accepts an array of vouchers in one call. Tightly coupled to Item A — ship together. Worth it at 10-50+ clients per window.

**Item C — One bad request doesn't drop the others.** Today's settlement is atomic. One bad signature reverts everything. Item C wraps each per-client settlement in try/catch — failures emit an event, the loop continues. Only meaningful if Item B ships.

**Item D — Cross-path runtime fallback.** Add a runtime fallback from offchain to on-chain so that on "clean failure round" exhaustion the consumer can automatically retry the same request on-chain without losing it. Requires a contract-level mechanism to cancel or supersede a pending offchain signature so the cross-path nonce hazard doesn't void a still-in-flight settlement. Until this ships, consumers stay on a single path per deployment.

**Item E — 503 backpressure on overload.** Mech returns 503 immediately when at the operator's LLM provider concurrency limit, before starting any LLM call. Optional `Retry-After` header. Quality improvement (faster failover, less wasted LLM cost), not a correctness requirement. Ship if observed volume makes the wasted LLM cost worth fixing.

## Phase 3 effort and rollout

- ~500 lines of new Solidity if we ship the bundle A+B+C
- ~500 lines of off-chain support across mech and clients
- Audit cycle (~3-4 weeks elapsed for the audit firm)
- Critical path: contract write → internal review → audit → mainnet
- Total elapsed end to end: 6-10 weeks
- If we don't ship any of them, Phases 1 and 2 still deliver standalone value.

---

## Open items needing sign-off

### Before Phase 1 build starts

- Confirm no requester withdrawal is acceptable
- Confirm content stays out of public IPFS by default (commit-reveal pattern accepted; on-chain + IPFS path stays available as opt-out)
- Owner for the mech-interact offchain branch (the dominant build cost)
- Confirm the wildcard data lake approach (raw mech rows added to wildcard, not a separate raw-data DB)
- Metrics Postgres + Wildcard API infrastructure home and ownership — who deploys, who's on-call?
- Per-operator write rate limit on `POST /mech/events` — recommendation 200 writes/sec/op
- HTTP timeout default for client failover retry — recommendation 60s, configurable per-tool
- Confirm every existing deployed mech publishes the HTTP URL in its IPFS metadata manifest (we assume every mech is offchain-capable)

### Before Phase 2 rollout starts

- Cut-over criteria thresholds (match rate %, latency, window size) for the dual-write validation step
- Deployment rollout order across consumer services (trader first? market-creator first?)
- Rollback runbook documented and rehearsed

### Phase 3 trigger criteria

- Volume threshold at which Item A and Item B become worth it
- First concrete client that justifies starting
- Audit firm and lead time

---

## Privacy across the whole plan

Same mechanism in every phase. No phase introduces new crypto. The mech computes the same content CID IPFS would have produced, puts that CID on-chain as a commitment, but never publishes the content publicly. Anyone with the original content can re-hash and verify the on-chain commitment matches. The mech cannot lie post-hoc about what was asked or delivered. During normal operation the content stays off public surfaces.

Trade-off accepted: the mech becomes a single point of failure for liveness and for after-the-fact verification. Operators must retain content locally for at least the configured retention window (default 24h). The on-chain + IPFS path stays available as opt-out for any consumer that needs a public fallback. The wildcard data lake is the authoritative analytics record, with computed metrics served by the public Wildcard API. Subgraphs index counts and CIDs but not content.

## Step-in vs failover across the plan

Step-in is an on-chain-only mechanism. It keeps working as today for any consumer that uses the on-chain + IPFS path, via the autonomous mech polling logic in `task_execution/behaviours.py:545`.

The offchain HTTP path has no step-in and no equivalent on-chain coordination. We ship a client-side failover instead: on HTTP timeout, mech-interact signs a fresh request for the next priority mech at the same on-chain nonce. The contract's monotonic nonce (`MechMarketplace.sol:222-263`) ensures only one mech can consume nonce N, so the requester isn't double-charged. Operator residual LLM-cost on the rare race is the cost of decentralized failover without a coordinator.
