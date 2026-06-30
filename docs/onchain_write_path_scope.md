# On-chain Write Path — Scope and Decisions

Companion to `docs/marketplace_api_spec.md`. The off-chain write loop (mech HTTP request → on-chain settlement → `POST /mech/events`) is already specced and shipping. This document covers the on-chain equivalent: how on-chain requests and deliveries land in the predict-api data lake, including the requests that never get delivered, with mech step-in handled correctly.

Implementation detail lives wherever the code lands (mech repo + wildcard server repo); this is the agreed-shape and decisions doc.

---

## 1. TL;DR

The mech extends what it already does on settlement. `PostTxSettlement` already writes one `{request, response}` event per delivered request, batched and EIP-712 signed, to `POST /mech/events`. We add two things:

1. For on-chain deliveries, the same write fires with `source='mech_onchain'` (today it always writes `mech_offchain`).
2. In the same `PostTxSettlement` round, the mech also scans its local tasks list for requests that have timed out without delivery, and appends a request-only event for each (`{request, response: null}`).

Net effect: the data lake captures everything the marketplace knows about, on-chain and off-chain. The marketplace subgraph stops being a load-bearing dependency for analytics.

No new endpoint, no new service, no indexer. Same writer, same auth, slightly extended event model, one new value on a CHECK constraint.

---

## 2. Why we need this now

Today the data lake only contains paid deliveries from the off-chain HTTP path. Three gaps:

1. **On-chain deliveries are invisible.** Mechs that serve requests over the marketplace contract (rather than HTTP) never write to the data lake. The analytics ETL therefore can't see their predictions or fees. We're decommissioning the legacy mech contracts, but the on-chain path on the new marketplace is still a live shape.
2. **Undelivered requests are invisible.** A requester pays the marketplace, the priority mech never delivers, no `mech_requests` row gets written. The request is real but absent from analytics. Delivery failure rate per mech can't be computed.
3. **Subgraph dependency.** Consumers like the Economy Explorer count "transactions per day" from the marketplace subgraph today. With on-chain requests in the data lake, the subgraph can be retired for analytics use cases.

