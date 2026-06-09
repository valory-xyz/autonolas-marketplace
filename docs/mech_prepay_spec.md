# Mech Prepay — Phased Plan

## What this is

A three-phase plan to move mech requests off the public chain rails while keeping them billable and auditable. Each phase delivers value standalone.

## Phases at a glance

| Phase | What ships | Contract changes | Effort |
|-------|------------|------------------|--------|
| **Phase 1** — HTTP requests, privacy via no-IPFS | Mech accepts requests over HTTPS. Content stays off public IPFS. Contracts untouched. | None | ~1500-2900 lines |
| **Phase 2** — Centralized analytics in our existing Postgres | Mechs write predictions to the same Postgres pearl-mini already uses. Website metrics read from there. Three files change. | None | ~900 lines |
| **Phase 3** — Optional scaling (deferred) | Cumulative voucher, multi-requester batching, fail-soft batching. Only build when volume justifies. | Yes (audit-needed) | Per-item, evaluated separately |

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

The mech already has an HTTP server. We extend it to take requests, stop pushing the content to IPFS, and keep the same on-chain settlement we use today. Anyone scraping IPFS finds nothing. The on-chain CID still proves what the mech delivered if anyone disputes it later.

## What we aim to implement

- Mech takes requests via HTTP instead of just on-chain
- Mech stops pushing request and response content to IPFS
- Mech still puts the same content hash on-chain (so disputes still work)
- Mech-client uses the HTTP path (it already supports it, just stops pushing to IPFS)
- mech-interact (used by Trader and other agents) gets a new branch that uses the HTTP path
- Trader and other agents flip a config flag to use the HTTP path
- No contract changes

## Flow

```
   Client (Trader / agent / mech-client)
       │
       │  1. Build request locally
       │     (compute the IPFS hash on the fly, don't upload)
       ▼
   POST /predict over HTTPS  ────────────────────▶  Mech HTTP server
                                                       │
                                                       │  2. Check sender has balance
                                                       │     on-chain
                                                       │
                                                       │  3. Queue the task
                                                       │     (response stored in memory)
                                                       │
                                                       │  4. Run the tool
                                                       ▼
   GET /fetch_offchain_info  ◀───────────────────  result available
                                                       │
                                                       │  5. Batch-settle on-chain
                                                       │     (same path as today,
                                                       │     just with the locally
                                                       │     computed hash, no IPFS upload)
                                                       ▼
                                              MechMarketplace.deliverMarketplaceWithSignatures
                                                       │
                                                       │  on-chain event still fires
                                                       │  with content hash, but
                                                       │  the content itself is
                                                       │  not on IPFS
                                                       ▼

If someone disputes a delivery later:
   Mech reveals the saved request/response
   The hash still matches the on-chain commitment
   Anyone can verify
```

## Why this gives us privacy without new crypto

A content hash is a one-way function. If we put the hash on-chain but never publish the content anywhere, scrapers see only the hash. They can't get the content. But the hash is still bound to specific content. If the mech later tries to lie about what was asked or delivered, anyone with the original content can re-hash it and prove the lie. So the mech is honesty-locked even though the content is private.

## Detailed implementation

### What changes in the mech (server side)

In `mech/packages/valory/skills/task_execution/handlers.py`:

- Add a flag `is_offchain` on the task struct
- When the flag is set:
  - Skip the IPFS upload of the request metadata
  - Skip the IPFS upload of the response
  - Keep the response in memory so the `/fetch_offchain_info` route can return it
- When the mech submits the on-chain settlement at the end of the batch:
  - Compute the IPFS hash locally using the same hashing library IPFS uses
  - Put that hash on-chain (so the on-chain record is still content-bound)
  - But don't upload anywhere
- Retain the original request and response bytes in a local on-disk store for the audit window

Effort: ~50 lines of code + ~150 lines of tests.

### What changes in mech-client

In `mech-client/mech_client/services/marketplace_service.py`:

- The HTTP path already exists (`--use-offchain` flag, line 69 of `request_cmd.py`)
- Today it still uploads the request metadata to IPFS as part of the request build
- Remove that upload. Build the JSON locally. Compute the hash locally. Send the JSON inline in the HTTP body.

Effort: ~30 lines of code + ~50 lines of tests.

### What changes in mech-interact (the big work)

`mech-interact` is the library Trader, Market-Creator, Meme-OoOrr, IEKit, and other autonomous agents use to talk to mechs. Today it only knows how to submit requests on-chain. We add a parallel HTTP branch:

- New `MechOffchainRequestBehaviour`: builds the request body, signs the request id with the agent's Safe key, POSTs to the mech's HTTP endpoint
- New `MechOffchainResponseBehaviour`: polls the mech's `/fetch_offchain_info` endpoint until the result is ready or the timeout hits. On timeout, falls back to the next priority mech (privacy regression: same content goes to another mech).
- Same wire format mech-client already uses.

This is the biggest single piece of Phase 1. Estimate: ~800-1300 lines of code + ~400-1300 lines of tests.

### What changes in our agents (Trader, etc.)

One line of config in each service's `service.yaml`:

```yaml
use_offchain: ${USE_OFFCHAIN:bool:true}
```

No other code changes. Agents that haven't migrated keep using the on-chain path. Migrate when ready.

### Mech operator retention SLA

New responsibility: every operator must keep request and response content on local disk for the audit window. Recommended window: 30 days minimum. Decision pending on whether 30, 90, or longer.

### Phase 1 contract changes

Zero. The existing `deliverMarketplaceWithSignatures` already accepts arbitrary bytes for `paymentData` and `deliveryData`. We just use it.

### Phase 1 trade-offs

- If the mech goes down or loses its local data, the response is gone forever
- Quality scoring can't read responses from IPFS anymore (handled in Phase 2)
- Single point of failure for liveness, deliberate

### Phase 1 effort total

Around 1500-2900 lines across mech, mech-client, mech-interact, and agent config. Dominated by the new mech-interact behaviour.

---

# Phase 2 — Centralized analytics in our existing Postgres

## TL;DR

Pearl-mini already writes prediction records to a Postgres database. We extend that database with a new column for mechs, have mechs write to it, and rewrite three website files to read from it instead of the marketplace subgraph. No resolution backfill, no extra workers — Omen and Polymarket subgraphs already carry resolution data and we keep using them.

## What we aim to implement

- Add three small columns to the existing predictions table
- Add an HTTP endpoint on the wildcard server (the same server pearl-mini uses) so mechs can write predictions
- Mech calls that endpoint each time it accepts and completes a request
- Per-mech rate limits on the write endpoint
- Update three website metric files (tool accuracy, omenstrat ROI, polystrat ROI) to read from Postgres instead of marketplace subgraph
- Four other metric files unchanged
- No new resolution backfill worker (Omen and Polymarket subgraphs already provide this)
- Historical backfill from the marketplace subgraph: recommended, not required

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
                  │ (new endpoint)      │                       │ from Postgres      │
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

The Omen subgraph returns `currentAnswer` on every bet. The Polymarket subgraph returns `winningIndex` on every question. Today's tool-accuracy code already reads these directly from the bet objects. We just keep that part. The predictions table doesn't need to know about resolutions at all — the website joins predictions (from Postgres) with bets+resolutions (from subgraphs) at query time.

## Detailed implementation

### Postgres schema additions

Three changes to the existing predictions table:

```sql
-- Allow a new source value for mech-written rows
ALTER TABLE predictions DROP CONSTRAINT predictions_source_check;
ALTER TABLE predictions ADD CONSTRAINT predictions_source_check
    CHECK (source IN ('wildcard', 'parquet_historical', 'mech_offchain'));

-- Which mech served this request (NULL for non-mech rows)
ALTER TABLE predictions ADD COLUMN mech_address TEXT;
CREATE INDEX predictions_mech_address_idx ON predictions (mech_address)
    WHERE mech_address IS NOT NULL;

-- Which chain (Gnosis, Polygon, Base, etc.)
ALTER TABLE predictions ADD COLUMN chain_id INTEGER;
```

Twenty lines of migration. All other columns already exist and serve our needs.

### The mech write endpoint

A new HTTP route on the wildcard FastAPI server:

```
POST /predictions
Authorization: Bearer <mech-operator-api-key>

Body:
{
  "request_id": "0x...",
  "status": "processing" | "complete" | "failed",
  "tool_name": "openai-gpt-4",
  "tool_version": "0x...",        // local IPFS hash of the tool code
  "model_requested": "...",
  "model": "...",
  "cost": "10200",                // atomic units, matches delivery rate
  "question_text": "...",
  "outcomes": ["Yes", "No"],
  "market_id": "0x...",
  "market_url": "https://...",
  "market_close_at": "2026-...",
  "p_yes": 0.62,
  "p_no": 0.38,
  "confidence": 0.83,
  "prompt_used": "...",           // stored (auth-gated, not public)
  "user_wallet": null,            // for mech rows: null
  "agent_safe": "0x...",          // the bettor identity
  "platform": "omen" | "polymarket",
  "source": "mech_offchain",
  "mech_address": "0x...",
  "chain_id": 100,
  "predicted_at": "2026-...",
  "latency_s": 1.2
}
```

