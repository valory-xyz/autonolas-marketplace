# Mech Prepay Specification

## 1. How far are we from MPP, and what this spec closes

After shipping this spec, mech-prepay becomes functionally MPP session inside the BalanceTracker. The behavioral gap closes completely. The remaining differences are structural and external-compatibility.

| Property | mech-prepay today (pre-deposit only) | This spec | MPP session |
|----------|---------------------------------------|-----------|-------------|
| Cumulative voucher signing | No (per-request signatures) | **Yes** | Yes |
| Funds locked against withdraw | No (race exists) | **Yes (encumbered channels)** | Yes (escrow contract) |
| Settlement race | Exists (bounded by maxRate) | **Eliminated** | Eliminated |
| Atomic batch revert (one bad voucher kills all) | Yes (DOS risk) | **No (fail-soft try/catch)** | Yes (not addressed in MPP spec) |
| Per-request on-chain records | Yes (N events per batch) | **No (Postgres on mech side)** | No |
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
- Postgres-backed mech-side response store (mirrors `wildcard/server/src/session/store.py`)
- mech-client and mech-interact voucher branches

Total new code: ~2000 lines across contracts, mech, and clients. One new audit boundary (the BalanceTracker subclass).

---

## 2. The design, problem by problem

Five distinct problems with today's mech-prepay. Each has its own targeted fix.

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

At roughly 50,000 gas per iteration, a 50-request batch from one client burns ~2.5M gas just on this loop, before the actual balance accounting. Multiply by M distinct clients per batch window and on-chain settlement dominates everything else.

**Fix.**

Replace per-request signatures with one cumulative voucher per `(requester, mech)` pair per batch period. The client signs ONE EIP-712 typed message authorizing a `cumulativeAmount`. Each new request bumps the cumulative. The mech keeps only the latest voucher per pair off-chain. On settlement, the BalanceTracker verifies ONE signature, checks monotonicity, and debits the delta.

For 100 off-chain requests from one client: one signature on-chain, one storage write, one balance update. Constant cost regardless of N.

For 100 requests across 50 clients: 50 signatures total, not 100. Linear in distinct requesters, not in total requests.

This is the core scaling unlock. Everything else builds on it.

### B. Settlement race lets clients drain funds before the mech settles

**Problem.**

In plain mech-prepay (no encumbrance), the mech accepts a voucher off-chain, returns the result to the client at HTTP 200, then later attempts to settle on-chain. Between those moments the client can call `withdrawRequester` and empty `mapRequesterBalances`. The mech's settlement reverts with `InsufficientBalance`. The mech ate the cost of running the tool.

Per-request exposure is bounded by `maxDeliveryRate` (~$0.05). But across a high-volume mech, this becomes a denial-of-payment vector. A client can submit a request, wait for the result, then sweep their balance before the batch cycle. Repeated, it's an attack on mech revenue.

**Fix.**

Lock funds BEFORE the off-chain acceptance, not after. Introduce a channel concept that lives inside the existing BalanceTracker (no separate escrow contract).

Each `(payer, mech)` pair gets a channel record:

- **Deposit**: the locked amount committed to this channel at open time
- **Settled**: cumulative already settled on-chain via vouchers
- **Expiry**: timestamp after which the payer can force-close
- **Finalized flag**: set when the channel closes

The BalanceTracker also tracks per-requester encumbered total. The lifecycle:

- `openChannel(mech, deposit, expiry)`: payer commits `deposit` from `mapRequesterBalances` into `mapEncumberedAmount` and into the new channel. Funds are locked.
- `settleByVoucher(...)`: marketplace-only. Moves voucher delta from encumbered to `mapMechBalances[mech]`.
- `closeChannel(channelId, finalCumulative, finalSig)`: settles the last voucher, refunds residual back to `mapRequesterBalances[payer]`, finalizes.
- `requestClose(channelId)` + `forceClose(channelId)` after `CLOSE_TIMEOUT` (24h): payer's safety valve if the mech goes silent.

`withdrawRequester` operates only on `mapRequesterBalances` (the free portion), never on encumbered funds. The mech is guaranteed it can settle any voucher up to the channel's deposit cap.

The race is eliminated by construction. Same property MPP gives via its escrow.

### C. One bad voucher reverts the whole batch

**Problem.**

