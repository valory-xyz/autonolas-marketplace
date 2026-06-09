# Mech Prepay Specification

## 1. How far are we from MPP, and what this spec closes

After shipping this spec, mech-prepay becomes functionally MPP session inside the BalanceTracker. The behavioral gap closes completely. The remaining differences are structural and external-compatibility.

| Property | mech-prepay today (pre-deposit only) | This spec | MPP session |
|----------|---------------------------------------|-----------|-------------|
| Cumulative voucher signing | No (per-request signatures) | **Yes** | Yes |
| Funds locked against withdraw | No (race exists) | **Yes (encumbered channels)** | Yes (escrow contract) |
| Settlement race | Exists (bounded by maxRate) | **Eliminated** | Eliminated |
| Atomic batch revert (one bad voucher kills all) | Yes (DOS risk) | **No (fail-soft try/catch)** | Yes (not addressed in MPP spec) |
| Per-request on-chain records (subgraph-indexable) | Yes | **Yes (preserved via Deliver events)** | No |
| Cross-requester batching in one tx | No | **Yes (one tx covers M requesters)** | No (per-channel only) |
| Custody contract | BalanceTracker (existing) | BalanceTracker (existing) | MppEscrow (new contract) |
| Audit boundary | 1 contract | 1 contract | 2 contracts |
| Discoverable on MPPscan | No | No (could add OpenAPI later) | No (same) |
| Payable by generic mppx client | No | No | No |
| MPP-protocol-compatible | No | No | Partial (Valory extension of session intent on EVM) |

### What we'd still need later to be MPP-protocol-compatible

Three additions, all orthogonal to this spec, can be deferred to a v1.1:

1. **OpenAPI discovery document** at `GET /openapi.json` with `x-payment-info` annotations. Self-register at `mppscan.com/register`. Documentation work, no contract changes.
2. **MPP-shaped HTTP headers**: accept `Payment-Credential` as an alternative to our voucher body, emit `Payment-Receipt` on 200. ~30 lines in the mech HTTP handler.
3. **A standalone TypeScript adapter package** so external mppx-style clients can sign vouchers against our channels. ~400-600 lines.

None of those change the on-chain story.

### What this spec implements (the core deltas)

- New EIP-712 PrepayVoucher type for cumulative authorization
- New BalanceTracker subclass with channels + encumbrance + voucher settlement
- New marketplace function `settleBatchByVouchers` with per-voucher try/catch
- New OlasMech forwarder
- New mech HTTP routes for channel-open hints and voucher submission
- mech-client and mech-interact voucher branches
- **Per-request Deliver events preserved** so subgraphs keep working as the source of indexable delivery data

Total new code: ~1900 lines across contracts, mech, and clients. One new audit boundary (the BalanceTracker subclass).

---

## 2. Current architecture, what exists today

This is the baseline before any changes. Mapping what is and isn't already built across the three layers.

### 2.1 Contract side (autonolas-marketplace repo)

**`BalanceTrackerFixedPriceToken`** at `contracts/mechs/token/BalanceTrackerFixedPriceToken.sol`:
- `deposit(amount)` (lines 93-101) pulls USDC via `transferFrom` and credits `mapRequesterBalances[msg.sender]`
- `depositFor(account, amount)` (lines 107-115) same on behalf of another address
- `_adjustInitialBalance` in the base class (`BalanceTrackerBase.sol:90-111`) debits `mapRequesterBalances[requester]` by the summed delivery rate
- No requester withdraw entry today

**`MechMarketplace.sol`**:
- `deliverMarketplaceWithSignatures(requester, deliverWithSignatures[], deliveryRates[], paymentData)` at line 833
- Takes ONE `requester` per call
- Loops through `deliverWithSignatures[i]`, verifying each with `_verifySignedHash` (per-request ecrecover)
- Atomically reverts the whole batch on any signature failure (`SignatureNotValidated`, `AlreadyRequested`, etc.)
- Calls `BalanceTracker.adjustMechRequesterBalances` once at the end with the summed total

**`OlasMech.sol`**:
- `deliverMarketplaceWithSignatures` forwarder at line 285 (`onlyOperator`)
- Forwards directly to the marketplace function with the same shape

What's missing for vouchers and channels:
- Channel state mapping (`mapChannels`)
- Encumbrance tracking (`mapEncumberedAmount`)
- Voucher EIP-712 type + verification helper
- `settleByVoucher`, `openChannel`, `closeChannel`, `requestClose`, `forceClose` entries
- A new marketplace function that takes multiple requesters and isolates failures per voucher

### 2.2 Mech side (mech repo)

**`MechHttpHandler`** at `mech/packages/valory/skills/task_execution/handlers.py:518`:
- HTTP server already running (uses `prometheus_client.start_http_server`)
- Two routes registered today:
  - `POST /send_signed_requests` (line 567): accepts signed off-chain requests with per-request signatures
  - `GET /fetch_offchain_info` (line 668): client polls for response by request_id
