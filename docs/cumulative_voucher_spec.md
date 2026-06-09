# Cumulative Voucher Settlement, Scaling Mech-Prepay Closer to MPP

## 1. Overview

This spec extends `mech_prepay_spec.md` with a voucher-based settlement path that brings the on-chain cost per request close to MPP without introducing a new escrow contract. The pre-deposit BalanceTracker keeps holding funds; what changes is how the mech authorises debits.

Today's mech-prepay settlement is linear in N: one signature, one storage write, and one Deliver event per request inside the batch. MPP's settlement is constant per batch. This spec closes most of that gap by replacing per-request signatures with a single **PrepayVoucher** signed once by the requester per batch period.

The result is intentionally short of full MPP. The settlement race remains, and on-chain per-request records go away. See Section 9 for the path to closing those final gaps if and when that's worth doing.

### Design intent

| Goal | How this spec meets it |
|------|------------------------|
| Make settlement constant-per-requester, not linear-per-request | One ecrecover and one storage write per requester per batch, regardless of N |
| Keep the existing pre-deposit BalanceTracker as fund custody | No new escrow contract; voucher debits `mapRequesterBalances` |
| Stay structurally additive on top of mech-prepay | New BalanceTracker function + new marketplace function; old functions keep working |
| Keep multi-requester batching independent | Vouchers compose naturally with the `multi_requester_batching_spec.md` change |

### What this spec deliberately keeps out

- **The settlement race.** Funds in `mapRequesterBalances` remain withdrawable by the client. Section 5 documents the bounded exposure; Section 9 shows the upgrade path that closes the race.
- **On-chain per-request records.** Today's `mapRequestIdInfos[requestId]` and per-delivery `Deliver` events go away in the voucher path. Indexers move to a new `VoucherSettled` event carrying the count.
- **A separate escrow contract.** Funds stay in the existing `BalanceTrackerFixedPriceToken`. If we ever want to lock funds against unilateral withdraw, see `mpp_session_spec.md` for the proper structural answer.

---

## 2. Why mech-prepay's settlement is linear today

Reading `MechMarketplace._deliverMarketplaceWithSignatures` (`contracts/MechMarketplace.sol:206-285`):

```
for each i in 0..N-1:
    requestId = getRequestId(mech, requester, requestData[i], rates[i], paymentType, nonce + i)
    _verifySignedHash(requester, requestId, signatures[i])      # ecrecover
    mapRequestIdInfos[requestId] = RequestInfo(...)             # SSTORE
    emit Deliver(mech, multisig, requestId, rate, data, deliveryData)
karma.changeRequesterMechKarma(requester, mech, +N)
karma.changeMechKarma(mech, +N)
mech.updateNumRequests(N)
BalanceTracker.adjustMechRequesterBalances(mech, requester, rates, "")    # 1 call, 1 debit
emit MarketplaceDeliveryWithSignatures(...)
```

The fixed-overhead block (karma, mech updates, balance debit, one event) is constant. The for-loop is the linear bottleneck: `N × (keccak + ecrecover + SSTORE + LOG)` per requester per batch.

At ~50k gas for an ecrecover + storage write + event emission, a 50-request batch from one client burns ~2.5M gas just on the per-request loop, before the actual balance-tracker work. Multiply by the number of distinct clients per batch window and the settlement cost dominates everything else.

MPP avoids this entirely. `MppEscrow.settle(channelId, cumulative, voucherSig)` is one ecrecover, one storage write, one transfer, one event. The N-request batch collapses to constant cost because the voucher represents cumulative state.

This spec gives mech-prepay the same property.

---

## 3. Proposed solution

Add a new settlement path alongside the existing one. Old code keeps working. New code uses vouchers.

### 3.1 The PrepayVoucher type

A client signs ONE EIP-712 typed message authorizing a specific mech to draw up to `cumulativeAmount` from their balance until `expiry`.

```
EIP-712 domain:
    name              = "Olas Mech Prepay"
    version           = "1"
    chainId           = block.chainid
    verifyingContract = address(BalanceTrackerFixedPriceToken)

EIP-712 type:
    PrepayVoucher(
        address mech,
        address requester,
        uint128 cumulativeAmount,
        uint256 expiry
    )
```

Properties:

