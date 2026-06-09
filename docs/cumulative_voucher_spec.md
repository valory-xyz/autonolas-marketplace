# Cumulative Voucher Settlement with Encumbered Channels

## 1. How far are we from MPP, and what this spec closes

After shipping this spec, mech-prepay becomes functionally MPP session inside the BalanceTracker. The behavioral gap closes completely. The remaining differences are structural and external-compatibility:

| Property | mech-prepay (today) | This spec | MPP session |
|----------|---------------------|-----------|-------------|
| Cumulative voucher signing | No (per-request sigs) | **Yes** | Yes |
| Funds locked against withdraw | No (race exists) | **Yes (encumbered channels)** | Yes (escrow contract) |
| Settlement race | Exists (bounded by maxRate) | **Eliminated** | Eliminated |
| Atomic batch revert | Yes (DOS risk) | **No (fail-soft)** | Yes (no fix in MPP spec) |
| Per-request on-chain records | Yes (N events) | **No (Postgres on mech)** | No |
| Cross-requester batching in one tx | No | **Yes (one tx, M requesters)** | No (per-channel only) |
| Custody contract | BalanceTracker | BalanceTracker | MppEscrow (new contract) |
| Audit boundary | 1 contract | 1 contract | 2 contracts |
| Discoverable on MPPscan | No | No (could add OpenAPI later) | No |
| Payable by generic mppx client | No | No | No |
| MPP-protocol-compatible | No | No | Partial (our session intent is a Valory extension; see `mpp_session_spec.md` §1) |

### What we'd still need to add later to be MPP-protocol-compatible

Three additions, all orthogonal to this spec:

1. **OpenAPI discovery document** at `GET /openapi.json` with `x-payment-info` annotations. Self-register at `mppscan.com/register`. Documentation work, no contract changes.
2. **MPP-shaped HTTP headers**: accept `Payment-Credential` as an alternative to our voucher body, emit `Payment-Receipt` on 200. ~30 lines in the mech HTTP handler.
3. **A separately-shipped mppx adapter** (`@valory/olas-mpp` npm package) so external mppx clients can sign vouchers against our channels. ~400-600 lines TypeScript.

None of those change the on-chain story. They're follow-on integration work if the team decides MPPscan visibility matters.

### What we'd need to implement in THIS spec

Concrete deltas, all detailed in Section 2:

- New EIP-712 voucher type and signing
- New BalanceTracker subclass with channels + voucher settlement
- New marketplace function `settleBatchByVouchers` with per-voucher try/catch
- New OlasMech forwarder
- New mech HTTP routes for voucher submission
- Postgres-backed mech-side response store
- mech-client and mech-interact voucher branches

Total new code: ~1900 lines across contracts, mech, and clients. One new audit boundary (the BalanceTracker subclass).

---

## 2. The design, problem by problem

Five distinct problems with today's mech-prepay. Each has its own targeted fix.

### A. Batch settlement cost is linear in request count

**The problem.**

`MechMarketplace._deliverMarketplaceWithSignatures` (`MechMarketplace.sol:206-285`) iterates over the batch and verifies each request individually:

```
for each i in 0..N-1:
    requestId = getRequestId(mech, requester, requestData[i], rates[i], paymentType, nonce + i)
    _verifySignedHash(requester, requestId, signatures[i])      # ecrecover
    mapRequestIdInfos[requestId] = RequestInfo(...)             # SSTORE
    emit Deliver(...)                                           # LOG
```

That loop is `N × (keccak + ecrecover + SSTORE + LOG)` per requester per batch. At ~50k gas per iteration, a 50-request batch from one client burns ~2.5M gas just on the per-request loop. Multiply by M distinct clients in a window and on-chain settlement dominates everything else.

**The fix.**

Replace per-request signatures with one cumulative voucher per `(requester, mech)` pair per batch period. The client signs ONE EIP-712 typed message authorizing a `cumulativeAmount`:

```
PrepayVoucher(
    address mech,
    address requester,
    bytes32 channelId,
    uint128 cumulativeAmount
)
```

Each new request bumps the cumulative. The mech keeps only the latest voucher per pair. On settlement, the BalanceTracker verifies ONE signature, checks monotonicity, and debits the delta.

For 100 off-chain requests from one client: one signature on-chain, one storage write, one transfer. Constant cost.

For 100 requests across 50 clients: 50 signatures total, not 100. Linear in requesters, not in requests.