- `_check_offchain_requester_balance` (line 853) reads `mech.paymentType()` and `mapRequesterBalances[requester]` on-chain
- Returns HTTP 402 if balance is insufficient (line 631), HTTP 200 if the task is queued (line 662)
- Stores responses in `offchain_request_responses` shared state for the GET endpoint

**Task submission** in `mech/packages/valory/skills/task_submission_abci/behaviours.py`:
- Lines 1567-1596 group off-chain done tasks by sender
- Lines 1596-1648 build one `deliverMarketplaceWithSignatures` call per sender with `paymentData = b""`
- One on-chain transaction per requester per batch window

What's missing:
- HTTP routes for `/open_channel_hint` and `/submit_voucher`
- Voucher signature verification helper (port from `wildcard/server/src/session/voucher.py`)
- Channel state slot in `synchronized_data`
- A new batch behaviour that builds voucher-based settlement calls

### 2.3 Client side (mech-client, the CLI / Python library)

**Already has the off-chain HTTP path built**. In `mech-client/mech_client/services/marketplace_service.py:243-356`:
- `_send_offchain_request` signs per-request data and POSTs to `/send_signed_requests`
- `OffchainDeliveryWatcher` polls the mech HTTP endpoint for the result
- Auto-discovers the mech HTTP URL from on-chain metadata (`marketplace_service.py:136`)
- CLI flag `--use-offchain` at `cli/commands/request_cmd.py:69-71`
- `use_offchain implies use_prepaid` (line 171): the off-chain path uses the pre-deposit balance tracker model already

What's missing:
- Voucher signing (EIP-712 typed data)
- Channel lifecycle commands (`open-channel`, `close-channel`, `request-close`, `withdraw`)
- 402 voucher-hint parsing and retry logic
- Local channel state (e.g., `~/.mech-client/channels.json`)

### 2.4 Client side (mech-interact, the ABCI skill used by Trader, Market-Creator, etc.)

**`MechRequestBehaviour`** at `mech-interact/packages/valory/skills/mech_interact_abci/behaviours/request.py`:
- Today's flow is purely on-chain: `MechMarketplace.request()` / `requestBatch()` per request
- `_ensure_available_balance` (line 512) checks safe / token balance directly, doesn't read the BalanceTracker for token mechs
- `_build_marketplace_v2_request_data` (line 821) builds `request` call with `paymentData = EMPTY_PAYMENT_DATA_HEX`
- Per-payment-type branching (native vs token vs NVM)

**`MechResponseBehaviour`** at `behaviours/response.py`:
- Polls for the Deliver event on the mech / marketplace contract (line 269)
- Decodes the IPFS hash from the event, fetches result from IPFS

What's missing:
- Any HTTP signed-request branch (today it never POSTs to a mech HTTP endpoint)
- Voucher signing using the safe key
- Channel state in `synchronized_data`
- A new behaviour entirely for the voucher + HTTP flow
- A closure behaviour for graceful shutdown (close channels to recover residual)

### 2.5 What the surface tells us

The on-chain settlement pipeline (`deliverMarketplaceWithSignatures` → `adjustMechRequesterBalances` → `_adjustInitialBalance` → `mapRequesterBalances`/`mapMechBalances`) is already the right shape. We just need to layer a voucher-aware variant alongside it.

The mech HTTP server is already running and already does balance checks. We just need to add voucher routes alongside the existing signed-request route.

The client side splits cleanly: mech-client has the HTTP path built and gets a voucher branch; mech-interact has no HTTP path at all and gets a brand-new voucher behaviour.

---

## 3. The design, problem by problem

Four distinct problems with today's mech-prepay. Each has its own targeted fix.

### A. Batch settlement cost is linear in request count

**Problem.**

`MechMarketplace._deliverMarketplaceWithSignatures` (`MechMarketplace.sol:206-285`) iterates over the batch and verifies each request individually. The per-iteration work is approximately:

```
for each i in 0..N-1:
    keccak hash to derive requestId
    ecrecover to verify the per-request signature
    SSTORE to record the request info
    LOG to emit the Deliver event
```

At roughly 50,000 gas per iteration, a 50-request batch from one client burns ~2.5M gas just on this loop. Multiply by M distinct clients per batch window and on-chain settlement dominates everything else.

**Fix.**

Replace per-request signatures with one cumulative voucher per `(requester, mech)` pair per batch period. The client signs ONE EIP-712 typed message authorizing a `cumulativeAmount`. Each new request bumps the cumulative. The mech keeps only the latest voucher per pair off-chain. On settlement, the BalanceTracker verifies ONE signature, checks monotonicity, debits the delta.

Per-request delivery records still ride along with the voucher batch settlement call. Inside `settleByVoucher`, the function loops through the delivery records and emits one `Deliver` event per request (subgraph-indexable, same shape as today). The cumulative voucher replaces the per-request signature; the per-request data is preserved for indexing.