- **Mech-bound.** Voucher works only for the specific `mech` address. A voucher signed for Mech A cannot be used by Mech B.
- **Cumulative.** Each new voucher must have `cumulativeAmount` strictly greater than the previously settled cumulative for that `(requester, mech)` pair. Monotonic.
- **Time-bound.** `expiry` is a Unix timestamp after which the voucher cannot be settled on-chain. Client picks a reasonable window (e.g. one hour, one day).
- **Replay-safe.** No nonce field is needed because cumulative IS the nonce. A voucher with `cumulativeAmount = X` becomes unusable as soon as the on-chain `settled` exceeds X.

### 3.2 New BalanceTracker function

Add `settleByVoucher` to the BalanceTracker. Either modify `BalanceTrackerFixedPriceToken` in place or deploy a subclass `BalanceTrackerFixedPriceTokenVoucher`.

```solidity
// per-(requester, mech) cumulative tracker
mapping(address => mapping(address => uint128)) public mapSettledCumulative;

function settleByVoucher(
    address mech,
    address requester,
    uint128 cumulativeAmount,
    uint256 expiry,
    uint8 v, bytes32 r, bytes32 s
) external returns (uint256 delta) {
    if (_locked == 2) revert ReentrancyGuard();
    _locked = 2;

    if (msg.sender != mechMarketplace) revert MarketplaceOnly(msg.sender, mechMarketplace);
    if (block.timestamp > expiry) revert VoucherExpired(expiry, block.timestamp);

    uint128 prevSettled = mapSettledCumulative[requester][mech];
    if (cumulativeAmount <= prevSettled) revert NonMonotonicCumulative(cumulativeAmount, prevSettled);

    // Verify EIP-712 voucher signature
    bytes32 digest = _voucherDigest(mech, requester, cumulativeAmount, expiry);
    address signer = ecrecover(digest, v, r, s);
    if (signer != requester) revert InvalidVoucherSignature(signer, requester);

    delta = uint256(cumulativeAmount - prevSettled);
    if (mapRequesterBalances[requester] < delta)
        revert InsufficientBalance(mapRequesterBalances[requester], delta);

    mapRequesterBalances[requester] -= delta;
    mapMechBalances[mech] += delta;
    mapSettledCumulative[requester][mech] = cumulativeAmount;

    emit VoucherSettled(mech, requester, cumulativeAmount, delta);

    _locked = 1;
}
```

That's the entire core change on the BalanceTracker. One new mapping, one new function, one new event.

### 3.3 New marketplace entry point

The marketplace exposes a settlement function that calls `settleByVoucher` and does aggregate bookkeeping. No per-request loops.

```solidity
struct PrepayVoucher {
    address requester;
    uint128 cumulativeAmount;
    uint256 expiry;
    uint8 v;
    bytes32 r;
    bytes32 s;
    uint256 requestCount;        // how many off-chain deliveries this voucher represents
}

function settleBatchByVouchers(
    PrepayVoucher[] calldata vouchers
) external {
    if (_locked == 2) revert ReentrancyGuard();
    _locked = 2;

    address mech = msg.sender;
    checkMech(mech);

    bytes32 paymentType = IMech(mech).paymentType();
    address balanceTracker = mapPaymentTypeBalanceTrackers[paymentType];
    if (balanceTracker == address(0)) revert ZeroAddress();

    uint256 totalRequests;

    for (uint256 i = 0; i < vouchers.length; ++i) {
        PrepayVoucher calldata v = vouchers[i];

        IBalanceTrackerVoucher(balanceTracker).settleByVoucher(
            mech, v.requester, v.cumulativeAmount, v.expiry, v.v, v.r, v.s
        );

        IKarma(karma).changeRequesterMechKarma(v.requester, mech, int256(v.requestCount));
        mapDeliveryCounts[v.requester] += v.requestCount;
        totalRequests += v.requestCount;
    }

    IKarma(karma).changeMechKarma(mech, int256(totalRequests));
    mapMechDeliveryCounts[mech] += totalRequests;
    numTotalRequests += totalRequests;

    IMech(mech).updateNumRequests(totalRequests);

    emit MarketplaceVoucherSettlement(mech, vouchers.length, totalRequests);

    _locked = 1;
}
```

For a batch of N requests across M requesters:
- M ecrecover calls (not N)
- M `mapSettledCumulative` writes (not N)
- M karma writes (not N+1)
- One aggregate event
- One `updateNumRequests` call on the mech

### 3.4 Off-chain interaction model

The wire protocol changes shape but stays HTTP-compatible.

**Today** (per-request signatures, mech-prepay):