The endpoint:
- Verifies the API key
- Checks the mech_address in the body matches the key holder
- Applies per-operator rate limiting (recommended: 100 requests/second/operator initial, tune from logs)
- Inserts or updates the predictions row by request_id
- Returns 200 on success, 4xx on validation, 5xx on DB error

Effort: ~150 lines on the wildcard server.

### The mech write client (inside the mech)

When the mech accepts a request (Phase 1 step 3 in the flow above):

```
POST /predictions with status="processing", tool_name, market_id, prompt_used, ...
```

When the mech finishes the tool execution:

```
POST /predictions with same request_id, status="complete", p_yes, p_no, confidence,
                       predicted_at, latency_s
```

If the tool fails:

```
POST /predictions with status="failed", error message
```

Three calls per request lifecycle. Async, non-blocking. If the Postgres call fails (network blip, server down), the mech queues the write locally and replays. Mech doesn't refuse a request because Postgres is down.

Effort: ~150 lines of mech-side code.

### Authentication and rate limits

- Each mech operator gets a unique API key tied to their `mech_address`
- Standard FastAPI auth middleware on `POST /predictions`
- Rate limit: per-API-key, sliding window
- Recommended initial limit: 100 writes/second per operator (covers high traffic mechs with headroom). Tune from monitoring.

Effort: ~50 lines on the wildcard server.

### The website metric rewrites

Three files change.

#### tool-accuracy.ts

Today: queries the marketplace subgraph for `parsedRequest.tool` and `parsedRequest.questionTitle`, then fuzzy-matches bet questions to mech requests.

After Phase 2: queries Postgres for predictions directly, joins to bets by `(market_id, bettor)`. The fuzzy matching function (`matchBetToMechRequest`, lines 110-142) goes away.

Pseudocode:

```typescript
// One SQL query to Postgres
const predictions = await pgQuery(`
  SELECT request_id, tool_name, market_id, agent_safe, platform
  FROM predictions
  WHERE source = 'mech_offchain'
    AND status = 'complete'
    AND predicted_at > $1
`, [sinceTimestamp]);

// Existing bet fetch from Omen subgraph (unchanged)
const bets = await fetchResolvedBets();

// Index predictions for fast lookup
const predIndex = new Map();
for (const p of predictions) {
  predIndex.set(`${p.platform}|${p.market_id}|${p.agent_safe.toLowerCase()}`, p);
}

// For each bet, look up the prediction and check correctness
for (const bet of bets) {
  const key = `omen|${bet.fixedProductMarketMaker.id}|${bet.bettor.id.toLowerCase()}`;
  const pred = predIndex.get(key);
  if (!pred) continue;
  const correct = Number(bet.fixedProductMarketMaker.currentAnswer) === Number(bet.outcomeIndex);
  bumpStats(pred.tool_name, correct);
}
```

Same shape for the Polymarket version, with `platform = 'polymarket'` and `winningIndex` instead of `currentAnswer`.

Effort: ~80 lines, mostly deletions. The file gets shorter.

#### omenstrat-roi.ts

Today: matches mech requests to open markets by fuzzy `parsedRequest.questionTitle` (line 228).

After: exact join on `market_id`. The open-market list still comes from the Omen subgraph; the mech-request side comes from Postgres.

Effort: ~30 lines.

#### polystrat-roi.ts

Same change as omenstrat-roi.ts but for the Polymarket version.

Effort: ~30 lines.

### Files that don't change

- `omenstrat-brier.ts` — uses the Omen daily Brier subgraph, no marketplace dependency
- `omenstrat-success-rate.ts` — uses Omen bets only
- `polystrat-success-rate.ts` — uses Polymarket bets only
- `index.ts` — uses registry / staking subgraphs only

### The prompt_used column

We store the full prompt. The Postgres is internal infrastructure, not public. Anyone querying it is authenticated. This matches how wildcard already handles pearl-mini's prompts. The on-chain commit-reveal property still holds for the public surface.