Gas after the fix:
- O(M) ecrecover, one per requester (not per request)
- O(N) Deliver events, but events are cheap (~5-10k gas each, vs ~50k for ecrecover + SSTORE)
- O(M) storage writes for `mapChannels[channelId].settled`

For 100 requests from one client: 1 ecrecover, 100 cheap events. For 100 requests across 50 clients: 50 ecrecovers, 100 cheap events. A meaningful reduction without losing subgraph visibility.

### B. Settlement race lets clients drain funds before the mech settles

**Problem.**

In plain mech-prepay (no encumbrance), the mech accepts a voucher off-chain, returns the result to the client at HTTP 200, then later attempts to settle on-chain. Between those moments the client can call `withdrawRequester` and empty `mapRequesterBalances`. The mech's settlement reverts with `InsufficientBalance`. The mech ate the cost of running the tool.

Per-request exposure is bounded by `maxDeliveryRate` (~$0.05). But across a high-volume mech, this becomes a denial-of-payment vector. Repeated, it's an attack on mech revenue.

**Fix.**

Lock funds BEFORE off-chain acceptance, not after. Introduce a channel concept that lives inside the existing BalanceTracker (no separate escrow contract).

Each `(payer, mech)` pair gets a channel record:
- **Deposit**: amount committed at open time
- **Settled**: cumulative already settled on-chain
- **Expiry**: timestamp after which the payer can force-close
- **Finalized flag**: set when the channel closes

The BalanceTracker also tracks per-requester encumbered total. Lifecycle:

- `openChannel(mech, deposit, expiry)`: payer commits `deposit` from `mapRequesterBalances` into `mapEncumberedAmount` and into the new channel. Funds are locked.
- `settleByVoucher(...)`: marketplace-only. Moves voucher delta from encumbered to `mapMechBalances[mech]`.
- `closeChannel(channelId, finalCumulative, finalSig)`: settles the last voucher, refunds residual to `mapRequesterBalances[payer]`, finalizes.
- `requestClose(channelId)` + `forceClose(channelId)` after `CLOSE_TIMEOUT` (24h): payer's safety valve.

`withdrawRequester` operates only on `mapRequesterBalances` (free portion), never on encumbered funds. The mech is guaranteed it can settle any voucher up to the channel's deposit cap.

The race is eliminated by construction.

### C. One bad voucher reverts the whole batch

**Problem.**

`deliverMarketplaceWithSignatures` is atomic. One bad signature in a batch reverts everything. In a multi-requester batch where 99 vouchers are valid and 1 is malformed, all 100 settlements fail. The mech has to identify the bad voucher off-chain, drop it, and resubmit.

A single misbehaving (or buggy) client can break a mech's entire settlement cycle.

**Fix.**

Per-voucher `try`/`catch` in the new marketplace batch settlement. Each voucher is settled inside its own try block; failures emit a `VoucherSettlementFailed` event and the loop continues.

The per-voucher `settleByVoucher` is reentrancy-guarded and idempotent on success (advances `mapChannels[channelId].settled`). A failure leaves the channel state unchanged. Bad vouchers are isolated; good ones still settle.

This is actually BETTER than MPP session's behavior, which doesn't specify fail-soft batching.

### D. Settlement is per-requester, not across requesters

**Problem.**

Even with cumulative vouchers, today's `deliverMarketplaceWithSignatures(requester, ...)` takes ONE `requester` parameter. To settle vouchers from M different clients, the mech submits M separate transactions. For 50 active clients in a 5-minute window, that's 50 transactions instead of 1.

**Fix.**

`settleBatchByVouchers(PrepayVoucherInput[])` takes an array of vouchers, one entry per requester. Inside the loop (with try/catch from problem C), each `settleByVoucher` call debits the right channel's encumbrance and credits `mapMechBalances[mech]`. The delivery records ride with each voucher entry, so per-request Deliver events still fire correctly.

The mech submits ONE transaction with one voucher entry per active requester. Marketplace overhead amortizes across all of them.

For 1000 requests across 100 clients in a window: 1 transaction with 100 voucher entries inside it, 1000 Deliver events emitted, 100 voucher signature verifications.

---

## 4. Putting it together

### 4.1 EIP-712 voucher type

```
EIP-712 domain:
    name              = "Olas Mech Prepay Channel"
    version           = "1"
    chainId           = block.chainid
    verifyingContract = BalanceTracker address

EIP-712 type:
    PrepayVoucher(
        address mech,
        address requester,
        bytes32 channelId,
        uint128 cumulativeAmount
    )
```

Bound to a specific channel via `channelId`. Inherits the channel's `expiry`.

### 4.2 Settlement input shape

The marketplace's `settleBatchByVouchers` takes an array of:

```
PrepayVoucherInput {
    requester:       client address (signer of the voucher)
    channelId:       bytes32 identifying the channel
    cumulativeAmount: latest signed cumulative
    voucherSig:      EIP-712 signature
    deliveries:      array of per-request records, each with:
                        requestData (for Deliver event)
                        deliveryData (the result, for Deliver event)
                        deliveryRate (per-request charge)
}
```