```
client → mech: POST /send_signed_requests
                {request_id, ipfs_hash, sender, delivery_rate,
                 signature_over_requestId, ipfs_data}
mech → client: HTTP 200 { request_id }
mech batches; later submits deliverMarketplaceWithSignatures
```

**With cumulative vouchers**:

```
client → mech: POST /predict
                {ipfs_hash, tool, args, requested_rate, ipfs_data}
mech → client: HTTP 402 if no live voucher OR if would exceed current cumulative
                body: { scheme: "olas-voucher",
                        mech, current_cumulative, would_be_cumulative,
                        recommended_expiry, balance_tracker, eip712_domain }
client → mech: POST /predict
                same body + signed_voucher = {cumulative, expiry, v, r, s}
mech: verifies voucher off-chain (ecrecover matches client EOA;
       cumulative > last_accepted_cumulative; cumulative + delta <= deposit)
       runs tool, returns 200 { result, accepted_cumulative }
mech batches; later submits settleBatchByVouchers with one voucher per requester
```

Vouchers are accumulated mech-side. Each new request from the same client gets a fresh voucher that bumps `cumulativeAmount`. The mech only keeps the latest voucher per `(requester, mech)` pair, because the latest one supersedes everything before it.

### 3.5 What stays the same

- Funds live in `mapRequesterBalances`. Deposits are the existing `deposit` / `depositFor`. Withdraws (the new `withdrawRequester` from `mech_prepay_spec.md`) work unchanged.
- `processPaymentByMultisig` and fee carve-out work unchanged.
- Karma updates flow through the marketplace and require no new contracts.
- The existing `deliverMarketplaceWithSignatures` path coexists. Clients that want on-chain request records continue using it.

### 3.6 What changes for indexers

The `Deliver` event per delivery is gone in the voucher path. Replaced with:

```solidity
event VoucherSettled(address indexed mech, address indexed requester,
                     uint128 cumulativeAmount, uint256 delta);
event MarketplaceVoucherSettlement(address indexed mech, uint256 numVouchers, uint256 totalRequests);
```

Subgraphs that watch `MarketplaceDeliveryWithSignatures` for per-request tracking would need to either:
- Switch to `MarketplaceVoucherSettlement` for batch-level tracking (loses per-request granularity), or
- Continue indexing both events for clients that mix the two paths.