This is the core scaling unlock. Everything else in this spec builds on it.

### B. Settlement race lets clients drain funds before the mech settles

**The problem.**

In plain mech-prepay, the mech accepts a voucher off-chain, returns the result to the client at HTTP 200, then later attempts to settle on-chain. Between those moments the client can call `withdrawRequester` and empty `mapRequesterBalances`. The mech's settlement reverts with `InsufficientBalance`. The mech ate the cost of running the tool.

Per-request exposure is bounded by `maxDeliveryRate` (~$0.05). But across a high-volume mech, this becomes a denial-of-payment vector. A client can submit a request, wait for the result, then sweep their balance before the batch cycle. Repeated, it's an attack on mech revenue.

**The fix.**

Encumber the funds inside the BalanceTracker BEFORE the off-chain acceptance, not after. Introduce a channel concept that lives inside the existing BalanceTracker (no separate escrow contract):

```solidity
struct PrepayChannel {
    address payer;
    address mech;
    uint128 deposit;       // committed to this channel
    uint128 settled;       // cumulative already settled on-chain
    uint64 expiry;
    uint64 closeRequestedAt;
    bool finalized;
}
mapping(bytes32 => PrepayChannel) public mapChannels;
mapping(address => uint256) public mapEncumberedAmount;     // per-requester total locked
```

Channel lifecycle entry points:

- `openChannel(mech, deposit, expiry)`: payer commits `deposit` from `mapRequesterBalances` into `mapEncumberedAmount` and into the new channel. Funds are locked.
- `settleByVoucher(...)`: marketplace-only. Moves voucher delta from encumbered to `mapMechBalances[mech]`.
- `closeChannel(channelId, finalCumulative, finalSig)`: settles the last voucher, refunds residual to `mapRequesterBalances[payer]`, finalizes.
- `requestClose(channelId)` + `forceClose(channelId)` after `CLOSE_TIMEOUT` (24h): payer's safety valve to recover funds if the mech goes silent.

`withdrawRequester` only operates on `mapRequesterBalances` (free), never on `mapEncumberedAmount` (locked). The mech is guaranteed it can settle any voucher up to the channel's deposit cap.

The race is eliminated by construction. Same property MPP gives you via its escrow.

### C. One bad voucher reverts the whole batch

**The problem.**

`deliverMarketplaceWithSignatures` is atomic. If one signature in a batch is bad, the whole transaction reverts. In a multi-requester batch where 99 vouchers are valid and 1 is malformed (or expired, or has insufficient deposit, or whatever), all 100 settlements fail. The mech has to identify the bad voucher off-chain, remove it from the batch, and resubmit.

In production this is a real DOS vector. A single misbehaving (or buggy) client can break a mech's entire settlement cycle.

**The fix.**

Per-voucher `try`/`catch` in the marketplace batch settlement. Each voucher is settled inside its own try block. Failures emit an event and the loop continues:

```solidity
function settleBatchByVouchers(PrepayVoucherInput[] calldata vouchers) external {
    address mech = msg.sender;
    checkMech(mech);
    address balanceTracker = mapPaymentTypeBalanceTrackers[IMech(mech).paymentType()];

    uint256 totalSuccessful;
    uint256 totalSuccessfulRequests;

    for (uint256 i = 0; i < vouchers.length; ++i) {
        PrepayVoucherInput calldata v = vouchers[i];

        try IBalanceTrackerChannel(balanceTracker).settleByVoucher(
            mech, v.requester, v.cumulativeAmount, v.voucherSig
        ) returns (uint256 /*delta*/) {
            // success: do per-requester karma + counter updates
            IKarma(karma).changeRequesterMechKarma(v.requester, mech, int256(v.requestCount));
            mapDeliveryCounts[v.requester] += v.requestCount;
            totalSuccessful++;
            totalSuccessfulRequests += v.requestCount;
        } catch (bytes memory reason) {
            emit VoucherSettlementFailed(mech, v.requester, v.channelId,
                                         v.cumulativeAmount, reason);
            // no revert, continue to the next voucher
        }
    }

    if (totalSuccessfulRequests > 0) {
        IKarma(karma).changeMechKarma(mech, int256(totalSuccessfulRequests));
        mapMechDeliveryCounts[mech] += totalSuccessfulRequests;
        numTotalRequests += totalSuccessfulRequests;
        IMech(mech).updateNumRequests(totalSuccessfulRequests);
    }

    emit MarketplaceVoucherSettlement(mech, vouchers.length,
                                       totalSuccessful, totalSuccessfulRequests);
}
```

