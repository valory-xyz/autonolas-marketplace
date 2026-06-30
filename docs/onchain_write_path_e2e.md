# On-chain Write Path — End-to-End Test Runbook

Cross-repo manual verification for the on-chain write path described in [`onchain_write_path_scope.md`](onchain_write_path_scope.md). Companion to [`mech_prepay_e2e_test_plan.md`](mech_prepay_e2e_test_plan.md), which covers the off-chain HTTP path. Run this once before declaring the work done.

The flow exercises:

1. An on-chain request that times out without being delivered (priority mech sweeps it into a request-only event).
2. A different mech stepping in to deliver the same request after the timeout (the lake's `delivery_mech` updates from NULL to the stepper's address, response row appears).

The DB's `ON CONFLICT (request_id) DO UPDATE ... WHERE delivery_mech IS NULL` is what makes the second write idempotent and order-independent — the runbook below confirms that property holds end-to-end.

---

## Prerequisites

- A local Ethereum fork (anvil / hardhat / ganache). Mainnet fork is fine; what matters is that two mechs and a marketplace are deployed and reachable.
- A wildcard / predict-api instance with migration `008_mech_onchain_source` applied. Confirm:

  ```sh
  alembic current
  # ... 008_mech_onchain_source (head)
  ```

- Two mech services running, both registered with the marketplace and both in the predict-api `mech_operators_by_chain` registry. Call them `MECH_PRIORITY` and `MECH_STEPPER` below.
- A requester EOA funded with the marketplace's payment asset.
- `psql` access to the wildcard Postgres (read-only role is fine for verification).

Concrete addresses to fill in before running:

| Variable | Where to find it |
|---|---|
| `MARKETPLACE` | `autonolas-marketplace/docs/configuration.json` for the chain. |
| `MECH_PRIORITY` | The `OlasMech` contract address registered via `MechFactory`. |
| `MECH_STEPPER` | Second registered mech on the same chain. |
| `REQUESTER` | Caller of `requestBatch` below. |
| `CHAIN_ID` | Integer chain id of the fork. |
| `RESPONSE_TIMEOUT` | Within `[minResponseTimeout, maxResponseTimeout]` from the marketplace; keep small for testing, e.g. 60 seconds. |

---

## Step 1 — Submit an on-chain request to the priority mech

Anvil shell or scripted call:

```sh
cast send $MARKETPLACE \
  "request(bytes,uint256,bytes32,address,uint256,bytes)" \
  $REQUEST_DATA $MAX_DELIVERY_RATE $PAYMENT_TYPE $MECH_PRIORITY $RESPONSE_TIMEOUT $PAYMENT_DATA \
  --from $REQUESTER --private-key $REQUESTER_KEY
```

`REQUEST_DATA` is the bytes-encoded request payload the mech would have IPFS-pinned in the legacy flow (here, anything non-empty is fine for the test). `RESPONSE_TIMEOUT` is the relative timeout in seconds.

Capture the returned `requestId` from the `MarketplaceRequest` event.

Verify on-chain that the request lives and is in the priority window:

```sh
cast call $MARKETPLACE "getRequestStatus(bytes32)(uint8)" $REQUEST_ID
# Expected: 1   (RequestStatus.RequestedPriority)
```

---

## Step 2 — Wait past the response timeout without delivering

Either sleep `RESPONSE_TIMEOUT + 1` seconds in real time, or fast-forward the fork:

```sh
cast rpc anvil_mine $((RESPONSE_TIMEOUT + 10))
cast rpc evm_increaseTime $((RESPONSE_TIMEOUT + 10))
cast call $MARKETPLACE "getRequestStatus(bytes32)(uint8)" $REQUEST_ID
# Expected: 2   (RequestStatus.RequestedExpired)
```

Crucially, do NOT call `deliverMarketplaceWithSignatures` on either mech yet.

---

## Step 3 — Trigger PostTxSettlement on the priority mech

The mech needs a settlement round to fire `PostTxSettlement`. Send any other delivered request through `MECH_PRIORITY` (a separate, fresh request with a generous timeout that this mech will actually serve), and let the FSM settle it. The settlement round will sweep the local pending tasks, find the now-expired one from Step 1, and POST a request-only event to `/mech/events` alongside the delivered event for the fresh request.