`deliverMarketplaceWithSignatures` is atomic. One bad signature in a batch reverts everything. In a multi-requester batch where 99 vouchers are valid and 1 is malformed (expired, insufficient deposit, bad signature), all 100 settlements fail. The mech has to identify the bad voucher off-chain, drop it, and resubmit.

A single misbehaving (or buggy) client can break a mech's entire settlement cycle. Real DOS vector.

**Fix.**

Per-voucher `try`/`catch` in the new marketplace batch settlement. Each voucher is settled inside its own try block; failures emit a `VoucherSettlementFailed` event and the loop continues to the next voucher.

The per-voucher `settleByVoucher` is reentrancy-guarded and idempotent on success (advances `mapChannels[channelId].settled`). A failure leaves the channel state unchanged. Bad vouchers are isolated; good ones still settle.

This is actually BETTER than MPP session's behavior, which doesn't specify fail-soft batching.

### D. Per-request on-chain records add bloat for no benefit

**Problem.**

Today every delivery emits a `Deliver` event and stores a `RequestInfo` struct in `mapRequestIdInfos[requestId]`. For high-volume mechs that's a lot of on-chain state and event emissions purely to record "this request was delivered."

Subgraph indexers consume these events for delivery tracking. But HTTP-style paid-API clients already poll the mech's HTTP endpoint for results. They don't read the subgraph. So the on-chain delivery records are paid-for-but-unused for this access pattern.

**Fix.**

Drop per-request on-chain records. Persist delivery data on the mech side using the wildcard pattern (`wildcard/server/src/session/store.py`).

Two layers of mech-side storage:

**Layer 1, `synchronized_data`** (already exists in open-autonomy):
- Channel state per active `(requester, mech)` pair: channelId, deposit, expiry, highestAcceptedCumulative, lastSettledOnChain, latestVoucherSig
- Pending voucher acceptance log waiting for next batch settlement
- Survives agent restart, consistent across the ensemble

**Layer 2, optional Postgres** for delivery results (recommended for production):

```sql
CREATE TABLE prepay_requests (
    request_id TEXT PRIMARY KEY,
    requester TEXT NOT NULL,
    channel_id TEXT NOT NULL,
    cumulative_at_acceptance NUMERIC NOT NULL,
    ipfs_hash_of_result TEXT,
    accepted_at TIMESTAMP NOT NULL,
    settled_on_chain_at TIMESTAMP
);
CREATE INDEX idx_prepay_requester ON prepay_requests(requester);
CREATE INDEX idx_prepay_channel ON prepay_requests(channel_id);
```

Mirrors wildcard's production schema.

On-chain events in the voucher path:
- `ChannelOpened` (one per channel open)
- `VoucherSettled` (one per successful voucher in a batch)
- `VoucherSettlementFailed` (one per failed voucher in a batch)
- `MarketplaceVoucherSettlement` (one per batch)
- `ChannelClosed` (one per channel close)

No per-request `Deliver` event. Clients fetch results via the existing HTTP `GET /fetch_offchain_info` endpoint.

### E. Settlement is per-requester, not across requesters

**Problem.**

Even with cumulative vouchers, today's `deliverMarketplaceWithSignatures(requester, ...)` takes one `requester` parameter. To settle vouchers from M different clients, the mech submits M separate transactions. For 50 active clients in a 5-minute window, that's 50 transactions instead of 1. The marketplace overhead (mech check, paymentType lookup, balance tracker resolution) repeats 50 times.

**Fix.**

`settleBatchByVouchers` takes an array of vouchers, one entry per requester. Inside the loop (with try/catch from problem C), each `settleByVoucher` call debits the right channel's encumbrance and credits `mapMechBalances[mech]`.

The mech submits ONE transaction with one voucher entry per active requester. Marketplace overhead amortizes across all of them.

For 1000 requests across 100 clients in a window: 1 transaction with 100 voucher entries inside it.

---

## 3. Putting it together

### 3.1 EIP-712 voucher type

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

The voucher is bound to a specific channel via `channelId`. The channel itself carries `expiry`; the voucher inherits it.

### 3.2 New contract: BalanceTrackerFixedPriceTokenChannel

Subclass of `BalanceTrackerFixedPriceToken`. Adds:

- Mappings: `mapChannels` (channel state by id), `mapEncumberedAmount` (per-requester locked total)
- Events: `ChannelOpened`, `VoucherSettled`, `ChannelCloseRequested`, `ChannelClosed`
- Functions: `openChannel`, `settleByVoucher` (marketplace-only), `closeChannel`, `requestClose`, `forceClose`
- Custom errors: `ChannelAlreadyOpen`, `ChannelNotOpen`, `ChannelFinalized`, `VoucherExpired`, `NonMonotonicCumulative`, `ExceedsDeposit`, `InvalidVoucherSignature`, `CloseNotRequested`, `CloseTimeoutNotReached`, `PastExpiry`
- EIP-712 helper for the voucher digest

Inherits unchanged from the base: `deposit`, `depositFor`, `withdrawRequester`, `processPaymentByMultisig`, fee logic.

`CLOSE_TIMEOUT` constant set to 24 hours.

### 3.3 Marketplace addition

One new function: `settleBatchByVouchers(PrepayVoucherInput[])`. Wraps each voucher's settlement in `try`/`catch`. On success, does per-requester karma + counter updates. On failure, emits `VoucherSettlementFailed` and continues. After the loop, does aggregate karma + counter updates for the mech using the totalSuccessfulRequests count.

### 3.4 OlasMech addition

One forwarder function, `onlyOperator`, that calls `MechMarketplace.settleBatchByVouchers`.

### 3.5 Registration

```
mechMarketplace.setPaymentTypeBalanceTrackers(
    [keccak256("MECH_PREPAY_CHANNEL_USDC")],
    [BalanceTrackerFixedPriceTokenChannel_address]
);
```

Distinct payment type from the existing `FixedPriceTokenUSDC`. Mechs that want the new behavior deploy with this payment type. Existing mechs keep working unchanged.

---

## 4. End-to-end flow

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


Phase 3, off-chain request loop (no on-chain activity)
──────────────────────────────────────────────────────
For each request:
   Client → POST /predict { tool, prompt }
   Mech → HTTP 402 { scheme: "olas-prepay-voucher", channelId,
                     eip712_domain, current_cumulative, would_be_cumulative }
   Client signs PrepayVoucher(mech, client, channelId, new_cumulative)
   Client → POST /predict { ..., voucher: {cumulative, sig} }
   Mech verifies sig + monotonicity + cumulative ≤ channel.deposit
   Mech runs tool, returns HTTP 200 { result, accepted_cumulative }
   Mech persists:
      synchronized_data: latestVoucher[(client, mech)] = {cumulative, sig}
      Postgres: (request_id, client, channelId, cumulative, ipfs_hash, now)


Phase 4, batched on-chain settlement with fail-soft
───────────────────────────────────────────────────
Mech Safe accumulates latest voucher per active (requester, mech).
Once per batch window:

   OlasMech.settleBatchByVouchers([
      { requester, channelId, cumulative, count, sig },
      { requester, channelId, cumulative, count, sig },
      ...
   ])

   ────▶ MechMarketplace.settleBatchByVouchers
         for each voucher (in try/catch):
            BalanceTracker.settleByVoucher(...)
               verify sig, monotonicity, ≤ deposit, not finalized
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
                                                ────▶ refunds (deposit - finalCumulative)
                                                       back to mapRequesterBalances[client]
                                                ────▶ marks finalized
                                                ────▶ ChannelClosed event

Safety path (payer-initiated, if mech goes silent):
   Client → requestClose(channelId)             emits ChannelCloseRequested
   wait CLOSE_TIMEOUT (24h)
   Client → forceClose(channelId)               refunds residual, marks finalized


Phase 6, withdraw free balance (existing mech-prepay)
─────────────────────────────────────────────────────
Client → BalanceTracker.withdrawRequester(amount)
                                                ────▶ operates only on mapRequesterBalances
                                                       (encumbered portion is untouchable)