`settleByVoucher` on the BalanceTracker is reentrancy-guarded and idempotent on success (advances `mapChannels[channelId].settled`). A failure leaves the channel state unchanged. Bad vouchers are isolated; good ones still settle.

This is actually BETTER than MPP session's behavior, which doesn't specify fail-soft batching.

### D. Per-request on-chain records add bloat for no benefit

**The problem.**

Today every delivery emits a `Deliver` event and stores a `RequestInfo` struct in `mapRequestIdInfos[requestId]`. For high-volume mechs that's a lot of on-chain state and event emissions purely to record "this request was delivered." Subgraph indexers consume these events for delivery tracking.

But for an HTTP-style paid API model, clients already poll the mech's HTTP endpoint for their results. They don't read the subgraph. So the on-chain delivery records are paid-for-but-unused.

**The fix.**

Drop per-request on-chain records. Persist delivery data on the mech side using the wildcard pattern (`wildcard/server/src/session/store.py`).

Two layers of mech-side storage:

**Layer 1, `synchronized_data` (already exists in open-autonomy):**
- Channel state per active `(requester, mech)`: `{channelId, deposit, expiry, highestAcceptedCumulative, lastSettledOnChain, latestVoucherSig}`
- Pending voucher acceptance log: list of accepted vouchers waiting for next batch settlement
- Survives agent restart, consistent across the agent ensemble

**Layer 2, optional Postgres for delivery results:**

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

This is exactly what the wildcard prediction server does in production. Mirrors that schema.

On-chain events in the voucher path:
- `ChannelOpened` (one per channel open)
- `VoucherSettled` (one per successful voucher in a batch)
- `VoucherSettlementFailed` (one per failed voucher in a batch)
- `MarketplaceVoucherSettlement` (one per batch)
- `ChannelClosed` (one per channel close)

No `Deliver` event per request. Clients fetch results via the existing HTTP `GET /fetch_offchain_info` endpoint (`mech/.../handlers.py:668-709`), not via subgraph.

### E. Settlement is per-requester, not across requesters

**The problem.**

Even with cumulative vouchers, the current marketplace function `deliverMarketplaceWithSignatures(requester, ...)` takes ONE `requester` parameter. To settle vouchers from M different clients, the mech submits M separate transactions.

For a busy mech with 50 active clients in a 5-minute batch window, that's 50 transactions instead of 1. The marketplace overhead (mech check, paymentType lookup, balance tracker resolution, event emission) repeats 50 times.

**The fix.**

`settleBatchByVouchers` takes an array of vouchers, one per requester:

```solidity
struct PrepayVoucherInput {
    address requester;
    bytes32 channelId;
    uint128 cumulativeAmount;
    uint256 requestCount;        // off-chain delivery count this voucher represents
    bytes voucherSig;
}

function settleBatchByVouchers(PrepayVoucherInput[] calldata vouchers) external;
```

The mech submits ONE transaction with one entry per active requester. Inside the loop, each `settleByVoucher` call debits the right channel's encumbrance and credits `mapMechBalances[mech]`.