Inside `settleByVoucher` on the BalanceTracker:
- Verify voucher signature once
- Verify `sum(deliveries[i].deliveryRate) == cumulativeAmount - prevSettled`
- Loop through deliveries: emit one `Deliver` event per record (subgraph-indexable)
- Move the delta from encumbered to `mapMechBalances[mech]`
- Update `mapChannels[channelId].settled = cumulativeAmount`

This keeps per-request Deliver events on-chain while concentrating the expensive signature verification to one ecrecover per requester.

### 4.3 New contract layout

`BalanceTrackerFixedPriceTokenChannel` (subclass of `BalanceTrackerFixedPriceToken`). Adds:

- Mappings: `mapChannels`, `mapEncumberedAmount`
- Events: `ChannelOpened`, `VoucherSettled`, `Deliver` (per-request), `ChannelCloseRequested`, `ChannelClosed`
- Functions: `openChannel`, `settleByVoucher` (marketplace-only), `closeChannel`, `requestClose`, `forceClose`
- Custom errors: `ChannelAlreadyOpen`, `ChannelNotOpen`, `ChannelFinalized`, `VoucherExpired`, `NonMonotonicCumulative`, `ExceedsDeposit`, `InvalidVoucherSignature`, `RateMismatch`, `CloseNotRequested`, `CloseTimeoutNotReached`, `PastExpiry`
- EIP-712 domain + voucher digest helper
- `CLOSE_TIMEOUT` constant (24 hours)

Inherits unchanged: `deposit`, `depositFor`, `withdrawRequester`, `adjustMechRequesterBalances` (legacy path), `processPaymentByMultisig`, fee logic.

### 4.4 Marketplace addition

One new function `settleBatchByVouchers(PrepayVoucherInput[])` with per-voucher try/catch. New event `MarketplaceVoucherSettlement`. No changes to existing marketplace functions.

### 4.5 OlasMech addition

One forwarder function `settleBatchByVouchers`, `onlyOperator`.

### 4.6 Registration

```
mechMarketplace.setPaymentTypeBalanceTrackers(
    [keccak256("MECH_PREPAY_CHANNEL_USDC")],
    [BalanceTrackerFixedPriceTokenChannel_address]
);
```

Distinct payment type from the existing `FixedPriceTokenUSDC`. Mechs that want the new behavior deploy with this payment type. Existing mechs keep working unchanged.

---

## 5. End-to-end flow

```
Phase 1, one-time deposit (existing mech-prepay)
────────────────────────────────────────────────
Client EOA / Safe
   USDC.approve(BalanceTracker, X)
   BalanceTracker.depositFor(client, X)         ────▶ mapRequesterBalances[client] += X


Phase 2, open a channel with a specific mech
────────────────────────────────────────────
Client EOA / Safe
   BalanceTracker.openChannel(mech, deposit=Y, expiry=now+24h)
                                                ────▶ moves Y from mapRequesterBalances
                                                       to mapEncumberedAmount (locked)
                                                ────▶ mapChannels[channelId] stored
                                                ────▶ ChannelOpened event


Phase 3, off-chain request loop (no on-chain activity per request)
──────────────────────────────────────────────────────────────────
For each request:
   Client → POST /predict { tool, prompt }
   Mech → HTTP 402 { scheme: "olas-prepay-voucher", channelId,
                     eip712_domain, current_cumulative, would_be_cumulative }
   Client signs PrepayVoucher(mech, client, channelId, new_cumulative)
   Client → POST /predict { ..., voucher: {cumulative, sig} }
   Mech verifies sig + monotonicity + cumulative ≤ channel.deposit
   Mech runs tool, returns HTTP 200 { result, accepted_cumulative }
   Mech persists in synchronized_data:
      latestVoucher[(client, mech)] = {cumulative, sig}
      pending delivery records list (requestData, deliveryData, rate per request)


Phase 4, batched on-chain settlement with fail-soft + per-request events
────────────────────────────────────────────────────────────────────────
Mech Safe accumulates latest voucher + delivery records per active pair.
Once per batch window:

   OlasMech.settleBatchByVouchers([
      { requester, channelId, cumulative, deliveries: [N records], sig },
      { requester, channelId, cumulative, deliveries: [N records], sig },
      ...
   ])

   ────▶ MechMarketplace.settleBatchByVouchers
         for each voucher (in try/catch):
            BalanceTracker.settleByVoucher(...)
               verify sig, monotonicity, ≤ deposit, not finalized
               verify sum(deliveries[i].rate) == cumulative - settled
               for each delivery record:
                  emit Deliver event   ◀── subgraph-indexable
               delta = cumulative - settled
               mapEncumberedAmount[requester] -= delta
               mapMechBalances[mech] += delta
               mapChannels[channelId].settled = cumulative
               emit VoucherSettled
            on failure: emit VoucherSettlementFailed, continue
         aggregate karma + counters for successful ones
         emit MarketplaceVoucherSettlement


Phase 5, channel close
──────────────────────
Happy path (mech-initiated):
   Mech Safe → BalanceTracker.closeChannel(channelId, finalCumulative, finalSig)
                                                ────▶ settles last voucher
                                                ────▶ refunds residual back to
                                                       mapRequesterBalances[client]
                                                ────▶ marks finalized
                                                ────▶ ChannelClosed event

Safety path (payer-initiated, if mech goes silent):
   Client → requestClose(channelId)             emits ChannelCloseRequested
   wait CLOSE_TIMEOUT (24h)
   Client → forceClose(channelId)               refunds residual, marks finalized


Phase 6, withdraw free balance
──────────────────────────────
Client → BalanceTracker.withdrawRequester(amount)
                                                ────▶ operates only on mapRequesterBalances
                                                       (encumbered portion is untouchable)
```