If anyone wants stricter privacy later, switch this column to a hash. Not blocking for Phase 2.

### Historical backfill (recommendation, not requirement)

Today's marketplace subgraph still has rich `parsedRequest` data for all the on-chain mech traffic that used public IPFS. To preserve continuity in the tool accuracy and ROI metrics, we recommend a one-time backfill:

- Read all historical Request and Delivery events from the marketplace subgraph
- For each, read the `parsedRequest.tool` and `parsedRequest.questionTitle` (already populated)
- Insert into Postgres with `source = 'parquet_historical'` and `mech_address` filled from the on-chain event sender

This is optional. If we skip it, metrics reset at migration date — the tool accuracy table for the recent window will be sparse for a few days until enough mech_offchain rows accumulate. If continuity matters for product positioning, run the backfill.

Effort if we do it: ~300 lines (port from wildcard's parquet pipeline).

### Phase 2 contract changes

Zero. All adaptation is in Postgres, the wildcard server, the mech, and the website.

### Phase 2 effort total

~910 lines, plus the optional ~300 line historical backfill.

| Component | Lines |
|-----------|-------|
| Postgres migration (new source, mech_address, chain_id) | ~20 |
| Wildcard server POST /predictions endpoint | ~150 |
| Mech write client | ~150 |
| Auth + per-mech rate limits | ~50 |
| tool-accuracy.ts rewrite | ~80 |
| omenstrat-roi.ts rewrite | ~30 |
| polystrat-roi.ts rewrite | ~30 |
| Tests | ~400 |
| **Total** | **~910** |
| Historical backfill (recommendation) | +~300 |

---

# Phase 3 — Optional scaling improvements

## TL;DR

Three independent contract-level improvements. None of them ship by default. Each gets evaluated on its own merits when a specific volume threshold is crossed. They share the property that they need contract changes and an audit.

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

## Why these aren't in Phase 1 or 2

Each one needs a contract change, an audit, and meaningful client SDK work. The benefit only shows up at high traffic. For mechs serving a few requests per day, the per-request signature path is fine. For a mech doing thousands of requests per day from dozens of clients, the savings stack up.

## Detailed implementation (per item)

### Item A — One signature per batch

**The problem.** The current settlement path verifies every request's signature individually inside the smart contract. For 50 requests in a batch from one client, that's 50 signature verifications on-chain. Each one costs gas.

**The fix.** Instead of one signature per request, the client signs a single authorization per session that says "I authorize the mech to charge me up to X total." Each new request just bumps X. The mech keeps the latest authorization. On settlement, the contract verifies one signature regardless of how many requests it represents.

**When it's worth doing.**

| Client behavior | Today's cost | After Item A | Worth it? |
|-----------------|--------------|--------------|-----------|
| Sends 1-3 requests per session | Tiny | Tiny | No, not worth the contract work |
| Sends 10 requests per session | ~$0.30 in gas | ~$0.05 | Marginal |
| Sends 50+ requests per session | ~$2.50 in gas | ~$0.05 | Yes, real savings |

Recommendation: defer until we have a concrete client (Optimus, an internal product, a partner) that hits the high-traffic range.

**What it needs to build.** A new BalanceTracker subclass (~300 lines), a new marketplace function (~100 lines), client SDK changes to sign the cumulative authorization instead of per-request signatures. Plus audit time.

### Item B — One transaction covers all clients in a batch window

**The problem.** The current settlement function takes one client per call. So if 50 different clients each made requests in the same 5-minute window, the mech submits 50 separate transactions. Each pays the same fixed overhead.

**The fix.** A new settlement function that takes an array of clients and settles all of them in one transaction. Overhead is paid once, not 50 times.

**When it's worth doing.**

| Mech behavior | Today's cost | After Item B | Worth it? |
|---------------|--------------|--------------|-----------|
| Serves <5 distinct clients per window | Small | Small | Marginal |
| Serves 10-50 clients per window | 10-50x marketplace overhead | 1x marketplace overhead | Yes |
| Serves 100+ clients per window | Very expensive | 1x overhead | Yes, large savings |

Recommendation: ship together with Item A. They're closely coupled — the combined effect makes the whole batch one cheap transaction.

**What it needs to build.** Extends the new function from Item A to accept an array. ~100-150 lines of marketplace code plus matching mech-side batch builder.

### Item C — One bad request doesn't drop the others

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
| wildcard | auth module | Per-operator API key issuance and validation |
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
