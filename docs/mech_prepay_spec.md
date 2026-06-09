# Mech Prepay — Phased Plan

## What this is

A three-phase plan to move mech requests off the public chain rails while keeping them billable and auditable. Each phase delivers value standalone.

## Phases at a glance

| Phase | What ships | Contract changes | API changes | Effort |
|-------|------------|------------------|-------------|--------|
| **Phase 1** — HTTP requests, privacy via no-IPFS | Mech accepts requests over HTTPS. Content stays off public IPFS. | None | Additive only — structured 402 body, two new response headers, no body shape changes on 200, no new routes | ~2020-3420 lines |
| **Phase 2** — Centralized analytics in our existing Postgres | Mechs write predictions to the same Postgres pearl-mini already uses. Website metrics read from there. | None | Yes — new `POST /predictions` on the wildcard server | ~900 lines |
| **Phase 3** — Optional scaling (deferred) | Cumulative voucher, multi-requester batching, fail-soft batching. Build only when volume justifies. | Yes (audit-needed) | Yes — new marketplace function | Per-item, evaluated separately |

## Why this shape

We want privacy, low cost, and good analytics. Phase 1 buys privacy by stopping public IPFS publication. Phase 2 saves the metrics by moving them off the (now-empty) IPFS pipeline and into our existing Postgres. Phase 3 is reserved for scaling improvements that only matter at high volume.

## What we are explicitly NOT doing

- No requester withdrawal entry. Money committed to the marketplace stays committed.
- No new escrow contract.
- No new cryptography. Privacy is achieved by not publishing, not by encryption.
- No MPP protocol compatibility.

---

# Phase 1 — HTTP requests with privacy

## TL;DR