The race is gone. The atomic batch is gone. Per-request Deliver events stay. Settlement is one transaction per batch window across all active requesters.

---

## 6. Worked example

Setup:
- Alice deposits $1.00 into the BalanceTracker. `mapRequesterBalances[Alice] = 1_000_000`.
- Mech rate: $0.01 per request. Quote: 10_000 atomic units.
- Alice opens a channel: `openChannel(mech, 500_000, now+24h)`.
  - `mapRequesterBalances[Alice]` = 500_000 (free)
  - `mapEncumberedAmount[Alice]` = 500_000 (locked in channel)
  - `mapChannels[cA].deposit = 500_000, settled = 0`

15 minutes pass, Alice makes 8 requests off-chain:
- Each request signs voucher with cumulative 10_000, 20_000, ..., 80_000
- 0 on-chain transactions
- Mech stores latest voucher + the 8 delivery records in `synchronized_data`

During these 15 minutes Alice tries to drain her wallet:
- `withdrawRequester(500_000)` succeeds. She gets her free balance back.
- She CANNOT touch the 500_000 in the channel.
- Mech still safely holds claim to up to 500_000 via accepted vouchers.

At batch boundary, mech submits:

```
settleBatchByVouchers([
  { requester: Alice, channelId: cA, cumulative: 80_000,
    deliveries: [8 records, each with rate 10_000], sig: sig_8 }
])
```

Inside the contract:
- Voucher signature verified ✓
- `cumulative (80_000) > settled (0)` ✓
- `cumulative (80_000) ≤ deposit (500_000)` ✓
- `sum(deliveries[i].rate) = 80_000 == cumulative - settled (80_000)` ✓
- 8 `Deliver` events emitted, one per request (subgraph picks them up)
- delta = 80_000
- `mapEncumberedAmount[Alice]` -= 80_000 (now 420_000)
- `mapMechBalances[mech]` += 80_000
- `mapChannels[cA].settled = 80_000`
- 1 `VoucherSettled` event
- Karma + counters for Alice

Alice continues. Eventually one party closes:
- `closeChannel(cA, 92_000, latest_sig)` settles last voucher (delta 12_000 with 1 more Deliver event), refunds 408_000 back to `mapRequesterBalances[Alice]`.

Total on-chain transactions for 9 requests: 1 deposit + 1 openChannel + 1 batched settle (with 9 Deliver events inside) + 1 closeChannel = 4 transactions.

Now imagine 50 clients doing similar:
- 50 deposits + 50 openChannels (one-time, per client)
- **1 batched settle** covering vouchers from all 50 clients (per batch window) with N Deliver events
- 50 closeChannels (one-time, when done)

Per-batch settlement work for the mech: 1 transaction. That is the scaling property.

---

## 7. Full end-to-end changes required

This section lists every change across the stack. No code, just what changes where.

### 7.1 Contract side (autonolas-marketplace repo)

**New file**: `contracts/mechs/token/prepay/BalanceTrackerFixedPriceTokenChannel.sol`

Subclass of `BalanceTrackerFixedPriceToken`. Adds channel custody and voucher settlement entirely inside the BalanceTracker. No separate escrow contract.

What it adds:
- Per-channel storage struct (payer, mech, deposit, settled, expiry, closeRequestedAt, finalized) keyed by channelId
- Per-requester encumbered total mapping
- Five new external functions: `openChannel`, `settleByVoucher` (marketplace-only), `closeChannel`, `requestClose`, `forceClose`
- EIP-712 domain and voucher digest helpers
- Custom errors covering channel lifecycle states and voucher validation
- Events: `ChannelOpened`, `VoucherSettled`, `Deliver` (per request, inside the voucher settlement), `ChannelCloseRequested`, `ChannelClosed`
- `CLOSE_TIMEOUT` constant (24 hours)

What it inherits unchanged from the base:
- `deposit`, `depositFor`, `withdrawRequester` (operates on free portion of `mapRequesterBalances` only)
- `adjustMechRequesterBalances` (legacy per-request-signature path coexists)
- `processPaymentByMultisig`, fee logic, drain

**Modified file**: `contracts/MechMarketplace.sol`