Step-in (a mech that wasn't the priority deliverer stepping in after the priority timeout) needs to be recorded correctly: the row should show `priority_mech = P` and `delivery_mech = S` (the stepper), and any karma penalty against P should be derivable from the row.

---

## 3. The design

The mech's `PostTxSettlement` behaviour is the only write site, as it is today. Two kinds of events go into each batched, signed POST to `/mech/events`:

### 3.1 Delivered events (today's shape, with `source='mech_onchain'` for on-chain)

The mech writes one event per delivered request:

```
{
  "request":  { request_id, chain_id, priority_mech=<the original priority mech>,
                delivery_mech=<this mech>, prompt, tool, delivery_rate, ... ,
                source: "mech_onchain" },
  "response": { request_id, delivery_mech=<this mech>, status: "complete" | "failed",
                result, ... , source: "mech_onchain" }
}
```

Step-in falls out for free: when this mech stepped in to deliver another mech's request, `priority_mech` is the original mech (read from the on-chain `RequestInfo`) and `delivery_mech` is this mech. The two are different. Karma decrement against the priority mech is observable from the row.

### 3.2 Undelivered events (new)

In the same `PostTxSettlement` round, the mech scans its local tasks list for entries past their `responseTimeout`. That single local-clock comparison is the whole decision rule — no contract read, no consultation of `getRequestStatus`. If a stepping mech has actually delivered the request between the timeout passing and the sweep, the DB's race-safe `ON CONFLICT` clause on `mech_requests.delivery_mech` (see §3.4) reconciles the two writes to the correct row regardless of order.

For each timed-out entry, the mech appends a request-only event to the batch:

```
{
  "request":  { request_id, chain_id, priority_mech=<this mech, since it was assigned>,
                delivery_mech=null, prompt, tool, delivery_rate, ... ,
                source: "mech_onchain" },
  "response": null
}
```

Then the mech can clear the request from its local tasks list.

### 3.3 Why "undelivered" is the absence of a response row, not a `status='failed'` row

The FK already shapes this: each `mech_requests` row has 0 or 1 `mech_responses` rows. So the natural semantic is:

- `mech_requests` row exists → the request happened.
- Matching `mech_responses` row exists → the request was delivered. `status` indicates whether the tool succeeded or errored during execution.
- `mech_requests` row exists with no matching `mech_responses` row → the request was never delivered by any mech.

If we instead wrote a `status='failed'` response for undelivered requests, we'd overload what `status='failed'` already means today: "the tool ran and produced an error during execution" (e.g. LLM timeout, JSON parse failure, upstream API 500). Every downstream consumer of `status='failed'` would then have to disambiguate "tool failed" from "never delivered" via the error message. Bad coupling.

The absence-of-response model keeps `status='failed'` meaning what it means today and lets undelivered surface through a `LEFT JOIN` query that the analytics ETL already understands.

### 3.4 Race between "timed out" and "stepped in"

A subtle but real race: priority mech P writes a request-only event after `responseTimeout`, and at the same time mech S steps in and delivers (the contract allows step-in indefinitely after timeout). The order of writes to the lake determines what's left, and the DB — not the mech's local state — is the arbiter.

We make the writer order-independent via the conflict clause on `mech_requests`:

```sql
INSERT INTO mech_requests (...)
  ON CONFLICT (request_id) DO UPDATE
    SET delivery_mech = EXCLUDED.delivery_mech
    WHERE mech_requests.delivery_mech IS NULL
```

Two orderings:

**Scenario A — S writes first:**
- S inserts `mech_requests(delivery_mech=S)` and `mech_responses(status='complete')`.
- P (later) writes the request-only event. The `mech_requests` insert hits ON CONFLICT, the WHERE guard fails (S's row has a non-NULL `delivery_mech`), so no update. Row stays correct.

**Scenario B — P writes first:**
- P inserts `mech_requests(delivery_mech=NULL)`, no `mech_responses` row.
- S (later) inserts `mech_requests(delivery_mech=S)`. ON CONFLICT hits, WHERE guard passes (existing row's `delivery_mech` IS NULL), so the update applies. `delivery_mech` becomes S.
- S inserts `mech_responses` fresh. No conflict, succeeds.

Both orderings end up at the same correct state. No "real" data ever gets overwritten because the WHERE guard only fires on NULL.

The trade-off of leaning on the DB instead of consulting the contract first: a brief inconsistency window between P's request-only write and S's delivered write where the lake shows `delivery_mech = NULL` for a request the chain already considers delivered. Window is typically seconds (a few blocks plus the gap between settlements). Acceptable for analytics in v1; if a consumer ever needs strict freshness it can `LEFT JOIN` against the marketplace's `getRequestStatus` directly, or we can add the contract read as a pre-write filter on the mech (one-PR change).

---

## 4. What changes, by side

### 4.1 Predict-api (wildcard server)

Three changes, all small.

**Migration (new revision 008)**

- Add `'mech_onchain'` to the `source` CHECK on both `mech_requests` and `mech_responses`.
- Add a `mech_requests_onchain_requested_at` CHECK mirroring the existing offchain one, so the on-chain live path also has to carry `requested_at`.

```sql
ALTER TABLE mech_requests   DROP CONSTRAINT mech_requests_source_check;
ALTER TABLE mech_responses  DROP CONSTRAINT mech_responses_source_check;
ALTER TABLE mech_requests   ADD CONSTRAINT mech_requests_source_check
  CHECK (source IN ('mech_offchain', 'mech_onchain', 'ipfs_historical'));
ALTER TABLE mech_responses  ADD CONSTRAINT mech_responses_source_check
  CHECK (source IN ('mech_offchain', 'mech_onchain', 'ipfs_historical'));
ALTER TABLE mech_requests   ADD CONSTRAINT mech_requests_onchain_requested_at
  CHECK (source <> 'mech_onchain' OR requested_at IS NOT NULL);
```

`prompt` and `tool` stay `NOT NULL` everywhere. The mech has them in its local tasks list (resolved from IPFS during the request execution attempt) by the time `PostTxSettlement` runs, including for undelivered events.

**Model (`server/src/models/mech.py`)**

`MechSettlementEvent` renames to `MechEvent`. The `response` field becomes optional. Validator skips response-shape checks when `response is None`.

```python
class MechEvent(BaseModel):
    request: MechRequestPayload
    response: MechResponsePayload | None = None

    @model_validator(mode="after")
    def _check(self) -> "MechEvent":
        if self.response is None:
            return self
        # existing complete/failed/result/error checks unchanged
        ...
```

**Writer (`server/src/mech_store.py`)**

Branch on `event.response is None`. Change the `mech_requests` insert's conflict clause to overwrite a NULL `delivery_mech` only.

```python
await conn.execute(
    """
    INSERT INTO mech_requests (...) VALUES (...)
    ON CONFLICT (request_id) DO UPDATE
        SET delivery_mech = EXCLUDED.delivery_mech
        WHERE mech_requests.delivery_mech IS NULL
    """,
    ...
)

if event.response is not None:
    await conn.execute(
        """
        INSERT INTO mech_responses (...) VALUES (...)
        ON CONFLICT (request_id) DO NOTHING
        """,
        ...
    )
```

The `mech_responses` insert keeps `ON CONFLICT DO NOTHING`. Only the delivering mech ever writes the response row, so the race we care about is on the request side, not the response side.

### 4.2 Mech repo

Two changes.

**`PostTxSettlement` extension**

After building the delivered events list, scan the local tasks list. For each task whose `responseTimeout` has passed by the local clock, build a request-only event, append it to the batch, and remove the task from the local list. No contract read.

```python
events = build_delivered_events(settled_deliveries)

for task in list(local_tasks_list):
    if now() > task.response_timeout:
        events.append(build_request_only_event(task))
        local_tasks_list.remove(task)
```

Concurrent step-in (the timeout passes and another mech delivers between the local clock check and the write) is reconciled at the DB layer by the `ON CONFLICT (request_id) DO UPDATE ... WHERE delivery_mech IS NULL` clause on `mech_requests` — see §3.4. The mech does not need to ask the contract whether someone else already delivered; the DB collapses both orderings to the same correct row.

The whole batch (delivered + undelivered events) is signed once with the existing EIP-712 path and POSTed in one call.

**Source field**

The event builder sets `source='mech_onchain'` on events for on-chain deliveries (and on the request-only events, which are by definition on-chain). The existing off-chain HTTP path keeps writing `source='mech_offchain'`.

### 4.3 What's NOT changing

- `POST /mech/events` endpoint shape (still a `SignedMechEventBatch` of events).
- EIP-712 typed data and signing logic.
- The route layer (signature verification, `Safe.getOwners` cache, `checkMech` cache).
- The `mech_responses` insert's conflict clause.
- The `prompt` and `tool` `NOT NULL` constraints.
- The `MechMarketplace`, `OlasMech`, or `BalanceTracker` contracts. Zero on-chain changes.

---

## 5. Rollout order

Predict-api ships first. The migration (008) and the model relaxation are strictly looser than today, so a mech still on the old code keeps working unchanged.

Mech ships second. Once predict-api accepts request-only events with `source='mech_onchain'`, the mech can start sending them.

If the order flips, the mech's request-only POSTs hit a strict server and return 422 until predict-api catches up. Same coordination dance as the original off-chain write loop rollout.

---

## 6. Boundaries

**In scope**:

- Mech-side `PostTxSettlement` extension to capture undelivered requests.
- Predict-api migration + model + writer changes.
- The race-safe ON CONFLICT clause on `mech_requests.delivery_mech`.

**Out of scope (separate workstreams)**:

- Analytics ETL changes to surface `failure rate per mech` or `requests submitted but not delivered` metrics. The data lake will have the rows; consumers can add the query and the aggregate column later if they want them exposed via the Wildcard API.
- IPFS content backfill for `mech_onchain` rows whose `raw_content` might be lighter than the off-chain shape. The mech already resolves IPFS to populate `prompt`/`tool`, so this is only a concern if we discover a gap during implementation.
- Historical on-chain backfill (already covered by the historical IPFS ETL workstream).
- Any consumer-side rewrites (olas-website / townhall-kpis / Economy Explorer migrating off the marketplace subgraph). Independent timing.

---

## 7. Risks and things to flag for review

- **Periodic timeout sweep frequency.** Undelivered events only flush during `PostTxSettlement`, which fires when the mech settles a batch. A mech with no incoming traffic won't fire `PostTxSettlement` and undelivered requests sit until the next batch. Acceptable for v1 (mechs in production have steady traffic); if it bites, add an independent timer-driven sweep.
- **Brief lake-vs-chain staleness on concurrent step-in.** Because the mech writes the request-only event based on its local clock alone (no `getRequestStatus` filter), there is a short window where the lake shows `delivery_mech = NULL` for a request a stepping mech has already delivered on-chain. The window is typically seconds and the DB's race-safe `ON CONFLICT` clause converges to the correct row on the next write. If a consumer ever needs strict freshness, the contract status can be added as a pre-write filter on the mech as a one-PR follow-up.
- **Idempotency of the "delivery_mech NULL → S" update.** Worth a test that confirms two concurrent stepper writes (extremely unlikely but possible in a fork-recovery scenario) don't fight each other. With the WHERE guard on NULL, the second write is a no-op; explicit test would lock it in.
- **What happens if a request is delivered but the delivering mech crashes before `PostTxSettlement` writes.** The on-chain delivery is recorded but the data lake never sees it. Same gap exists today on the off-chain path; treat as known and unchanged.

---

## 8. Effort

Predict-api side: ~1 week. Migration + model + writer + tests, including the race-condition test.

Mech side: ~1 week. `PostTxSettlement` extension (local-clock sweep, no contract reads) + tests.

Coordination + rollout: a few days.

Total: roughly two weeks of one engineer's time across both repos.

---

## 9. Open questions for the team

1. **Are we OK with undelivered events only flushing on the next `PostTxSettlement`?** Or do we want a separate timer-driven sweep so a quiet mech still surfaces its timeouts? Recommendation: ship without the timer; add only if the lag bites.
2. **Should the analytics ETL surface a "failure rate per mech" metric in v1?** The data will be there. No consumer currently asks for it, but Tatiana flagged interest in delivery counts. Recommendation: separate scope; let consumers ask for it.
3. **Once on-chain rows are landing reliably, can the Economy Explorer drop the marketplace subgraph?** Per the earlier discussion: yes for deliveries, yes for requests (since both will now be in the data lake). Worth confirming with whoever owns the Explorer before the subgraph gets retired.