The mech already has an HTTP server. We change its behavior to stop pushing request/response content to public IPFS while keeping the same on-chain settlement. Plus two small additive HTTP improvements: the 402 response gets a structured body explaining what to deposit (today it's empty) and the 200 response gets a Payment-Receipt header for audit trails. Existing clients keep working without changes.

## Tasks at a glance

**Privacy (commit-reveal):**
- [ ] Add an `is_offchain` flag to the mech task struct
- [ ] Mech: skip IPFS upload of request metadata when flag is set
- [ ] Mech: skip IPFS upload of response when flag is set
- [ ] Mech: compute content hash locally instead of uploading
- [ ] Mech: persist (request, response) preimages to local disk for the audit window
- [ ] Mech-client: drop the IPFS upload step in the existing offchain path
- [ ] Mech-client: compute the content hash locally before posting

**Mech-interact offchain branch:**
- [ ] Mech-interact: build a new offchain request behaviour (HTTP POST)
- [ ] Mech-interact: build a new offchain response behaviour (polling)
- [ ] Trader and other agents: add one config flag in `service.yaml`

**Improved 402 challenge + receipt headers:**
- [ ] Mech: emit `WWW-Authenticate: Payment` header on 402 responses
- [ ] Mech: replace empty 402 body with structured JSON (scheme, payTo, currentBalance, required, depositInstructions)
- [ ] Mech: emit `Payment-Receipt` header on 200 responses
- [ ] Mech-client: parse the structured 402 body, surface helpful error
- [ ] Mech-client: optional auto-deposit and retry flag (executes depositInstructions on-chain)
- [ ] Mech-client: log the `Payment-Receipt` header for audit
- [ ] Mech-interact: parse the structured 402 body
- [ ] Mech-interact: build a multisend (approve + depositFor) using the existing Safe path, retry the request after deposit
- [ ] Mech-interact: log the `Payment-Receipt` header for audit

**Operations:**
- [ ] Document the retention SLA (recommended 90 days)

## API surface in Phase 1

**No new HTTP routes. Body shapes on 200 are unchanged. Two additive changes to the existing routes:**

| Change | Where | Backwards compatible? |
|--------|-------|------------------------|
| 402 response body goes from empty → structured JSON | `POST /send_signed_requests` 402 path | Yes — old clients that ignored the body still ignore it |
| New `WWW-Authenticate: Payment` header on 402 | `POST /send_signed_requests` 402 path | Yes — old clients don't read unknown headers |
| New `Payment-Receipt` header on 200 | `POST /send_signed_requests` 200 path | Yes — informational, can be ignored |

The two existing routes stay at the same paths with the same request bodies:

| Route | Used today | Used in Phase 1 |
|-------|-----------|------------------|
| `POST /send_signed_requests` | Yes | Yes, same request body; 402/200 responses get the new headers |
| `GET /fetch_offchain_info` | Yes | Yes, same response shape |

Anything that worked against today's HTTP API keeps working in Phase 1. New clients can use the structured 402 body for auto-deposit retries.

## Flow

```
   Client (Trader / agent / mech-client)
       │
       │  1. Build request locally
       │     (compute the IPFS hash on the fly, don't upload)
       ▼
   POST /send_signed_requests  ─────────────────▶  Mech HTTP server
                                                       │
                                                       │  2. Check sender has balance
                                                       │     on-chain (existing logic)
                                                       │
              ┌─── if insufficient ─────────────┐
              │                                 │
              │       ◀ HTTP 402 Payment Required
              │       ◀   WWW-Authenticate: Payment scheme="olas-prepay"
              │       ◀ Body: { scheme, payTo, currentBalance,
              │       ◀         required, depositInstructions }
              │                                 │
              │  Client parses the body,        │
              │  optionally auto-deposits       │
              │  on-chain, then retries         │
              │  from step 1                    │
              │                                 │
              └─── else (sufficient) ──────────┘
                                                       │
                                                       │  3. Queue the task,
                                                       │     skip the IPFS upload
                                                       │
                                                       │  4. Run the tool,
                                                       │     keep result in memory
                                                       │
                                                       │  5. Persist (request, response)
                                                       │     preimages to local disk
                                                       ▼
                                              ◀ HTTP 200 OK
                                              ◀   Payment-Receipt: <base64 receipt>
                                              ◀ Body: { request_id }
                                                       │
   GET /fetch_offchain_info  ◀─────────────────  result available
                                                       │
                                                       │  6. Batch-settle on-chain
                                                       │     (same path as today,
                                                       │      with the locally
                                                       │      computed hash, no upload)
                                                       ▼
                                              MechMarketplace.deliverMarketplaceWithSignatures
                                                       │
                                                       │  on-chain event still fires
                                                       │  with content hash, but
                                                       │  the content itself is
                                                       │  not on IPFS
                                                       ▼

If someone disputes later:
   Mech reads preimages from local disk
   Pins them to IPFS
   The hash still matches the on-chain commitment
   Anyone can verify
```

## Why this gives us privacy without new crypto

A content hash is a one-way function. If we put the hash on-chain but never publish the content anywhere, scrapers see only the hash. They can't get the content. But the hash is still bound to specific content. If the mech later tries to lie about what was asked or delivered, anyone with the original content can re-hash it and prove the lie. The mech is honesty-locked even though the content is private.

## Detailed implementation

### Mech-side changes (server)

**Steps**

Privacy (commit-reveal):
- [ ] Add `is_offchain` boolean to the task struct queued by `_enqueue_offchain_request`
- [ ] In `_execute_ipfs_tasks`: branch on the flag; skip the IPFS metadata upload, store the JSON in a new `in_memory_requests` dict keyed by request_id
- [ ] In the response build path: skip the IPFS upload, keep the response in `offchain_request_responses` (already exists for the GET endpoint)
- [ ] In `_get_offchain_tasks_deliver_data`: compute the locally-derived IPFS hash and pass it through as `delivery_data` (decision pending — recommendation is the hash for verifiability)
- [ ] Add a local persistence layer (e.g. SQLite or LevelDB) for (request_id, request_bytes, response_bytes, accepted_at) tuples
- [ ] Background job: prune entries older than the retention window

Improved 402 challenge:
- [ ] Build a `build_402_challenge` helper that produces the structured body: `{scheme, payTo, asset, chainId, currentBalance, required, depositInstructions, error}`
- [ ] In the insufficient-balance branch of `_handle_signed_requests`: emit `WWW-Authenticate: Payment scheme="olas-prepay" realm="<mech_address>"` header and the structured body
- [ ] `depositInstructions` should reference the BalanceTracker address and `depositFor(address, amount)` ABI

Payment-Receipt header:
- [ ] On 200 from `_handle_signed_requests`: emit `Payment-Receipt: <base64 JSON>` with `{request_id, accepted_at, accepted_amount, settlement_status: "pending"}`

Tests:
- [ ] Assert no IPFS calls happen on the offchain path
- [ ] Assert local store gets populated
- [ ] Assert the on-chain settlement still goes through
- [ ] Assert 402 body matches schema and the WWW-Authenticate header is present
- [ ] Assert Payment-Receipt header is present on 200 with valid base64-encoded JSON
- [ ] Assert existing clients (no header awareness) still parse the 200 body correctly

**Where**

- `mech/packages/valory/skills/task_execution/handlers.py`
- `mech/packages/valory/skills/task_execution/behaviours.py`
- `mech/packages/valory/skills/task_submission_abci/behaviours.py`

**Effort**

~100 source + ~250 test lines.

### Mech-client changes

**Steps**

Privacy (commit-reveal):
- [ ] In `_send_offchain_request`: skip the call to `fetch_ipfs_hash`
- [ ] Build the request metadata JSON locally (`prompt`, `tool`, `nonce`, extras)
- [ ] Compute the content hash locally using the same hashing library IPFS uses (so the format matches a real IPFS CID)
- [ ] Send the JSON inline in the existing `ipfs_data` body field

Structured 402 handling:
- [ ] On HTTP 402: check for `WWW-Authenticate: Payment` header
- [ ] Parse the structured body, expose fields as `InsufficientBalanceError(current_balance, required, deposit_instructions)`
- [ ] Add `auto_deposit=True/False` parameter on the offchain entry point
- [ ] When `auto_deposit` is enabled: execute the deposit on-chain (via the existing wallet hookup), wait for confirmation, then retry the request (with a retry-count guard, default 1 retry)

Payment-Receipt logging:
- [ ] On HTTP 200: read `Payment-Receipt` header if present
- [ ] Log it (info level) for debug / audit visibility
- [ ] Optionally surface in the return value

Tests:
- [ ] Assert no IPFS upload happens
- [ ] Assert the hash in the body still parses as a CID
- [ ] Mock a 402 with structured body, assert `InsufficientBalanceError` carries the expected fields
- [ ] Mock a 402 then a 200, with `auto_deposit=True`, assert the deposit call happens and retry succeeds
- [ ] Mock a 200 with `Payment-Receipt`, assert it gets logged

**Where**

- `mech-client/mech_client/services/marketplace_service.py`

**Effort**

~90 source + ~150 test lines.

### Mech-interact changes (the dominant cost)

`mech-interact` today only knows the on-chain flow. We add a parallel HTTP branch.

**Steps**

Core offchain branch:
- [ ] Add `OffchainMechRequestBehaviour`: build the POST body with `request_id`, `sender`, `signature`, `ipfs_hash` (locally computed), `ipfs_data` (inline JSON), `delivery_rate`
- [ ] Use the safe key to sign the `request_id`
- [ ] Send the POST to the mech's HTTP endpoint using the existing AEA HTTP connection
- [ ] Add `OffchainMechResponseBehaviour`: poll `GET /fetch_offchain_info` until the result is ready or the timeout expires
- [ ] On timeout: fall back to the next priority mech (privacy note: same content goes to a second mech)
- [ ] Wire up the new behaviours into the round/state machine
- [ ] Skill.yaml param: `mech_http_url` (auto-discoverable from on-chain metadata or explicit)

Structured 402 handling + auto-deposit:
- [ ] On HTTP 402: check for `WWW-Authenticate: Payment` header and parse the structured body
- [ ] Build a multisend transaction via the existing Safe path: `USDC.approve(BalanceTracker, amount)` + `BalanceTracker.depositFor(safe, amount)`
- [ ] Submit through the existing transaction settlement skill
- [ ] Once deposit is confirmed on-chain, loop back and re-send the offchain request
- [ ] Add a retry-count guard (default 1) to prevent infinite loops
- [ ] If the Safe has insufficient free balance to fund the deposit: abort with a clear error

Payment-Receipt logging:
- [ ] On HTTP 200: read `Payment-Receipt` header
- [ ] Log it through the standard agent logger
- [ ] Optionally write it to synchronized_data for ensemble visibility

Tests:
- [ ] Mirror the existing `test_request_behaviour.py` and `test_response_behaviour.py` patterns
- [ ] Mock a 402 with structured body, assert the multisend gets built with correct parameters
- [ ] End-to-end: 402 → deposit → retry → 200, assert all steps fire
- [ ] Assert retry guard blocks more than the configured retries

**Where**

- New: `mech-interact/packages/valory/skills/mech_interact_abci/behaviours/offchain_request.py`
- New: `mech-interact/packages/valory/skills/mech_interact_abci/behaviours/offchain_response.py`
- Minor edits to: `base.py`, `round_behaviour.py`, `states/base.py`, `payloads.py`, `models.py`

**Effort**

~900-1450 source + ~550-1450 test lines.

### Agent / library config changes

**Steps**

- [ ] In each consuming service's `service.yaml`, add `use_offchain: ${USE_OFFCHAIN:bool:true}`
- [ ] Confirm there's a feature flag fallback so we can roll back per-deployment if needed
- [ ] No code changes outside the flag

**Where**

- `trader/.../service.yaml`
- `market-creator/.../service.yaml`
- `meme-ooorr/.../service.yaml`
- `iekit/.../service.yaml`
- Any other repos that consume mech-interact

**Effort**

~5 lines per service.

### Mech operator retention SLA

**Steps**

- [ ] Pick the retention window (recommendation: 90 days)
- [ ] Specify durability target (backup frequency, replication policy)
- [ ] Document in the operator runbook
- [ ] Add a monitoring alarm for "preimage store at risk of losing data within window"

**Effort**

Operations work, no code estimate.

### Phase 1 contract changes

Zero. The existing `deliverMarketplaceWithSignatures` already accepts arbitrary bytes for `paymentData` and `deliveryData`. We just use it.

### Phase 1 trade-offs

- If the mech goes down or loses its local data, the response is gone forever
- Quality scoring can't read responses from IPFS anymore (handled in Phase 2)
- Single point of failure for liveness, deliberate

### Phase 1 effort total

Around 2020-3420 lines across mech, mech-client, mech-interact, and agent config. Dominated by the new mech-interact behaviour. Roughly +520 lines on top of the privacy-only baseline for the structured 402 + Payment-Receipt header additions.

Breakdown:

| Layer | Privacy core | + 402/Receipt additions | Total |
|-------|--------------|--------------------------|-------|
| Mech (server) | ~200 | ~150 | ~350 |
| Mech-client | ~80 | ~160 | ~240 |
| Mech-interact | ~1200-2600 | ~250 | ~1450-2850 |
| Trader / agent config | ~5 | 0 | ~5 |
| **Total** | **~1485-2885** | **~560** | **~2045-3445** |

---

# Phase 2 — Centralized analytics in our existing Postgres

## TL;DR

Pearl-mini already writes prediction records to a Postgres database. We extend that database with three small columns for mechs, have mechs write to it via a new HTTP endpoint, and rewrite three website files to read from it instead of the marketplace subgraph. No resolution backfill — Omen and Polymarket subgraphs already carry resolution data and we keep using them.

## Tasks at a glance

- [ ] Add `mech_offchain` to the `source` CHECK constraint on the `predictions` table
- [ ] Add `mech_address TEXT NULL` column (with partial index)
- [ ] Add `chain_id INTEGER NULL` column
- [ ] Build a new `POST /predictions` endpoint on the wildcard FastAPI server
- [ ] Add per-operator API key auth on that endpoint
- [ ] Add per-operator rate limit (recommended 100 writes/sec/op)
- [ ] Add the mech-side write client (called on accept, on complete, on fail)
- [ ] Rewrite `tool-accuracy.ts` to read predictions from Postgres
- [ ] Rewrite `omenstrat-roi.ts` to join by `market_id` instead of fuzzy question matching
- [ ] Rewrite `polystrat-roi.ts` same way
- [ ] Run the one-time historical backfill from the marketplace subgraph (recommended, not required)
- [ ] Document the `prompt_used` storage policy (auth-gated, not public)

## What's new in the API surface for Phase 2

One new endpoint on the wildcard server:

| Endpoint | Purpose | Auth |
|----------|---------|------|
| `POST /predictions` (new) | Mech writes a prediction row | Per-operator API key |

Existing endpoints on the wildcard server are unchanged. The mech's own HTTP routes from Phase 1 stay unchanged.

## Flow

```
                                      ┌─────────────────────────┐
                                      │  Wildcard Postgres      │
                                      │  (the one pearl-mini    │
                                      │   already uses)         │
                                      │                         │
                                      │  predictions table      │
                                      │  + new columns:         │
                                      │     mech_address        │
                                      │     chain_id            │
                                      │  + new source value:    │
                                      │     mech_offchain       │
                                      └─────────────────────────┘
                                            ▲              ▲
                                            │              │
                              ┌─────────────┘              └──────────────┐
                              │ writes                                    │ reads
                              │                                           │
                  ┌───────────┴─────────┐                       ┌─────────┴──────────┐
                  │ POST /predictions   │                       │ olas-website cron  │
                  │ on the wildcard     │                       │                    │
                  │ FastAPI server      │                       │ reads predictions  │
                  │ (NEW endpoint)      │                       │ from Postgres      │
                  └───────────▲─────────┘                       │                    │
                              │                                 │ reads bets +       │
                              │ HTTPS                           │ resolutions from   │
                              │ (rate-limited per mech)         │ Omen + Polymarket  │
                              │                                 │ subgraphs as today │
                  ┌───────────┴─────────┐                       │                    │
                  │ Mech                │                       │ joins by           │
                  │                     │                       │ (market_id, bettor)│
                  │ writes prediction   │                       │                    │
                  │ row on each request │                       │ exposes metrics    │
                  └─────────────────────┘                       └────────────────────┘

The Omen and Polymarket subgraphs are unchanged.
They already carry every resolution we need.
```

## Why no resolution backfill

The Omen subgraph returns `currentAnswer` on every bet. The Polymarket subgraph returns `winningIndex` on every question. The website's tool-accuracy code already reads these directly from the bet objects. The wildcard `resolutions` table exists for a different workflow (training data ETL) and doesn't need to be populated for our analytics.

## Detailed implementation

### Postgres schema additions

**Steps**

- [ ] Write a new alembic migration that drops and re-adds the source CHECK constraint with `mech_offchain` allowed
- [ ] In the same migration, add `mech_address TEXT NULL`
- [ ] Create a partial index `predictions_mech_address_idx ON predictions (mech_address) WHERE mech_address IS NOT NULL`
- [ ] Add `chain_id INTEGER NULL`
- [ ] Run the migration in staging, then production

**Where**

- `wildcard/server/alembic/versions/00X_mech_offchain_columns.py`

**Effort**

~20 lines of migration code.

### Wildcard server: POST /predictions endpoint

**Steps**

- [ ] Define a Pydantic schema matching the predictions table shape (request_id, status, tool_name, market_id, p_yes, p_no, ...) with `mech_address` and `chain_id` required, `source` enforced to `mech_offchain`
- [ ] Implement the endpoint as upsert by `request_id` (so the on-accept call and on-complete call can both target the same row)
- [ ] Add validation: `mech_address` must match the authenticated operator's API key
- [ ] Return 200 on success, 400 on validation error, 401 on auth failure, 429 on rate limit, 500 on DB error
- [ ] Add structured logging
- [ ] Tests: roundtrip insert, upsert, validation rejection, auth rejection, rate-limit rejection

**Where**

- `wildcard/server/src/routes/predictions.py` (new)
- `wildcard/server/src/store.py` (extend for upsert by request_id)

**Effort**

~150 source + ~200 test lines.

### Mech-side write client

**Steps**

- [ ] Add an HTTP client that calls `POST /predictions` with retry + backoff
- [ ] On task acceptance: write row with `status='processing'`, tool_name, market_id, prompt_used, agent_safe, platform, chain_id, mech_address
- [ ] On task completion: upsert with `status='complete'`, p_yes, p_no, confidence, predicted_at, latency_s
- [ ] On task failure: upsert with `status='failed'`, error
- [ ] On write failure: queue the payload to a local replay buffer and retry on a schedule (mech does NOT refuse the request)
- [ ] Tests: assert one write on accept, one write on complete; assert replay buffer drains; assert request still succeeds when Postgres is down

**Where**

- `mech/packages/valory/skills/task_execution/behaviours.py` (hook into accept / complete / fail paths)
- New helper module for the write client

**Effort**

~150 source + ~200 test lines.

### Authentication and rate limits

**Steps**

- [ ] Add API key issuance UX (a manual ops command initially; can automate later)
- [ ] Store API keys hashed in a new `mech_operator_keys` table (operator address, hashed key, created_at)
- [ ] Add FastAPI auth middleware on `POST /predictions`
- [ ] Add per-key sliding-window rate limit (recommended 100 writes/second/operator)
- [ ] Tests: invalid key rejected, key for wrong mech_address rejected, burst over limit returns 429

**Where**

- `wildcard/server/src/auth/mech_keys.py` (new)
- Migration: `mech_operator_keys` table

**Effort**

~50 source + ~80 test lines.

### Website metric rewrites

**Steps**

- [ ] Add a Postgres client to `olas-website` (likely already available since pearl-mini uses Postgres)
- [ ] Rewrite `tool-accuracy.ts` to query Postgres for predictions and drop `matchBetToMechRequest` entirely
- [ ] Rewrite `omenstrat-roi.ts` to join by exact `market_id` against Postgres
- [ ] Rewrite `polystrat-roi.ts` same way
- [ ] Update snapshot output shape if needed (keep the same `ToolAccuracyStat` interface so consumers don't change)
- [ ] Tests: assert snapshot output matches today's shape, assert mech_offchain rows feed into the right Omen / Polymarket buckets via `platform` column

**Where**

- `olas-website/common-util/api/predict/tool-accuracy.ts`
- `olas-website/common-util/api/predict/omenstrat-roi.ts`
- `olas-website/common-util/api/predict/polystrat-roi.ts`

**Effort**

~80 + ~30 + ~30 = ~140 source + ~200 test lines.

### Files that don't change

- `omenstrat-brier.ts` — uses the Omen daily Brier subgraph, no marketplace dependency
- `omenstrat-success-rate.ts` — uses Omen bets only
- `polystrat-success-rate.ts` — uses Polymarket bets only
- `index.ts` — uses registry / staking subgraphs only

### The `prompt_used` column policy

We store the full prompt. The Postgres is internal infrastructure, not public. Anyone querying it is authenticated. This matches how wildcard already handles pearl-mini's prompts. The on-chain commit-reveal property still holds for the public surface.

If anyone wants stricter privacy later, switch this column to a hash. Not blocking for Phase 2.

### Historical backfill (recommendation, not requirement)

**Steps**

- [ ] Write a one-time ETL that reads all historical Request and Delivery events from the marketplace subgraph
- [ ] For each, read `parsedRequest.tool` and `parsedRequest.questionTitle`
- [ ] Map subgraph sender → `agent_safe`, mech address → `mech_address`, chain → `chain_id`
- [ ] Bulk-insert into Postgres with `source = 'parquet_historical'`
- [ ] Verify row counts and a few sample rows
- [ ] Remove the ETL script after the migration

**Where**

- New: `wildcard/server/scripts/backfill_mech_historical.py`

**Effort**

~300 source lines, ~one engineer week.

If we skip this, the tool accuracy and ROI metrics will be sparse for the first few days after migration until enough `mech_offchain` rows accumulate. Recommendation: do the backfill to preserve continuity.

### Phase 2 contract changes

Zero. All work is in Postgres, the wildcard server, the mech, and the website.

### Phase 2 effort total

| Component | Lines |
|-----------|-------|
| Postgres migration | ~20 |
| Wildcard server POST /predictions endpoint | ~150 |
| Mech write client | ~150 |
| Auth + per-operator rate limits | ~50 |
| `tool-accuracy.ts` rewrite | ~80 |
| `omenstrat-roi.ts` rewrite | ~30 |
| `polystrat-roi.ts` rewrite | ~30 |
| Tests | ~400 |
| **Total Phase 2** | **~910** |
| Historical backfill (recommendation) | +~300 |

---

# Phase 3 — Optional scaling improvements

## TL;DR

Three independent contract-level improvements. None of them ship by default. Each is evaluated on its own merits when a specific volume threshold is crossed. They share the property that they need contract changes and an audit.

## Tasks at a glance

- [ ] Define the volume thresholds at which each item moves to "build" status
- [ ] Identify the first concrete client that justifies starting
- [ ] If green-lit: bundle all three items into a single audit cycle
- [ ] Build new BalanceTracker subclass for cumulative vouchers
- [ ] Add new marketplace function for batched, fail-soft settlement
- [ ] Add OlasMech forwarder
- [ ] Update mech-client and mech-interact for voucher signing
- [ ] Audit, then mainnet rollout

## What we aim to implement (deferred)

Each item below moves to "build" status only when triggered. They're decoupled from Phases 1 and 2 and don't block the migration.

- **Item A** — One signature per batch instead of one per request
- **Item B** — One transaction covers all clients in a batch window
- **Item C** — One bad request in a batch doesn't drop the others

## Flow (after all three ship)

```
   100 clients each make some requests over 5 minutes
                          │
                          │  off-chain (no on-chain activity per request)
                          ▼
       Mech keeps the latest signed authorization per client
                          │
                          │
                          ▼
   One on-chain transaction settles all of them at once:
       For each client in the batch (using try/catch):
         - verify the signature once for that client
         - debit the client's balance by the total they owe
         - credit the mech
         - if any single client's settlement fails, the others still go through

   On-chain footprint:
       Today (after Phase 1+2):    ~50 transactions per batch window
       After Phase 3 items A+B+C:   1 transaction per batch window
```

## Detailed implementation (per item)

### Item A — One signature per batch

**Tasks**

- [ ] Define a new EIP-712 voucher type for cumulative authorization
- [ ] Build a new BalanceTracker subclass that verifies one signature per requester at settlement
- [ ] Add a marketplace function that accepts the voucher
- [ ] Update mech-client and mech-interact to sign cumulative vouchers instead of per-request signatures
- [ ] Tests + audit

**The problem.** The current settlement path verifies every request's signature individually inside the smart contract. For 50 requests in a batch from one client, that's 50 signature verifications on-chain. Each one costs gas.

**The fix.** Instead of one signature per request, the client signs a single authorization per session that says "I authorize the mech to charge me up to X total." Each new request just bumps X. The mech keeps the latest authorization. On settlement, the contract verifies one signature regardless of how many requests it represents.

**When it's worth doing.**

| Client behavior | Today's cost | After Item A | Worth it? |
|-----------------|--------------|--------------|-----------|
| Sends 1-3 requests per session | Tiny | Tiny | No, not worth the contract work |
| Sends 10 requests per session | ~$0.30 in gas | ~$0.05 | Marginal |
| Sends 50+ requests per session | ~$2.50 in gas | ~$0.05 | Yes, real savings |

Recommendation: defer until we have a concrete client (Optimus, an internal product, a partner) that hits the high-traffic range.

**Effort.** ~300 lines BalanceTracker subclass + ~100 lines marketplace + ~200 lines client SDK + audit.

### Item B — One transaction covers all clients in a batch window

**Tasks**

- [ ] Extend the marketplace function from Item A to accept an array of vouchers, one per client
- [ ] Update the mech-side batch builder to assemble per-client vouchers into a single array
- [ ] Tests + audit

**The problem.** The current settlement function takes one client per call. So if 50 different clients each made requests in the same 5-minute window, the mech submits 50 separate transactions. Each pays the same fixed overhead.

**The fix.** A new settlement function that takes an array of clients and settles all of them in one transaction. Overhead is paid once, not 50 times.

**When it's worth doing.**

| Mech behavior | Today's cost | After Item B | Worth it? |
|---------------|--------------|--------------|-----------|
| Serves <5 distinct clients per window | Small | Small | Marginal |
| Serves 10-50 clients per window | 10-50x marketplace overhead | 1x marketplace overhead | Yes |
| Serves 100+ clients per window | Very expensive | 1x overhead | Yes, large savings |

Recommendation: ship together with Item A. They're closely coupled — the combined effect makes the whole batch one cheap transaction.

**Effort.** ~100-150 lines of marketplace code plus matching mech-side batch builder.

### Item C — One bad request doesn't drop the others

**Tasks**

- [ ] Wrap each per-client settlement inside a try/catch in the new marketplace function
- [ ] Emit a `VoucherSettlementFailed` event on the failure path
- [ ] Tests for fail-soft behavior (one bad voucher in a batch of 50, expect 49 successes)
- [ ] Audit pass on the try/catch surface

**The problem.** Today's settlement function is atomic. If one of the 50 requests in a batch has a bad signature or some other failure, the whole transaction reverts. All 50 deliveries fail to settle. The mech has to identify the bad one off-chain, drop it, and resubmit.

**The fix.** Wrap each request's settlement inside a try/catch on-chain. Failures emit an event and the loop continues. The other 49 still settle.

**When it's worth doing.**

- If we don't ship Item B (multi-client batching), atomic revert only ever affects one client's batch. Not a real problem.
- If we ship Item B, one bad client can break the whole multi-client batch. The DOS risk gets real.

Recommendation: bundle with Item B. They go together. Cheap to add once we're already touching that code (~50 lines).

### Phase 3 effort and rollout

If we end up shipping the bundle A+B+C:
- ~500 lines of new Solidity
- ~500 lines of off-chain support across mech and clients
- An audit cycle (~3-4 weeks elapsed for the audit firm)
- Critical path: contract write → internal review → audit → mainnet
- Total elapsed end to end: roughly 6-10 weeks

If we don't ship any of them, Phase 1 and Phase 2 still deliver standalone value. Phase 3 is purely a scaling optimization for the future.

---

## Open items needing sign-off

### Before Phase 1 ships
- Confirm no requester withdrawal is acceptable
- Confirm content stays out of public IPFS (commit-reveal pattern accepted)
- Owner for the mech-interact offchain branch (the dominant cost in Phase 1)
- Retention SLA window: 30, 60, 90 days? Recommendation: 90.

### Before Phase 2 ships
- Confirm the wildcard Postgres can host mech writes (capacity + maintenance budget)
- Per-mech API key provisioning workflow (manual via ops? automated via on-chain registration?)
- Initial per-mech rate limit (recommended: 100 writes/sec)
- Decision on the optional historical backfill (recommended: yes, do it once at migration)

### Phase 3 trigger criteria
- Define the volume threshold at which Item A and Item B become worth it
- Identify the first concrete client that justifies starting
- Audit firm and lead time

---

## Privacy across the whole plan

Same mechanism in every phase. No phase introduces new crypto.

The mech computes the same content hash IPFS would have produced, puts that hash on-chain as a commitment, but never publishes the content. Anyone with the original content can re-hash and verify the on-chain commitment matches. The mech cannot lie post-hoc about what was asked or delivered. During normal operation the content stays off public surfaces.

Trade-off accepted: the mech becomes a single point of failure for liveness and for after-the-fact verification. Operators must retain content locally for the audit window. Public IPFS is no longer a fallback.

Phase 2 layers analytics on top: the wildcard Postgres becomes the authoritative analytics record. It's auth-gated, not public. Subgraphs index counts and CIDs but not content.

---

## Files and code touched, by phase

### Phase 1

| Repo | File | Change |
|------|------|--------|
| mech | `task_execution/handlers.py` | Skip IPFS upload when offchain flag is set, retain content locally |
| mech | `task_execution/behaviours.py` | Branch in `_execute_ipfs_tasks` |
| mech | `task_submission_abci/behaviours.py` | Locally-computed CID instead of IPFS-uploaded one |
| mech-client | `services/marketplace_service.py` | Drop the IPFS upload from the offchain path |
| mech-interact | new `behaviours/offchain_request.py` | New HTTP request behaviour |
| mech-interact | new `behaviours/offchain_response.py` | New HTTP polling behaviour |
| trader, market-creator, etc. | `service.yaml` | One config flag |

### Phase 2

| Repo | File | Change |
|------|------|--------|
| wildcard | new alembic migration | Add `mech_offchain` source, `mech_address`, `chain_id` columns |
| wildcard | new FastAPI route `POST /predictions` | Accepts mech writes, validates auth, rate-limits |
| wildcard | new `auth/mech_keys.py` | Per-operator API key issuance and validation |
| mech | task_execution behaviour | Write to wildcard Postgres on request lifecycle events |
| olas-website | `common-util/api/predict/tool-accuracy.ts` | Read predictions from Postgres, drop fuzzy matching |
| olas-website | `common-util/api/predict/omenstrat-roi.ts` | Read predictions from Postgres |
| olas-website | `common-util/api/predict/polystrat-roi.ts` | Read predictions from Postgres |

### Phase 3 (deferred, contract changes)

| Repo | File | Change |
|------|------|--------|
| autonolas-marketplace | new `BalanceTrackerFixedPriceTokenVoucher.sol` | Cumulative voucher settlement |
| autonolas-marketplace | `MechMarketplace.sol` | New `settleBatchByVouchers` function with try/catch |
| autonolas-marketplace | `OlasMech.sol` | Forwarder for the new function |
| mech, mech-client, mech-interact | various | Voucher signing, voucher submission |

---

## References

- `mech/packages/valory/skills/task_execution/handlers.py` — existing HTTP handler we extend in Phase 1
- `mech-client/mech_client/services/marketplace_service.py` — existing HTTP path we modify in Phase 1
- `mech-interact/packages/valory/skills/mech_interact_abci/behaviours/request.py` — the on-chain-only behaviour Phase 1 forks
- `wildcard/server/alembic/versions/001_initial_schema.py` — the predictions table schema we extend in Phase 2
- `wildcard/server/alembic/versions/004_historical_backfill_columns.py` — the platform, source, agent_safe columns we reuse in Phase 2
- `olas-website/common-util/api/predict/tool-accuracy.ts` — the metric file we rewrite in Phase 2
- `olas-website/common-util/api/predict/omenstrat-roi.ts` and `polystrat-roi.ts` — the ROI files we rewrite in Phase 2
- `contracts/MechMarketplace.sol` — the marketplace that stays unchanged in Phases 1 and 2
- `contracts/mechs/token/BalanceTrackerFixedPriceToken.sol` — the balance tracker that stays unchanged in Phases 1 and 2