One new function `settleBatchByVouchers(PrepayVoucherInput[])` that wraps each voucher's settlement in `try`/`catch`. Successful settlements get per-requester karma + counter updates; failed ones emit `VoucherSettlementFailed`. After the loop, aggregate karma + counter updates for the mech.

New event: `MarketplaceVoucherSettlement`. No changes to existing marketplace functions.

**Modified file**: `contracts/OlasMech.sol`

One new forwarder function `settleBatchByVouchers` (onlyOperator) that calls the marketplace.

**New file**: `contracts/interfaces/IBalanceTrackerChannel.sol`

New interface variant exposing `settleByVoucher` and the channel-lifecycle entry points.

**Registration call (one-time)**:
- Register the new BalanceTracker against the new payment type `keccak256("MECH_PREPAY_CHANNEL_USDC")`
- Mechs that want the new behavior deploy with this payment type
- Existing mechs continue working unchanged

**Audit boundary**: one new contract. The marketplace and OlasMech changes are small forwarders that audit alongside their existing functions.

Effort estimate: ~500 lines of Solidity across contracts, plus an audit cycle.

### 7.2 Mech side (mech repo)

**Modified file**: `mech/packages/valory/skills/task_execution/handlers.py`

Two new HTTP routes added to `MechHttpHandler`:

- `POST /open_channel_hint`: client asks for the data needed to construct an `openChannel` transaction. Mech responds with channelId derivation parameters, recommended deposit, EIP-712 domain.
- `POST /submit_voucher`: voucher-bearing request submission. Body contains `tool`, `prompt`, IPFS data, and voucher `{channelId, cumulativeAmount, signature}`. Mech verifies the EIP-712 voucher off-chain, checks the cumulative is strictly greater than the stored value, checks cumulative is within the channel deposit, then enqueues the task and returns 200.

The existing `POST /send_signed_requests` route (per-request signatures) stays for the legacy path. The existing `GET /fetch_offchain_info` polling endpoint stays unchanged.

A new helper `_verify_voucher` ports `wildcard/server/src/session/voucher.py:verify_voucher` into the mech behaviour.

**Modified file**: `mech/packages/valory/skills/task_submission_abci/behaviours.py`

New behaviour branch that:
- Reads pending voucher acceptance log + delivery records from `synchronized_data`
- Groups by `(requester, mech)`, keeps only the latest voucher per pair, retains the per-request delivery records
- Builds the `PrepayVoucherInput[]` array (each entry includes delivery records)
- Submits via `OlasMech.settleBatchByVouchers`

Coexists with the existing per-request signature batching. Mech operator chooses per batch which path to use (configurable).

**Modified module**: `synchronized_data` slot definitions

New slots:
- Per active channel: `{channelId, payer, mech, deposit, expiry, highestAcceptedCumulative, lastSettledOnChain, latestVoucherSig}`
- Pending voucher acceptance log: list of `(request_id, channel_id, cumulative, accepted_at, delivery_record)`

Survives agent restarts. Consistent across the agent ensemble.

**Optional**: Postgres adapter for durable delivery records outside `synchronized_data`. Useful for long-lived production deployments that want to query historical deliveries beyond the current synchronized state. NOT required for v1 — `synchronized_data` plus on-chain `Deliver` events (subgraph-indexable) cover the primary use cases.

Effort estimate: ~500 lines of new behaviour + handler code.

### 7.3 mech-client (the Python CLI / library)

**Already there**: mech-client has the off-chain HTTP path built (see Section 2.3). `_send_offchain_request` signs request data and POSTs to `/send_signed_requests`. `OffchainDeliveryWatcher` polls for the result. `--use-offchain` CLI flag exists.

**What to add**:

A parallel `_send_voucher_request` method that:
- Discovers the mech HTTP endpoint
- On the first request to a given mech: fetches the channel-open hint via `POST /open_channel_hint`, submits an `openChannel` transaction
- Tracks local channel state per-mech in a local file (e.g. `~/.mech-client/channels.json`)
- Signs the next voucher with cumulative bumped, POSTs to `/submit_voucher`
- On 402 with `scheme: "olas-prepay-voucher"`: parses the voucher hint, signs the next voucher, retries
- Polls for result via the existing `OffchainDeliveryWatcher`

New CLI commands:
- `mech-client open-channel --mech <addr> --deposit <amount> --expiry <hours>`
- `mech-client close-channel --channel-id <id>`
- `mech-client request-close --channel-id <id>`
- `mech-client withdraw --amount <X>`

New CLI flag `--use-voucher` opts into the voucher path. Existing flags unchanged.

Effort estimate: ~400 lines of new service code + CLI command wiring.

### 7.4 mech-interact (the ABCI skill used by Trader, Market-Creator, etc.)

**Today's flow**: purely on-chain `MechMarketplace.request()` per request. No HTTP off-chain branch (see Section 2.4).

**What to add**:

A new behaviour `MechVoucherChannelBehaviour` (or extension of `MechRequestBehaviour`) that:
- Checks `synchronized_data` for an active channel with the priority mech
- If none: builds an approve + depositFor + openChannel multisend, submits, persists the channel id
- For the request: signs the next voucher with the safe key (EIP-712 typed data), POSTs to the mech's `/submit_voucher` endpoint via the existing AEA http connection
- On 402 with voucher hint: re-sign with the corrected cumulative and retry
- Updates `synchronized_data.channel_state` after each accepted voucher
- The response behaviour polls the mech's HTTP endpoint (or stays with on-chain Deliver-event polling as a fallback)

New params in `skill.yaml`:
- `mech_http_url`: explicit override of the mech's HTTP endpoint
- `prefer_voucher_path`: opt-in flag to use the new path
- `default_channel_deposit`: how much to lock per channel (e.g. $1.00)
- `default_channel_expiry_hours`: default 24

The existing on-chain request behaviour stays untouched. Services that don't opt in keep working the same way.

A closure behaviour is also needed for graceful service shutdown: at termination, close any active channels to recover residual deposit.

Effort estimate: ~400 lines of new behaviour code in mech-interact, plus tests.

### 7.5 Do we need a separate package?

Two questions here.

**For Valory's own clients (mech-client, mech-interact)**: no separate package. Both libraries already exist; we add a voucher branch to each.

**For third-party HTTP clients that aren't Python**: a thin TypeScript / JavaScript package is worth maintaining when there's an external consumer. Use cases:
- Browser-based agents
- Node.js / TypeScript services that want to call mechs without running open-autonomy
- Any client outside the Valory Python stack