```

The race is gone. The atomic batch is gone. Per-request on-chain records are gone. Settlement is one transaction per batch window across all active requesters.

---

## 5. Worked example

Setup:
- Alice deposits $1.00 into the BalanceTracker. `mapRequesterBalances[Alice] = 1_000_000`.
- Mech rate: $0.01 per request. Quote: 10_000 atomic units.
- Alice opens a channel: `openChannel(mech, 500_000, now+24h)`.
  - `mapRequesterBalances[Alice]` becomes 500_000 (free)
  - `mapEncumberedAmount[Alice]` becomes 500_000 (locked in channel)
  - `mapChannels[cA].deposit = 500_000, settled = 0`

15 minutes pass, Alice makes 8 requests off-chain:
- Each request signs voucher with cumulative 10_000, 20_000, ..., 80_000
- 0 on-chain transactions
- Mech persists results in Postgres
- Mech holds latest voucher off-chain: `{cumulative: 80_000, sig: sig_8}`

During these 15 minutes Alice tries to drain her wallet:
- `withdrawRequester(500_000)` succeeds. She gets her free balance back.
- She CANNOT touch the 500_000 in the channel. Encumbered.
- Mech still safely holds claim to up to 500_000 via accepted vouchers.

At the batch boundary, mech submits:

```
settleBatchByVouchers([
  { requester: Alice, channelId: cA, cumulative: 80_000, count: 8, sig: sig_8 }
])
```

Inside the contract:
- Voucher sig verified
- `cumulative (80_000) > settled (0)` ✓
- `cumulative (80_000) ≤ deposit (500_000)` ✓
- delta = 80_000
- `mapEncumberedAmount[Alice]` -= 80_000 (now 420_000)
- `mapMechBalances[mech]` += 80_000
- `mapChannels[cA].settled = 80_000`
- Karma + counters for Alice
- One `VoucherSettled` event

Alice continues. Eventually one party closes:
- `closeChannel(cA, 92_000, latest_sig)` settles the last voucher (delta 12_000), refunds 408_000 back to `mapRequesterBalances[Alice]`.

Total on-chain transactions for 9 requests: 1 deposit + 1 openChannel + 1 batched settle + 1 closeChannel = 4 transactions, regardless of how many requests fit in the channel window.

Now imagine 50 clients doing similar:
- 50 deposits (each client, one-time)
- 50 openChannels (each client, one-time per channel)
- **1 batched settle** covering vouchers from all 50 clients (per batch window)
- 50 closeChannels (each client, one-time when done)

Per-batch settlement work for the mech: 1 transaction. That is the scaling property.

---

## 6. Full end-to-end changes required

This section lists every change across the stack. No code, just what changes where.

### 6.1 Contract side (autonolas-marketplace repo)

**New file**: `contracts/mechs/token/prepay/BalanceTrackerFixedPriceTokenChannel.sol`

A subclass of `BalanceTrackerFixedPriceToken`. Adds channel custody and voucher settlement entirely inside the BalanceTracker. No separate escrow contract.

What it adds:
- Per-channel storage struct (payer, mech, deposit, settled, expiry, closeRequestedAt, finalized) keyed by channelId
- Per-requester encumbered total mapping
- Five new external functions: `openChannel`, `settleByVoucher` (marketplace-only), `closeChannel`, `requestClose`, `forceClose`
- EIP-712 domain and voucher digest helpers
- A set of custom errors covering channel lifecycle states and voucher validation
- A set of events: `ChannelOpened`, `VoucherSettled`, `ChannelCloseRequested`, `ChannelClosed`
- `CLOSE_TIMEOUT` constant (24 hours recommended)

What it inherits unchanged from the base:
- `deposit`, `depositFor`, `withdrawRequester` (free balance still works)
- `adjustMechRequesterBalances` (legacy per-request-signature path coexists)
- `processPaymentByMultisig`, fee logic, drain

**Modified file**: `contracts/MechMarketplace.sol`

One new function `settleBatchByVouchers(PrepayVoucherInput[])` that wraps each voucher's settlement in try/catch. Successful settlements get per-requester karma + counter updates; failed ones emit `VoucherSettlementFailed` and the loop continues. After the loop, aggregate karma + counter updates for the mech.

New event: `MarketplaceVoucherSettlement`.

No changes to any existing marketplace function. The new entry is strictly additive.

**Modified file**: `contracts/OlasMech.sol`

One new forwarder function `settleBatchByVouchers` (onlyOperator) that calls the marketplace.

**New file**: `contracts/interfaces/IBalanceTrackerChannel.sol`

New interface variant exposing `settleByVoucher` and the channel-lifecycle entry points. Or extend the existing IBalanceTracker.

**Registration call (one-time, by marketplace owner)**:
- Register the new BalanceTracker against the new payment type `keccak256("MECH_PREPAY_CHANNEL_USDC")`
- Mechs that want the new behavior deploy with this payment type
- Existing mechs continue working unchanged

**Audit boundary**: one new contract. The marketplace and OlasMech changes are small forwarders that audit alongside their existing functions.

Effort estimate: ~500 lines of Solidity across contracts, plus an audit cycle.

### 6.2 Mech side (mech repo)

**Modified file**: `mech/packages/valory/skills/task_execution/handlers.py`

Two new HTTP routes added to `MechHttpHandler`:

- `POST /open_channel_hint`: client asks "what do I need to know to open a channel with you?" Mech responds with channelId derivation parameters, recommended deposit, EIP-712 domain. Used by client SDKs to construct an `openChannel` transaction.
- `POST /submit_voucher`: voucher-bearing request submission. Body contains `tool`, `prompt`, IPFS data, and voucher `{channelId, cumulativeAmount, signature}`. Mech verifies the EIP-712 voucher off-chain, checks the cumulative is strictly greater than the stored value, checks cumulative is within the channel deposit, then enqueues the task and returns 200.

The existing `POST /send_signed_requests` route (per-request signatures) stays for the legacy mech-prepay path. The existing `GET /fetch_offchain_info` polling endpoint stays unchanged.

A new helper `_verify_voucher` ports `wildcard/server/src/session/voucher.py:verify_voucher` into the mech behaviour. EIP-712 typed data recover with `eth_account.recover_message`, expects recovered signer to equal channel's payer.

**Modified file**: `mech/packages/valory/skills/task_submission_abci/behaviours.py`

New behaviour branch that:
- Reads pending voucher acceptance log from `synchronized_data`
- Groups by `(requester, mech)`, keeps only the latest voucher per pair
- Builds the `PrepayVoucherInput[]` array
- Submits via `OlasMech.settleBatchByVouchers`

Coexists with the existing per-request signature batching. Mech operator chooses per batch which path to use (configurable; usually voucher path once available).

**Modified module**: synchronized_data slot definitions

New slots:
- Per active channel: `channelId, payer, mech, deposit, expiry, highestAcceptedCumulative, lastSettledOnChain, latestVoucherSig`
- Pending voucher acceptance log: list of `(request_id, channel_id, cumulative, accepted_at)`

Survives agent restarts and is consistent across the agent ensemble. Cleared when a channel closes.

**New module**: optional Postgres adapter

For production deployments, a Postgres-backed delivery store. Schema as documented in Section 2.D. Adapter writes one row per accepted request (when the mech finishes serving), and updates the `settled_on_chain_at` column after a batch settles. Reads support the existing `GET /fetch_offchain_info` polling endpoint.

For development / single-agent deployments, synchronized_data alone is sufficient. The Postgres layer is purely for durability and queryability.

Effort estimate: ~500 lines of new behaviour + handler code, ~150 lines of Postgres adapter.

### 6.3 mech-client (the Python CLI / library)

**Already there**: mech-client has the off-chain HTTP path built in. `mech_client/services/marketplace_service.py:243-356` defines `_send_offchain_request` which signs request data, POSTs to `/send_signed_requests`, and polls for the result via `OffchainDeliveryWatcher`. The `--use-offchain` CLI flag at `mech_client/cli/commands/request_cmd.py:69-71` exposes this to users. `use_offchain implies use_prepaid`.

**What to add**:

A parallel `_send_voucher_request` method that:
- Discovers the mech HTTP endpoint (auto from on-chain metadata, or from config)
- On the first request to a given mech: fetches the channel-open hint via `POST /open_channel_hint`, submits an `openChannel` transaction (or asks the user to confirm via CLI prompt)
- Tracks local channel state (per-mech, per-active-channel) in a local file (e.g. `~/.mech-client/channels.json`)
- Signs the next voucher with cumulative bumped, POSTs to `/submit_voucher`
- On 402 with `scheme: "olas-prepay-voucher"`: reads the voucher hint body, signs the next voucher, retries
- Polls for result via the existing `OffchainDeliveryWatcher`

New CLI commands:
- `mech-client open-channel --mech <addr> --deposit <amount> --expiry <hours>`
- `mech-client close-channel --channel-id <id>`
- `mech-client request-close --channel-id <id>` (the safety-valve flow)
- `mech-client withdraw --amount <X>` (the free-balance withdraw)

Existing CLI behavior unchanged. `--use-offchain` keeps using the per-request signature path. New `--use-voucher` flag opts into the voucher path.

Effort estimate: ~400 lines of new service code + CLI command wiring.

### 6.4 mech-interact (the ABCI skill used by Trader, Market-Creator, MemeOoorr, etc.)

**Today's flow**: mech-interact uses the on-chain `MechMarketplace.request()` path exclusively. No HTTP off-chain branch. Per-request on-chain submission. Confirmed via `mech-interact/packages/valory/skills/mech_interact_abci/behaviours/request.py`.

**What to add**:

A new behaviour `MechVoucherChannelBehaviour` (or extension of `MechRequestBehaviour`) that:
- Checks `synchronized_data` for an active channel with the priority mech
- If none: builds an approve + depositFor + openChannel multisend, submits, persists the channel id
- For the request: signs the next voucher with the safe key (EIP-712 typed data), POSTs to the mech's `/submit_voucher` endpoint via the existing AEA http connection
- On 402 with voucher hint: re-sign with the corrected cumulative and retry
- Updates `synchronized_data.channel_state` after each accepted voucher
- The response behaviour polls the mech's HTTP endpoint (or stays with on-chain Deliver-event polling as a fallback)

New params in `skill.yaml`:
- `mech_http_url`: explicit override of the mech's HTTP endpoint (else auto-discover from on-chain metadata)
- `prefer_voucher_path`: opt-in flag to use the new path
- `default_channel_deposit`: how much to lock per channel (e.g. $1.00)
- `default_channel_expiry_hours`: default 24

The existing on-chain request behaviour stays untouched. Services that don't opt in keep working the same way.

A new closure behaviour is also needed for graceful service shutdown: at termination, close any active channels to recover residual deposit.

Effort estimate: ~400 lines of new behaviour code in mech-interact, plus tests.

### 6.5 Do we need a separate package?

Two genuine questions here:

**1. For Valory's own clients (mech-client, mech-interact)**: no separate package. Both libraries already exist; we add a voucher branch to each.

**2. For third-party HTTP clients that aren't Python**: a thin TypeScript/JavaScript package is worth maintaining. Use cases:
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

This package is NOT blocking for v1. mech-client and mech-interact cover all current Valory consumers. The TypeScript package is needed when external HTTP agents (the x402-scan-style ecosystem clients, browser apps, partner integrations) want to consume Olas mechs. Ship in v1.1 once there's a concrete external consumer.

**3. Future MPP protocol compatibility**: as Section 1 noted, going fully MPP-compatible later means adding an OpenAPI doc, MPP-shaped HTTP headers, and a TypeScript adapter that speaks the MPP wire. If we ship `@valory/olas-prepay-client` for use case #2 above, that same package can grow into the MPP-compatibility layer when needed. So the answer to "do we need a separate package" depends on whether we want non-Python clients to reach our mechs.

Recommended sequencing:
- v1: ship contracts + mech + mech-client + mech-interact. No TypeScript package yet.
- v1.1: add `@valory/olas-prepay-client` when a non-Python consumer shows up, or when MPP-protocol compatibility becomes a priority.

---

## 7. Contract change summary

| Component | Change | Notes |
|-----------|--------|-------|
| `BalanceTrackerFixedPriceTokenChannel` | NEW subclass | Channels + voucher settlement, ~300 lines |
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

## 8. Known constraints

What remains, honestly:

- **Channel deposit upfront**. Locking USDC in a channel is the price of race elimination. For one-shot clients, the legacy per-request flow is cheaper.
- **One channel per `(payer, mech)` pair**. A client talking to N mechs opens N channels.
- **Channel expiry**. Pick a window the mech can settle within. Recommended 24 hours.
- **No on-chain per-request records**. Mech-side Postgres is the source of truth for delivery details. Subgraph indexers watching `Deliver` events won't see voucher-path traffic.
- **Mech operator submits batches**. Same trust model as today's mech Safe ops. No new keys.
- **Strict monotonicity on-chain**. Two concurrent settlement attempts for the same cumulative: one wins, the other emits `VoucherSettlementFailed`. Mech reconciles off-chain.

What's NOT a constraint anymore:

- ~~Settlement race~~ eliminated by encumbrance
- ~~Atomic batch revert~~ eliminated by per-voucher try/catch
- ~~Need on-chain per-request records~~ replaced by Postgres-backed mech-side store
- ~~Per-requester-only batching~~ multi-requester is built into `settleBatchByVouchers`

---

## 9. Comparison vs MPP session

Behaviorally identical after this spec ships. Differences are structural and external-compatibility:

| Aspect | This spec | MPP session |
|--------|-----------|-------------|
| Custody contract | BalanceTracker (existing) | MppEscrow (new) |
| Channel state location | `mapChannels` inside BalanceTracker | `channels` inside MppEscrow |
| Voucher EIP-712 domain | `Olas Mech Prepay Channel` | `Tempo Stream Channel` (or equivalent) |
| Cumulative monotonicity | Enforced on-chain | Enforced on-chain |
| Settlement race | Eliminated | Eliminated |
| Atomic batch revert | Eliminated (try/catch) | Not addressed in MPP spec |
| Per-request on-chain records | None (Postgres) | None |
| Audit boundary | 1 contract | 2 contracts (escrow + tracker) |
| MPP protocol compatibility | None | Partial (Valory extension of session intent on EVM) |
| Discoverable on MPPscan | No without OpenAPI add-on | No without OpenAPI add-on |

Given that MPP protocol compatibility isn't a goal for v1, this spec is the cleaner path. Same outcome, smaller audit surface, no MPP terminology to defend.

---

## 10. Testing strategy

### 10.1 Contract tests

1. **Happy path**: open → 5 vouchers off-chain → batched settle → close. Balances correct end-to-end.
2. **Encumbrance enforcement**: open channel for 500_000, try `withdrawRequester(amount > free)`, expect revert.
3. **Voucher monotonicity**: settle cumulative=100, try cumulative=100 again, expect `NonMonotonicCumulative` event from try/catch.
4. **Exceeds deposit**: voucher with `cumulative > channel.deposit`, expect `ExceedsDeposit` event.
5. **Channel expiry**: voucher submitted after expiry, expect `VoucherExpired` event.
6. **Forged signature**: voucher signed by attacker, not payer, expect `InvalidVoucherSignature` event.
7. **Finalized channel**: settle after `closeChannel` called, expect `ChannelFinalized` event.
8. **`forceClose` timeout**: try `forceClose` before `CLOSE_TIMEOUT` elapsed, expect revert.
9. **Fail-soft batch**: 5 vouchers, 1 expired. 4 succeed, 1 emits failure event. Transaction completes. `mapMechBalances` reflects only the 4.
10. **Multi-requester**: 50 vouchers from 50 different requesters in one batch. All settle independently.
11. **Fee accounting**: `processPaymentByMultisig` works on accumulated `mapMechBalances` after voucher settlement.
12. **Reentrancy**: malicious token reenters during `transfer`, blocked by `_locked`.
13. **Multi-mech**: Alice opens channels with Mech A and Mech B, both settle independently, encumbrance tracks each.

### 10.2 End-to-end integration

1. Hardhat fork with USDC + new contracts deployed
2. mech-client `--use-voucher`: opens channel, sends 5 requests, mech batches, channel closes
3. Verify events: `ChannelOpened`, 5 `VoucherSettled`, `MarketplaceVoucherSettlement`, `ChannelClosed`
4. Verify Postgres has 5 rows with correct ipfs hashes
5. Verify final `mapRequesterBalances[client]` includes the refunded residual

### 10.3 Adversarial tests

1. **Race elimination**: client `withdrawRequester` after voucher acceptance, before settle. Withdraw bounded to free balance. Mech successfully settles the encumbered amount.
2. **Fail-soft**: 100-voucher batch with 10 bad vouchers randomly placed. 90 settle, 10 emit failure events. Transaction succeeds.

---

## 11. References

- `docs/mpp_session_spec.md`, the structural alternative using a separate escrow contract
- `docs/x402_spec.md`, the per-request EIP-3009 alternative
- `docs/x402_vs_mpp.md`, decision guide between the two ecosystem options
- `wildcard/server/src/session/store.py`, the Postgres-backed channel store this spec mirrors
- `wildcard/server/src/session/voucher.py`, the EIP-712 voucher verification reference
- `mech-client/mech_client/services/marketplace_service.py`, the existing HTTP off-chain integration that gets the voucher branch
- `mech-interact/packages/valory/skills/mech_interact_abci/behaviours/request.py`, the on-chain-only behaviour that gets the new voucher branch
- `mech/packages/valory/skills/task_execution/handlers.py`, the off-chain HTTP handler that gets the new voucher routes
- `mech/packages/valory/skills/task_submission_abci/behaviours.py`, the batched settlement behaviour that gets the new voucher-path branch
- `contracts/MechMarketplace.sol`, the marketplace that gets the new `settleBatchByVouchers` entry
- `contracts/mechs/token/BalanceTrackerFixedPriceToken.sol`, the parent class of the new BalanceTracker subclass
- [MPPscan discovery spec](https://www.mppscan.com/discovery/spec), for the optional future MPPscan listing