To force a settlement without sending a fresh request, you can also call the FSM's `PostTxSettlementBehaviour` directly via the mech operator's debug tooling — match whatever pattern the off-chain runbook uses.

---

## Step 4 — Verify the request-only row landed

```sql
SELECT request_id, priority_mech, delivery_mech, source, requested_at
FROM mech_requests
WHERE request_id = '<REQUEST_ID>';
```

Expected (note `delivery_mech` IS NULL, `source = 'mech_onchain'`):

```
 request_id | priority_mech  | delivery_mech | source       | requested_at
------------+----------------+---------------+--------------+--------------
 0x...      | <MECH_PRIORITY>| NULL          | mech_onchain | 2026-...
```

And no response row exists:

```sql
SELECT COUNT(*) FROM mech_responses WHERE request_id = '<REQUEST_ID>';
-- Expected: 0
```

This is the analytics-side definition of "undelivered": a `mech_requests` row with no matching `mech_responses` row. The `delivery_mech IS NULL` is the on-chain claim; the absent response is the lake's claim.

---

## Step 5 — Have the stepping mech deliver

```sh
# Build the deliver payload (request data + delivery data) the same way the
# mech does internally. The stepper does NOT need to be the priority mech —
# step-in is allowed after RequestedExpired.
cast send $MARKETPLACE \
  "deliverMarketplaceWithSignatures(...)" \
  ... \
  --from $MECH_STEPPER_OPERATOR --private-key $MECH_STEPPER_OPERATOR_KEY
```

Verify on-chain that delivery landed:

```sh
cast call $MARKETPLACE "getRequestStatus(bytes32)(uint8)" $REQUEST_ID
# Expected: 3   (RequestStatus.Delivered)
```

---

## Step 6 — Trigger PostTxSettlement on the stepping mech

Same shape as Step 3 but on `MECH_STEPPER`. The stepper's settlement round will write a full `{request, response}` event for the request it just delivered. The request half hits the existing row from Step 4 via `ON CONFLICT (request_id) DO UPDATE SET delivery_mech = EXCLUDED.delivery_mech WHERE mech_requests.delivery_mech IS NULL` — the WHERE guard passes (existing row has NULL `delivery_mech`), so `delivery_mech` updates to the stepper. The response half is a fresh insert.

---

## Step 7 — Verify the final state

```sql
SELECT request_id, priority_mech, delivery_mech, source
FROM mech_requests
WHERE request_id = '<REQUEST_ID>';
```

Expected:

```
 request_id | priority_mech  | delivery_mech  | source
------------+----------------+----------------+--------------
 0x...      | <MECH_PRIORITY>| <MECH_STEPPER> | mech_onchain
```

```sql
SELECT request_id, delivery_mech, status, source
FROM mech_responses
WHERE request_id = '<REQUEST_ID>';
```

Expected:

```
 request_id | delivery_mech  | status   | source
------------+----------------+----------+--------------
 0x...      | <MECH_STEPPER> | complete | mech_onchain
```

The row now shows step-in cleanly: priority mech is the original mech, delivery mech is the stepper, response row exists with `status = 'complete'`. Karma penalty against the priority mech is observable as a `priority_mech ≠ delivery_mech` row.

---

## Reverse-order variant

Run the same flow but swap the timing of Steps 4 and 6: have the stepper write FIRST (full event), then the priority mech write the request-only event for the now-already-delivered request. Expected end state is identical — the `ON CONFLICT ... WHERE delivery_mech IS NULL` clause fails on the second write (the row already has a non-NULL `delivery_mech` from the stepper), so the request-only write is a no-op. This pins the race-safety claim from §3.4 of the scope doc.

---

## What to record

After running, capture in the PR or runbook log:

- The two `requestId` values used (timed-out request and the fresh request that triggered each settlement).
- Final state of `mech_requests` and `mech_responses` rows for the timed-out request.
- Whether the reverse-order variant was also exercised.

If any of the SQL outputs don't match the expected shapes above, do not declare the work done — the divergence is the bug.