What it would contain:
- ChannelId derivation (matches the contract's keccak256 layout)
- EIP-712 typed data signing for `PrepayVoucher`
- HTTP wire helpers: POST `/open_channel_hint`, `/submit_voucher`, GET `/fetch_offchain_info`
- 402 challenge parsing and retry logic
- Local channel state management (in-memory or pluggable storage)

Suggested name: `@valory/olas-prepay-client` (TypeScript, ~400-600 lines).

This package is NOT blocking for v1. mech-client and mech-interact cover all current Valory consumers. The TypeScript package is needed when external HTTP agents want to consume Olas mechs. Ship in v1.1 once there's a concrete external consumer.

**Future MPP protocol compatibility**: as Section 1 noted, going fully MPP-compatible later means adding an OpenAPI doc, MPP-shaped HTTP headers, and a TypeScript adapter that speaks the MPP wire. If we ship `@valory/olas-prepay-client` for the case above, that same package can grow into the MPP-compatibility layer when needed.

Recommended sequencing:
- v1: contracts + mech + mech-client + mech-interact. No TypeScript package yet.
- v1.1: `@valory/olas-prepay-client` when a non-Python consumer shows up, or when MPP-protocol compatibility becomes a priority.

---

## 8. Contract change summary

| Component | Change | Notes |
|-----------|--------|-------|
| `BalanceTrackerFixedPriceTokenChannel` | NEW subclass | Channels + voucher settlement + Deliver events, ~300 lines |
| `MechMarketplace.sol` | Add `settleBatchByVouchers` + event | Per-voucher try/catch, additive |
| `OlasMech.sol` | Add `settleBatchByVouchers` forwarder | `onlyOperator` |
| `IBalanceTrackerChannel.sol` | New interface | Or extend the existing IBalanceTracker |
| `BalanceTrackerBase` | None | All hooks present |
| `BalanceTrackerFixedPriceToken` | None | Parent class, unchanged |
| Karma | None | Receives per-requester + aggregate updates |
| Fee logic (`processPaymentByMultisig`) | None | Operates on `mapMechBalances` as today |
| Existing payment families (Native, Token, NVM) | None | All untouched, coexist via registry |
| `BalanceTrackerX402` (if ever shipped) | None | Coexists, different payment type |
| `MppEscrow` (if ever shipped) | None | Coexists, different payment type |

The existing marketplace and OlasMech keep all their existing functions. The voucher path is strictly additive.

---

## 9. Known constraints

What remains, honestly:

- **Channel deposit upfront**. Locking USDC in a channel is the cost of race elimination. For one-shot clients, the legacy per-request flow is cheaper.
- **One channel per `(payer, mech)` pair**. A client talking to N mechs opens N channels.
- **Channel expiry**. Recommended 24 hours.
- **Mech operator submits batches**. Same trust model as today's mech Safe ops. No new keys.
- **Strict monotonicity on-chain**. Two concurrent settlement attempts for the same cumulative: one wins, the other emits `VoucherSettlementFailed`. Mech reconciles off-chain.

What's NOT a constraint anymore:

- ~~Settlement race~~ eliminated by encumbrance
- ~~Atomic batch revert~~ eliminated by per-voucher try/catch
- ~~Per-requester-only batching~~ multi-requester is built into `settleBatchByVouchers`
- Per-request on-chain records still emitted (Deliver events per delivery), subgraph keeps working

---

## 10. Comparison vs MPP session

Behaviorally identical after this spec ships. Differences are structural and external-compatibility:

| Aspect | This spec | MPP session |
|--------|-----------|-------------|
| Custody contract | BalanceTracker (existing) | MppEscrow (new) |
| Channel state location | `mapChannels` inside BalanceTracker | `channels` inside MppEscrow |
| Voucher EIP-712 domain | `Olas Mech Prepay Channel` | `Tempo Stream Channel` (or equivalent) |
| Cumulative monotonicity | Enforced on-chain | Enforced on-chain |
| Settlement race | Eliminated | Eliminated |
| Atomic batch revert | Eliminated (try/catch) | Not addressed in MPP spec |
| Per-request on-chain records | Yes (Deliver events from settleByVoucher) | No |
| Subgraph indexable | Yes | No |
| Audit boundary | 1 contract | 2 contracts |
| MPP protocol compatibility | None | Partial (Valory extension of session intent on EVM) |

Given that MPP protocol compatibility isn't a goal for v1, this spec is the cleaner path. Same outcome, smaller audit surface, and we keep subgraph-indexable per-request data.

---

## 11. Testing strategy

### 11.1 Contract tests

1. **Happy path**: open → 5 vouchers off-chain → batched settle → close. Balances correct end-to-end. 5 Deliver events emitted in the settle tx.
2. **Encumbrance enforcement**: open channel for 500_000, try `withdrawRequester(amount > free)`, expect revert.
3. **Voucher monotonicity**: settle cumulative=100, try cumulative=100 again, expect `NonMonotonicCumulative` event from try/catch.
4. **Exceeds deposit**: voucher with `cumulative > channel.deposit`, expect `ExceedsDeposit` event.
5. **Rate mismatch**: `sum(deliveries[i].rate) != cumulative - settled`, expect `RateMismatch` event.
6. **Channel expiry**: voucher submitted after expiry, expect `VoucherExpired` event.
7. **Forged signature**: voucher signed by attacker, expect `InvalidVoucherSignature` event.
8. **Finalized channel**: settle after `closeChannel` called, expect `ChannelFinalized` event.
9. **`forceClose` timeout**: try `forceClose` before `CLOSE_TIMEOUT` elapsed, expect revert.
10. **Fail-soft batch**: 5 vouchers, 1 expired. 4 succeed, 1 emits failure event. Transaction completes. `mapMechBalances` reflects only the 4. Verify total Deliver event count matches successful deliveries.
11. **Multi-requester**: 50 vouchers from 50 different requesters in one batch. All settle independently.
12. **Fee accounting**: `processPaymentByMultisig` works on accumulated `mapMechBalances` after voucher settlement.
13. **Reentrancy**: malicious token reenters during `transfer`, blocked by `_locked`.
14. **Multi-mech**: Alice opens channels with Mech A and Mech B, both settle independently, encumbrance tracks each.

### 11.2 End-to-end integration

1. Hardhat fork with USDC + new contracts deployed
2. mech-client `--use-voucher`: opens channel, sends 5 requests, mech batches, channel closes
3. Verify events: `ChannelOpened`, 5 `Deliver` events, 1 `VoucherSettled`, 1 `MarketplaceVoucherSettlement`, `ChannelClosed`
4. Subgraph reads the 5 Deliver events as if they came from the legacy flow
5. Verify final `mapRequesterBalances[client]` includes the refunded residual

### 11.3 Adversarial tests

1. **Race elimination**: client `withdrawRequester` after voucher acceptance, before settle. Withdraw bounded to free balance. Mech successfully settles the encumbered amount.
2. **Fail-soft**: 100-voucher batch with 10 bad vouchers randomly placed. 90 settle, 10 emit failure events. Tx succeeds.

---

## 12. References

- `docs/mpp_session_spec.md`, the structural alternative using a separate escrow contract
- `docs/x402_spec.md`, the per-request EIP-3009 alternative
- `docs/x402_vs_mpp.md`, decision guide between the ecosystem options
- `wildcard/server/src/session/store.py`, the per-channel state-tracking pattern this spec mirrors
- `wildcard/server/src/session/voucher.py`, the EIP-712 voucher verification reference
- `mech-client/mech_client/services/marketplace_service.py:243-356`, the existing HTTP off-chain integration that gets the voucher branch
- `mech-interact/packages/valory/skills/mech_interact_abci/behaviours/request.py`, the on-chain-only behaviour that gets the new voucher branch
- `mech/packages/valory/skills/task_execution/handlers.py:518`, the off-chain HTTP handler that gets the new voucher routes
- `mech/packages/valory/skills/task_submission_abci/behaviours.py:1580`, the batched settlement behaviour that gets the new voucher-path branch
- `contracts/MechMarketplace.sol:206-285`, the existing per-request signature path
- `contracts/mechs/token/BalanceTrackerFixedPriceToken.sol`, the parent class of the new BalanceTracker subclass
- [MPPscan discovery spec](https://www.mppscan.com/discovery/spec), for the optional future MPPscan listing