Combined with the cumulative voucher property (each entry covers N off-chain requests for that client) and the try/catch (failures don't kill siblings), this collapses settlement to one on-chain transaction per batch window, regardless of how many requests across how many clients.

For 1000 requests across 100 clients in a window: 1 transaction with 100 voucher entries inside it. Mech-overhead amortizes across all 1000.

---

## 3. Putting it together

### 3.1 PrepayVoucher EIP-712 type

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

The voucher is bound to a specific channel via `channelId`. The channel itself has an `expiry`; the voucher inherits it (no separate expiry on the voucher).

### 3.2 BalanceTrackerFixedPriceTokenChannel (new subclass)

```solidity
contract BalanceTrackerFixedPriceTokenChannel is BalanceTrackerFixedPriceToken {
    struct PrepayChannel {
        address payer;
        address mech;
        uint128 deposit;
        uint128 settled;
        uint64 expiry;
        uint64 closeRequestedAt;
        bool finalized;
    }

    mapping(bytes32 => PrepayChannel) public mapChannels;
    mapping(address => uint256) public mapEncumberedAmount;

    uint64 public constant CLOSE_TIMEOUT = 24 hours;

    function openChannel(address mech, uint128 deposit, uint64 expiry)
        external returns (bytes32 channelId);

    function settleByVoucher(
        address mech, address requester, uint128 cumulativeAmount, bytes calldata voucherSig
    ) external returns (uint256 delta);   // marketplace-only

    function closeChannel(
        bytes32 channelId, uint128 finalCumulative, bytes calldata finalSig
    ) external;

    function requestClose(bytes32 channelId) external;   // payer-only
    function forceClose(bytes32 channelId) external;     // payer-only, after CLOSE_TIMEOUT

    // withdrawRequester from the base contract works unchanged because
    // mapRequesterBalances is already the free portion; encumbered is separate
}
```

### 3.3 MechMarketplace addition

One new function, with per-voucher try/catch as shown in Section 2.C above. No changes to existing marketplace logic.

### 3.4 OlasMech forwarder

```solidity
function settleBatchByVouchers(PrepayVoucherInput[] calldata vouchers)
    external onlyOperator
{
    IMechMarketplace(mechMarketplace).settleBatchByVouchers(vouchers);
}
```

### 3.5 Registration

```solidity
mechMarketplace.setPaymentTypeBalanceTrackers(
    [keccak256("MECH_PREPAY_CHANNEL_USDC")],
    [BalanceTrackerFixedPriceTokenChannel_address]
);
```

This is a distinct payment type from the existing `FixedPriceTokenUSDC`. Mechs that want the new behavior deploy with this payment type. Existing mechs continue working unchanged.

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
                                                ────▶ mapChannels[channelId] = {payer, mech,
                                                          deposit: Y, settled: 0, expiry, ...}
                                                ────▶ ChannelOpened event


Phase 3, off-chain request loop (no on-chain anything)
──────────────────────────────────────────────────────
Request 1:
   Client → POST /predict { tool, prompt }
   Mech → 402 { scheme: "olas-prepay-voucher", channelId, eip712_domain,
                current_cumulative: 0, would_be_cumulative: 10200 }
   Client signs PrepayVoucher(mech, client, channelId, 10200)
   Client → POST /predict { ..., voucher: {...} }
   Mech verifies sig + monotonicity + cumulative ≤ channel.deposit
   Mech runs tool, returns 200 { result, accepted_cumulative: 10200 }
   Mech persists:
      synchronized_data: latestVoucher[(client, mech)] = {10200, sig}
      Postgres: (request_id_1, client, channelId, 10200, ipfs_hash, now)

Request 2..N:
   Same shape; cumulative bumps by quote each time
   No on-chain anything


Phase 4, batched on-chain settlement with fail-soft
───────────────────────────────────────────────────
Mech Safe collects latest voucher per active (requester, mech) pair.
Once per batch window:

   OlasMech.settleBatchByVouchers([
      { requester: 0xAlice, channelId: cA, cumulative: 81600,  count: 8,  sig: sA },
      { requester: 0xBob,   channelId: cB, cumulative: 30600,  count: 3,  sig: sB },
      { requester: 0xCarol, channelId: cC, cumulative: 122400, count: 12, sig: sC },
      ...
   ])

   ────▶ MechMarketplace.settleBatchByVouchers
         for each voucher (in try/catch):
            BalanceTracker.settleByVoucher(...)
               verify sig, cumulative > settled, cumulative ≤ deposit, not finalized
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
Happy path (mech-initiated, after the last batch):
   Mech Safe → BalanceTracker.closeChannel(channelId, finalCumulative, finalSig)
                                                ────▶ settles last voucher if not already
                                                ────▶ refunds (deposit - finalCumulative)
                                                       back to mapRequesterBalances[client]
                                                ────▶ marks finalized = true
                                                ────▶ ChannelClosed event

Safety path (payer-initiated, if mech goes silent):
   Client → requestClose(channelId)             emits ChannelCloseRequested
   Wait CLOSE_TIMEOUT = 24h
   Client → forceClose(channelId)               refunds residual, marks finalized


Phase 6, withdraw free balance (existing mech-prepay)
─────────────────────────────────────────────────────
Client → BalanceTracker.withdrawRequester(amount)
                                                ────▶ operates only on mapRequesterBalances
                                                       (encumbered portion untouchable)
```

The race is gone. The atomic batch is gone. Per-request on-chain records are gone. Settlement is one transaction per batch window across all active requesters.

---

## 5. Worked example

Setup:
- Alice deposits $1.00 into the BalanceTracker. `mapRequesterBalances[Alice] = 1_000_000`.
- Mech rate: $0.01 per request. Quote: 10_000 atomic units.
- Alice opens a channel: `openChannel(mech, 500_000, now+24h)`.
  - `mapRequesterBalances[Alice]` = 500_000 (free)
  - `mapEncumberedAmount[Alice]` = 500_000 (locked in channel)
  - `mapChannels[cA].deposit = 500_000, settled = 0`

15 minutes pass, Alice makes 8 requests off-chain:
- Each request signs voucher with cumulative = 10000, 20000, ..., 80000
- 0 on-chain transactions
- Mech persists results in Postgres
- Mech holds latest voucher: `{cumulative: 80000, sig: sig_8}`

Alice tries to drain her wallet during the 15 minutes:
- `withdrawRequester(500_000)` succeeds. She gets her free balance back.
- She CANNOT touch the 500_000 in the channel. Encumbered.
- Mech still safely holds claim to up to 500_000 via accepted vouchers.

At batch boundary, mech submits:
```
settleBatchByVouchers([
  { requester: Alice, channelId: cA, cumulative: 80_000, count: 8, sig: sig_8 }
])
```

Inside the contract:
- Voucher sig verified ✓
- `cumulative (80_000) > settled (0)` ✓
- `cumulative (80_000) ≤ deposit (500_000)` ✓
- delta = 80_000
- `mapEncumberedAmount[Alice] -= 80_000`  (now 420_000)
- `mapMechBalances[mech] += 80_000`
- `mapChannels[cA].settled = 80_000`
- Karma + counters updated for Alice
- One `VoucherSettled` event

Alice continues. Eventually she or the mech closes:
- `closeChannel(cA, 92_000, latest_sig)` settles last voucher (delta 12_000), refunds 408_000 to free balance.
- Alice's final state: free balance = (whatever's left after withdraw) + 408_000, encumbered = 0.

Total on-chain transactions for 9 requests: 1 deposit + 1 openChannel + 1 batched settle + 1 closeChannel = 4 transactions, regardless of how many requests within the channel window.

Now imagine 50 clients doing similar:
- 50 deposits (each client, one-time)
- 50 openChannels (each client, one-time per channel)
- **1 batched settle** covering vouchers from all 50 clients (per batch window)
- 50 closeChannels (each client, one-time when done)

Per-batch settlement work for the mech: 1 transaction. That's the scaling property.

---

## 6. What we need to build

| Layer | Lines | Notes |
|-------|-------|-------|
| `BalanceTrackerFixedPriceTokenChannel.sol` | ~300 | Subclass with channels + voucher settlement |
| `MechMarketplace.sol` | ~100 added | `settleBatchByVouchers` with try/catch |
| `OlasMech.sol` | ~10 added | Forwarder |
| `IBalanceTracker*.sol` | ~50 added | New interface variant |
| Mech behaviour (handlers + task_submission) | ~500 | HTTP voucher routes + batch settlement + state |
| Mech Postgres adapter | ~150 | Schema + queries |
| mech-client voucher branch | ~400 | Voucher signing, channel lifecycle CLI |
| mech-interact voucher branch | ~400 | Voucher signing, channel lifecycle in `synchronized_data` |
| **Total new code** | **~1900 lines** | |

Audit boundary: one new contract (`BalanceTrackerFixedPriceTokenChannel`).

---

## 7. Contract change summary

| Component | Change | Notes |
|-----------|--------|-------|
| `BalanceTrackerFixedPriceTokenChannel` | NEW subclass | Channels + voucher settlement; ~300 lines |
| `MechMarketplace` | Add `settleBatchByVouchers` + event | Per-voucher try/catch |
| `OlasMech` | Add forwarder | `onlyOperator` |
| `IBalanceTrackerChannel` | NEW interface | Or extend the existing one |
| `BalanceTrackerBase` | None | All hooks present |
| `BalanceTrackerFixedPriceToken` | None | Parent class, unchanged |
| Karma | None | Receives per-requester + aggregate updates as usual |
| Fee logic | None | `processPaymentByMultisig` works on `mapMechBalances` as today |
| Existing payment families | None | All untouched, coexist via registry |

The existing marketplace, OlasMech, and BalanceTracker base stay as-is. The voucher path is strictly additive.

---

## 8. Known constraints

What remains, honestly:

- **Channel deposit upfront.** Locking USDC in a channel is the cost of race elimination. For one-shot clients, mech-prepay (without channels) is cheaper.
- **One channel per (payer, mech) pair.** A client talking to N mechs opens N channels.
- **Channel expiry.** Recommended 24h. Voucher inherits the channel's expiry.
- **No on-chain per-request records.** Mech-side Postgres is the source of truth for delivery details. Subgraph indexers watching `Deliver` events won't see voucher-path traffic. The new events (`ChannelOpened`, `VoucherSettled`, etc.) are batch-level only.
- **Mech operator submits batches.** Same trust model as today's mech Safe ops. No new keys.
- **Strict monotonicity on-chain.** Two concurrent settlement attempts for the same cumulative: one wins, the other emits `VoucherSettlementFailed`. Mech reconciles off-chain.

What's NOT a constraint anymore:

- ~~Settlement race~~ eliminated by encumbrance
- ~~Atomic batch revert~~ eliminated by per-voucher try/catch
- ~~Need on-chain per-request records~~ replaced by Postgres-backed mech-side store
- ~~Per-requester-only batching~~ multi-requester is built into `settleBatchByVouchers`

---

## 9. Comparison vs MPP session

Behaviorally identical. Differences are structural and external-compatibility:

| Aspect | This spec | MPP session |
|--------|-----------|-------------|
| Custody contract | BalanceTracker (existing) | MppEscrow (new) |
| Channel state location | `mapChannels` inside BalanceTracker | `channels` inside MppEscrow |
| Voucher EIP-712 type | `PrepayVoucher` with Olas domain | Voucher with Tempo domain |
| Cumulative monotonicity | On-chain | On-chain |
| Settlement race | Eliminated | Eliminated |
| Atomic batch revert | Eliminated (try/catch) | Not addressed in MPP spec |
| Per-request on-chain records | None (Postgres) | None |
| Audit boundary | 1 contract | 2 contracts (escrow + tracker) |
| MPP protocol compatibility | None | Partial (Valory extension of session intent for EVM) |
| Discoverable on MPPscan | No without OpenAPI add-on | No without OpenAPI add-on |

Given that MPP protocol compatibility isn't a goal for v1, this spec is the cleaner path. Same outcome, smaller audit surface, no MPP terminology to defend or extend.

---

## 10. Testing strategy

### 10.1 Contract tests

1. **Happy path**: open → 5 vouchers off-chain → batched settle → close. Balances correct end-to-end.
2. **Encumbrance**: open channel for 500_000, try `withdrawRequester(amount > free balance)`, expect revert.
3. **Monotonicity**: settle cumulative=100, try cumulative=100 again, expect `NonMonotonicCumulative` in failure event from try/catch.
4. **Exceeds deposit**: voucher with cumulative > channel.deposit, expect `ExceedsDeposit` in failure event.
5. **Channel expiry**: voucher submitted after expiry, expect `VoucherExpired` in failure event.
6. **Forged signature**: voucher signed by attacker, expect `InvalidVoucherSignature` in failure event.
7. **Finalized channel**: settle after `closeChannel`, expect `ChannelFinalized` in failure event.
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
4. Verify Postgres holds 5 rows with correct ipfs hashes
5. Verify final `mapRequesterBalances[client]` includes the refunded residual

### 10.3 Adversarial tests

1. Race-elimination: client `withdrawRequester` after voucher acceptance, before settle. Withdraw bounded to free balance. Mech successfully settles the encumbered amount.
2. Fail-soft: 100-voucher batch with 10 bad vouchers randomly placed. 90 settle, 10 emit failure events. Tx succeeds.

---

## 11. References

- `docs/mech_prepay_spec.md`, the minimum-viable baseline this builds on
- `docs/mpp_session_spec.md`, the alternative using a separate escrow contract
- `docs/x402_spec.md`, the per-request EIP-3009 alternative
- `docs/x402_vs_mpp.md`, decision guide between the ecosystem options
- `wildcard/server/src/session/store.py`, the Postgres-backed channel store this spec mirrors
- `wildcard/server/src/session/voucher.py`, the EIP-712 voucher verification reference
- `mech-client/mech_client/services/marketplace_service.py`, the existing HTTP off-chain integration that gets a voucher branch
- `mech/packages/valory/skills/task_execution/handlers.py`, the off-chain HTTP handler getting voucher routes
- [MPPscan discovery spec](https://www.mppscan.com/discovery/spec), for the optional future MPPscan listing