The per-request delivery data still exists off-chain (IPFS, mech's response store). It's just not echoed on-chain.

---

## 4. End-to-end flow

```
Phase 1, one-time deposit
─────────────────────────
Client EOA / Safe
    │  approve(BalanceTracker, X), depositFor(client, X)         ────▶  mapRequesterBalances[client] += X


Phase 2, off-chain request loop
───────────────────────────────
Request 1:
    Client → POST /predict { tool, prompt, ... }
    Mech → 402 { current_cumulative: 0, would_be_cumulative: 10200,
                 recommended_expiry: now+1h, ... }
    Client signs PrepayVoucher(mech, client, 10200, now+1h)
    Client → POST /predict { ..., voucher: {...} }
    Mech verifies voucher, runs tool, returns 200 { result }
    Mech stores: latestVoucher[(client, mech)] = {10200, expiry, sig}

Request 2:
    Client → POST /predict { ..., voucher: PrepayVoucher(mech, client, 20400, now+1h) }
    Mech verifies new cumulative > old (20400 > 10200), runs tool, returns 200
    Mech stores: latestVoucher[(client, mech)] = {20400, expiry, sig}

...repeat for N requests, each with cumulative = N × rate


Phase 3, batched on-chain settlement
────────────────────────────────────
Mech Safe accumulates latest voucher per requester. After batch window:

    Mech.settleBatchByVouchers([
        { requester: 0xAlice, cumulative: 20400, expiry, sig, requestCount: 2 },
        { requester: 0xBob,   cumulative: 51000, expiry, sig, requestCount: 5 },
        { requester: 0xCarol, cumulative: 10200, expiry, sig, requestCount: 1 },
        ...
    ])

Inside the contract:
    for each voucher v:
        BalanceTracker.settleByVoucher(...)
            verify EIP-712 sig                                   1 ecrecover
            check cumulative > settled[(requester, mech)]
            debit mapRequesterBalances[requester] by delta       1 SSTORE
            credit mapMechBalances[mech] by delta                1 SSTORE
            update settled[(requester, mech)] = cumulative       1 SSTORE
            emit VoucherSettled                                  1 LOG
        karma update per requester                                1 SSTORE
    aggregate karma update for mech
    aggregate updateNumRequests
    one MarketplaceVoucherSettlement event

For a 100-request, 50-requester batch: ~50 ecrecover, ~150 SSTORE total.
For comparison today: ~100 ecrecover, ~250 SSTORE.


Phase 4, optional withdraw
──────────────────────────
Client → BalanceTracker.withdrawRequester(amount)             ────▶  mapRequesterBalances[client] -= amount
                                                                     transfer(client, amount)
```

The voucher path makes settlement scale with **distinct requesters per batch**, not with total request count. A mech serving 1000 requests across 100 requesters pays roughly the same on-chain cost as serving 100 requests across 100 requesters.

---

## 5. Worked example

Setup:
- 3 clients (Alice, Bob, Carol), each deposits 0.50 USDC (500_000 atomic units) into the BalanceTracker
- Mech rate: 0.01 USDC per request (10_000 units)
- Quote: 0.0102 USDC after fee gross-up (10_200 units), per the chosen pricing policy
- Voucher expiry: 1 hour rolling window

Over the next 15 minutes:
- Alice makes 8 requests. Latest voucher: `cumulative = 81_600`
- Bob makes 3 requests. Latest voucher: `cumulative = 30_600`
- Carol makes 12 requests. Latest voucher: `cumulative = 122_400`

Each off-chain request: ~50 ms of mech compute, no on-chain anything.

At the 15-minute batch boundary, the mech Safe submits:

```
settleBatchByVouchers([
    { requester: Alice, cumulative: 81_600,  expiry, sig_A, requestCount: 8 },
    { requester: Bob,   cumulative: 30_600,  expiry, sig_B, requestCount: 3 },
    { requester: Carol, cumulative: 122_400, expiry, sig_C, requestCount: 12 }
])
```

On-chain:
- 3 ecrecover calls
- 9 SSTOREs (3 × `settled[..][..]`, 3 × `mapRequesterBalances[..]`, 3 × karma)
- 1 aggregate karma SSTORE
- 4 events (3 VoucherSettled + 1 MarketplaceVoucherSettlement)
- 1 transfer of 234_600 units into the BalanceTracker context (already there from deposits; this is just the bookkeeping)

`mapMechBalances[mech]` increases by 234_600. Fee carve-out at next `processPaymentByMultisig` works exactly as before.

Total settlement for 23 requests across 3 clients: ~250k gas. Compare to today's mech-prepay path: ~50k × 23 = 1.15M gas plus the loop overhead. Roughly 4-5x reduction.

---

## 6. What we need to build

### 6.1 Smart contracts

**Option V1, modify `BalanceTrackerFixedPriceToken` in place** (smaller, but mutates a live contract):

- Add `mapSettledCumulative` mapping
- Add `settleByVoucher` external function
- Add EIP-712 domain helpers + `VoucherExpired` / `NonMonotonicCumulative` / `InvalidVoucherSignature` errors
- Add `VoucherSettled` event
- Total: ~80 lines of new code in an existing contract

**Option V2, deploy `BalanceTrackerFixedPriceTokenVoucher` as a subclass**:

- Inherit `BalanceTrackerFixedPriceToken`
- Add the same logic
- New deployment, register against the same payment type via `setPaymentTypeBalanceTrackers`
- Migrate live balances OR run both trackers in parallel during transition
- Total: ~120 lines (including constructor)

**Marketplace** (`MechMarketplace.sol`):

- Add `settleBatchByVouchers(PrepayVoucher[] calldata)` external function
- Add `MarketplaceVoucherSettlement` event
- Add `IBalanceTrackerVoucher` interface reference
- Total: ~80 lines

**OlasMech** (`OlasMech.sol`):

- Add `settleBatchByVouchers(PrepayVoucher[] calldata) external onlyOperator` as a forwarder to `MechMarketplace.settleBatchByVouchers`
- Total: ~10 lines

### 6.2 Mech side

In `mech/packages/valory/skills/task_execution/handlers.py`:

- Add a new route `Route.SUBMIT_VOUCHERED_REQUEST` (or accept vouchers via the existing `/send_signed_requests` with a different body shape)
- Verify voucher off-chain: ecrecover the EIP-712 digest, check `cumulativeAmount > storedCumulative`, check `cumulativeAmount - storedCumulative <= mapRequesterBalances[requester] - encumbered` (if we want to be defensive, even without the encumbrance mapping)
- Store latest voucher per `(requester, mech)` in `synchronized_data`
- On 402: return a body with `current_cumulative`, `would_be_cumulative`, and EIP-712 domain info so the client SDK can construct the next voucher

In `mech/packages/valory/skills/task_submission_abci/behaviours.py`:

- Add a behaviour branch that collects latest vouchers per requester and submits `OlasMech.settleBatchByVouchers` instead of `deliverMarketplaceWithSignatures` when the new path is enabled
- Decide per mech instance whether to use the voucher path or the per-request path; controlled by a config flag

Estimated effort: ~300 lines of new behaviour code + tests.

### 6.3 Client side

**mech-client** (`mech_client/services/marketplace_service.py`):

- Add `_send_voucher_request` alongside the existing `_send_offchain_request`
- Track the latest signed voucher per `(requester, mech)` pair
- On 402: parse the voucher body, sign the next voucher, retry
- Add a `--use-voucher` CLI flag

Estimated effort: ~200 lines.

**mech-interact** (`mech_interact_abci/behaviours/`):

- Add a `MechVoucherRequestBehaviour` alongside the existing on-chain request behaviour
- Same voucher tracking as mech-client
- Same 402 handling

Estimated effort: ~300 lines.

### 6.4 Documentation deliverable

A small protocol note that documents:

- EIP-712 domain and type
- HTTP wire shapes for the 402 challenge and the voucher submission
- Voucher state semantics (cumulative monotonicity, expiry)

This is the public spec that lets third-party clients sign vouchers against our balance tracker.

---

## 7. Contract change summary

| Component | Change | Notes |
|-----------|--------|-------|
| `BalanceTrackerFixedPriceToken` | Add `settleByVoucher`, `mapSettledCumulative`, EIP-712 helpers (V1) | Or deploy subclass `BalanceTrackerFixedPriceTokenVoucher` (V2) |
| `MechMarketplace` | Add `settleBatchByVouchers` + event | New entry point, existing functions unchanged |
| `OlasMech` | Add `settleBatchByVouchers` forwarder | onlyOperator |
| `IBalanceTracker` | Add new interface variant | Or extend the existing interface |
| Karma | None | Receives aggregate updates per voucher batch |
| Fee logic | None | Runs unchanged on `mapMechBalances` |
| Existing payment families | None | All untouched |
| `BalanceTrackerX402` (if shipped) | None | Coexists, different payment type |
| `MppEscrow` (if shipped) | None | Coexists, different payment type |

Total Solidity surface added: ~200 lines, almost all inside the new voucher functions.

---

## 8. Known constraints

- **Per-request on-chain records go away on the voucher path.** Indexers that want per-request granularity must continue using `deliverMarketplaceWithSignatures`. Mixing both paths is supported; a single mech can use either depending on per-batch policy.
- **Voucher signatures are per-(requester, mech) pair.** A client using multiple mechs signs multiple vouchers. Each lives in its own `mapSettledCumulative[requester][mech]` slot.
- **Settlement race still exists.** A client can call `withdrawRequester` and drain `mapRequesterBalances` between voucher acceptance off-chain and on-chain settlement. The mech bears that risk per voucher delta. Mitigations: small batch windows, pre-settlement balance check, the encumbrance upgrade in Section 9.
- **Voucher expiry must cover the batch window.** If the mech batches every 15 minutes, voucher expiry should be at least 30 minutes to allow for retries. Mech advertises a recommended expiry in the 402 challenge.
- **No voucher revocation on-chain.** The only way to "revoke" a voucher is to wait for expiry. Clients should pick short expiries when they're not sure they want to keep paying.
- **Cumulative monotonicity is strict.** A voucher with `cumulativeAmount` equal to or less than the on-chain `settled` value reverts. This means clients must always increase the cumulative; you can't sign a "void" voucher.
- **One signature per batch period, not per request.** This is the UX improvement. Clients sign less frequently but each signature commits them to a larger cumulative.

---

## 9. Path to closing the settlement race (Phase 4)

The race-elimination property is what separates this spec from full MPP. To eliminate the race without an MPP escrow contract, the BalanceTracker would also track per-requester encumbrance:

```solidity
mapping(address => uint256) public mapEncumberedAmount;

function commitVoucher(
    address mech, address requester, uint128 cumulativeAmount, uint256 expiry,
    uint8 v, bytes32 r, bytes32 s
) external onlyMech {
    // Verify voucher signature
    // newEncumbered = cumulativeAmount - mapSettledCumulative[requester][mech]
    // mapEncumberedAmount[requester] += newEncumbered
    // store the committed voucher state for later settlement
}

function withdrawRequester(uint256 amount) external {
    uint256 free = mapRequesterBalances[msg.sender] - mapEncumberedAmount[msg.sender];
    if (amount > free) revert AmountEncumbered(amount, free);
    // ... withdraw ...
}
```

What this gives:

- Funds backing an accepted voucher are locked until that voucher is settled or expires
- `withdrawRequester` can only release `balance - encumbered`
- Settlement race eliminated: the mech can always claim against any committed voucher

What this costs:

- Two new on-chain state updates per voucher (commit + settle), instead of one
- More complex expiry handling: encumbrance must release automatically when a voucher expires unsettled
- Roughly doubles the contract code added by this spec

At this point we've structurally reinvented MPP. The encumbrance map mirrors `MppEscrow.channels[id].deposit - settled`. The voucher format mirrors MPP's voucher. The commit/settle split mirrors MPP's accept/settle. The honest framing once we reach Phase 4 is: **we built MPP inside the BalanceTracker rather than as a separate contract.** Both work; the deciding factors are audit boundaries and naming.

If Phase 4 turns out to be needed, the recommended move is to ship `mpp_session_spec.md` rather than build MPP into the BalanceTracker. The MPP spec gives a clean separation of concerns, a recognizable name, and the same outcome.

---

## 10. Comparison vs the other proposals

| Property | mech-prepay (current) | This spec (voucher) | + multi-requester batching | MPP session |
|----------|-----------------------|---------------------|----------------------------|-------------|
| On-chain sig verifies per batch | N (one per request) | M (one per requester) | M (combined across mechs) | M (one per voucher) |
| On-chain storage writes per batch | ~3N | ~3M | ~3M | ~3M |
| Per-request on-chain records | Yes | No | No | No |
| Settlement race | Yes, bounded by maxRate | Yes, bounded by maxRate | Yes, bounded by maxRate | No |
| New escrow contract | No | No | No | Yes |
| Standardization | Valory-only | Valory-only | Valory-only | IETF-track framework, EVM session is Valory extension |
| Total new Solidity | ~10-30 lines (mech-prepay) | +~200 lines | +~150 lines | +~400 lines (MppEscrow + tracker + factory + mech) |
| Audit incremental cost | Smallest | Modest | Modest | Larger |

The voucher spec sits exactly between mech-prepay and MPP session on the scaling axis. It captures most of MPP's settlement efficiency without the structural complexity of an escrow contract.

---

## 11. Testing strategy

### 11.1 Contract tests

1. Happy path: client deposits, signs voucher, mech settles, balances update correctly
2. Cumulative monotonicity: voucher with `cumulativeAmount <= settled` reverts
3. Expiry: voucher submitted after expiry reverts
4. Mech binding: voucher signed for Mech A cannot be settled against Mech B (sig won't recover)
5. Insufficient balance: settling more than `mapRequesterBalances[requester]` reverts atomically
6. Coexistence: an active voucher path and an active `deliverMarketplaceWithSignatures` path on the same balance tracker do not interfere with each other
7. Cross-mech: same requester signs vouchers for two mechs; both can settle independently
8. Fee accounting: `processPaymentByMultisig` works on `mapMechBalances` after voucher settlement

### 11.2 End-to-end integration

1. Hardhat fork with USDC + new contracts
2. Use mech-client with `--use-voucher` to make N requests
3. Verify off-chain: each request gets a 200 with the latest accepted cumulative
4. Trigger mech batch settlement, verify on-chain `mapMechBalances` and `mapRequesterBalances` reflect the cumulative
5. Verify the `VoucherSettled` event count matches the number of distinct requesters (not the number of requests)

---

## 12. References

- `docs/mech_prepay_spec.md`, the baseline this builds on
- `docs/multi_requester_batching_spec.md` (to be written), the orthogonal change that batches across requesters
- `docs/x402_spec.md`, the per-request EIP-3009 alternative
- `docs/mpp_session_spec.md`, the full MPP session alternative
- `docs/x402_vs_mpp.md`, the decision guide between the two ecosystem-protocol options
- `contracts/mechs/token/BalanceTrackerFixedPriceToken.sol`, where the voucher functions land
- `mech/packages/valory/skills/task_execution/handlers.py`, the mech HTTP handler
- `mech-client/mech_client/services/marketplace_service.py`, the existing HTTP off-chain integration that gets a voucher branch
