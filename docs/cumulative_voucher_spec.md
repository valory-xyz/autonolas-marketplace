# Cumulative Voucher Settlement with Encumbered Channels

## 1. Overview

This spec extends `mech_prepay_spec.md` with three properties that make it a serious scaling path:

1. **Race elimination.** Funds backing accepted vouchers are encumbered inside the BalanceTracker and cannot be withdrawn until the channel is closed or vouchers expire. The mech is guaranteed it can settle against any voucher it accepted off-chain.
2. **Constant-cost settlement.** A single EIP-712 voucher commits a cumulative amount per `(requester, mech)` pair. One ecrecover + one storage write per requester per batch, regardless of how many off-chain requests it represents.
3. **Fail-soft batched settlement.** One bad voucher in a batch does not revert the whole transaction. Each voucher is settled inside a `try`/`catch`; failures emit an event and do not affect the other vouchers.

The on-chain pattern is functionally MPP session: open a channel, accumulate cumulative vouchers, batched settle, close. The difference is structural: channels live inside `BalanceTrackerFixedPriceToken` rather than a separate `MppEscrow` contract. One contract, one audit boundary, one upgrade path.

Delivery data (request bodies, results) is persisted on the mech side using the agent's `synchronized_data` plus an optional Postgres store, mirroring `wildcard/server/src/session/store.py`. The on-chain trace is purely settlement; per-request records and `Deliver` events are not emitted.

### Design intent

| Goal | How this spec meets it |
|------|------------------------|
| Eliminate the settlement race that mech-prepay has | Channel deposit is encumbered; withdraw cannot touch encumbered funds |
| Make settlement constant-cost per requester | Cumulative voucher: one signature, one storage write, one transfer per requester per batch |
| Handle bad vouchers gracefully in a multi-requester batch | Per-voucher `try`/`catch`; failures emit events, do not revert |
| Avoid a separate escrow contract | Channels live as a mapping inside the BalanceTracker |
| Stay on the existing `paymentType` registry | New BalanceTracker variant registered against a distinct payment type, marketplace and OlasMech untouched |
| Match wildcard's response-persistence pattern | Mech-side Postgres-style store, no on-chain delivery records needed |

### Relationship to the other specs

This is the next layer after `mech_prepay_spec.md`. It can be shipped as v2 or as v1 directly if race elimination is required from day one.

It is structurally close to `mpp_session_spec.md` but does NOT aim for MPP protocol compatibility (no MPPscan listing, no mppx client support). If protocol compatibility becomes important later, the migration from this spec to MPP session is small because the on-chain shapes are nearly identical.

---

## 2. The two problems being solved

### 2.1 Why the existing race is unacceptable at scale

In plain mech-prepay or `cumulative_voucher` without encumbrance, the mech can accept a voucher off-chain, return the result to the client at HTTP 200, then attempt to settle on-chain. Between those two moments the client can call `withdrawRequester` and drain `mapRequesterBalances`. The mech's settlement reverts with `InsufficientBalance`. The mech ate the cost of running the tool.

Per-request the exposure is bounded by `maxDeliveryRate` (around $0.05 for typical AI tool calls). But across a busy mech serving thousands of requests per day, the cumulative griefing risk is real. A client could deliberately submit a request, wait for the result, then sweep their balance before the batch cycle. Repeated, this becomes a denial-of-payment attack on the mech.

The structural fix is to lock the funds backing accepted vouchers BEFORE the off-chain acceptance, not after.

### 2.2 Why atomic batch revert is unacceptable

Today's `deliverMarketplaceWithSignatures` reverts the entire batch if any single delivery fails. Failure modes include bad signatures, expired vouchers, insufficient balance for that specific requester, and duplicate request IDs.

In a multi-requester batch, this is a denial-of-service vector. If a single requester signs a bad voucher (intentionally or by mistake), the mech's entire batch settlement reverts, all other requesters' deliveries get rejected, and the mech has to re-batch without that requester.

In a high-volume mech with 100 requesters in a 5-minute window, one bad voucher torches 99 others.

The fix is per-voucher isolation at settle time. Each voucher's settlement attempt is independent; failures emit events and don't revert the rest.

---

## 3. Proposed solution

### 3.1 PrepayChannel state, lives inside the BalanceTracker

Each `(payer, mech)` pair has a channel record. One mapping inside the existing BalanceTracker contract; no separate escrow contract.

```solidity
struct PrepayChannel {
    uint128 deposit;       // total committed to this channel
    uint128 settled;       // cumulative already settled on-chain
    uint64 expiry;         // unix timestamp; after this, payer can forceClose
    uint64 closeRequestedAt;  // 0 = not requested; nonzero = closing pending
    bool finalized;        // true once close has executed
}

// keyed by keccak256(payer, mech), the natural channel id
mapping(bytes32 => PrepayChannel) public mapChannels;
```

The funds backing the channel deposit live in the BalanceTracker's existing token balance. No separate token vault. The channel struct is just bookkeeping.

### 3.2 Channel lifecycle

Four entry points on the BalanceTracker, all routed via the marketplace's existing access pattern (`onlyMarketplace`-style) where appropriate.

**openChannel** (called by payer or via marketplace forwarder):

```solidity
function openChannel(address mech, uint128 deposit, uint64 expiry)
    external returns (bytes32 channelId)
{
    if (deposit == 0) revert ZeroValue();
    if (expiry <= block.timestamp) revert PastExpiry(expiry);

    channelId = keccak256(abi.encode(msg.sender, mech, address(this), block.chainid));
    if (mapChannels[channelId].deposit != 0) revert ChannelAlreadyOpen(channelId);

    // Pull funds from the payer's free balance into the channel.
    // Either the payer already has mapRequesterBalances credit OR they
    // pass through approve+transferFrom; both are supported via overloads.
    if (mapRequesterBalances[msg.sender] < deposit)
        revert InsufficientBalance(mapRequesterBalances[msg.sender], deposit);
    mapRequesterBalances[msg.sender] -= deposit;
    mapEncumberedAmount[msg.sender] += deposit;

    mapChannels[channelId] = PrepayChannel({
        deposit: deposit,
        settled: 0,
        expiry: expiry,
        closeRequestedAt: 0,
        finalized: false
    });

    emit ChannelOpened(msg.sender, mech, channelId, deposit, expiry);
}
```

After `openChannel`, the `deposit` is moved from the payer's free `mapRequesterBalances` slot to the encumbered slot. `withdrawRequester` can still drain the free portion but cannot touch the channel deposit.

**settleByVoucher** (called by the marketplace inside the settlement batch):

```solidity
function settleByVoucher(
    address mech,
    address requester,
    uint128 cumulativeAmount,
    bytes calldata voucherSig
) external returns (uint256 delta) {
    if (_locked == 2) revert ReentrancyGuard();
    _locked = 2;

    if (msg.sender != mechMarketplace) revert MarketplaceOnly(msg.sender, mechMarketplace);

    bytes32 channelId = keccak256(abi.encode(requester, mech, address(this), block.chainid));
    PrepayChannel storage ch = mapChannels[channelId];

    if (ch.deposit == 0) revert ChannelNotOpen(channelId);
    if (ch.finalized) revert ChannelFinalized(channelId);
    if (block.timestamp > ch.expiry) revert VoucherExpired(ch.expiry);
    if (cumulativeAmount <= ch.settled)
        revert NonMonotonicCumulative(cumulativeAmount, ch.settled);
    if (cumulativeAmount > ch.deposit)
        revert ExceedsDeposit(cumulativeAmount, ch.deposit);

    // Verify EIP-712 voucher
    bytes32 digest = _voucherDigest(mech, requester, cumulativeAmount, ch.expiry, channelId);
    address signer = _recoverVoucherSigner(digest, voucherSig);
    if (signer != requester) revert InvalidVoucherSignature(signer, requester);

    delta = uint256(cumulativeAmount - ch.settled);
    ch.settled = cumulativeAmount;

    // Move from encumbered to mech balance. mapRequesterBalances was already
    // debited at openChannel; we're just moving inside the BalanceTracker.
    mapEncumberedAmount[requester] -= delta;
    mapMechBalances[mech] += delta;

    emit VoucherSettled(mech, requester, channelId, cumulativeAmount, delta);

    _locked = 1;
}
```

**closeChannel** (called by marketplace forwarder on behalf of mech, or by payer after timeout):

```solidity
function closeChannel(
    bytes32 channelId,
    uint128 finalCumulative,
    bytes calldata voucherSig    // optional: latest accepted voucher, settles before closing
) external {
    // ... reentrancy guard ...

    PrepayChannel storage ch = mapChannels[channelId];
    if (ch.deposit == 0) revert ChannelNotOpen(channelId);
    if (ch.finalized) revert ChannelFinalized(channelId);

    address payer = _payerFromChannelId(channelId, mech);  // recovered from the channelId derivation

    // If a final voucher is provided, settle it first
    if (finalCumulative > ch.settled) {
        // Same verification + delta transfer as settleByVoucher
        // ...
    }

    // Refund the unspent encumbrance back to free balance
    uint128 unspent = ch.deposit - ch.settled;
    mapEncumberedAmount[payer] -= unspent;
    mapRequesterBalances[payer] += unspent;

    ch.finalized = true;
    emit ChannelClosed(payer, mech, channelId, ch.settled, unspent);
}
```

**requestClose** + **forceClose** (payer's safety valve):

```solidity
function requestClose(bytes32 channelId) external {
    PrepayChannel storage ch = mapChannels[channelId];
    address payer = _payerFromChannelId(channelId, ???);
    if (msg.sender != payer) revert UnauthorizedAccount(msg.sender);
    if (ch.finalized) revert ChannelFinalized(channelId);
    ch.closeRequestedAt = uint64(block.timestamp);
    emit ChannelCloseRequested(payer, channelId);
}

function forceClose(bytes32 channelId) external {
    PrepayChannel storage ch = mapChannels[channelId];
    address payer = _payerFromChannelId(channelId, ???);
    if (msg.sender != payer) revert UnauthorizedAccount(msg.sender);
    if (ch.finalized) revert ChannelFinalized(channelId);
    if (ch.closeRequestedAt == 0) revert CloseNotRequested();
    if (block.timestamp < ch.closeRequestedAt + CLOSE_TIMEOUT)
        revert CloseTimeoutNotReached(ch.closeRequestedAt + CLOSE_TIMEOUT, block.timestamp);

    uint128 unspent = ch.deposit - ch.settled;
    mapEncumberedAmount[payer] -= unspent;
    mapRequesterBalances[payer] += unspent;
    ch.finalized = true;
    emit ChannelClosed(payer, mech, ???, ch.settled, unspent);
}
```

`CLOSE_TIMEOUT` recommended at 24 hours. Gives the mech a window to settle accepted vouchers before the payer can unilaterally pull funds out.

> Note on the channelId design: the channel id is derived from `keccak256(payer, mech, balanceTrackerAddress, chainId)`. This means the payer can be recovered if the function takes `mech` as an argument, or vice versa, but not both from the id alone. The full implementation needs an auxiliary mapping `channelId => payer` to make `requestClose` / `forceClose` work without the mech argument. Skipping the detail in this draft; the contract should store `payer` and `mech` directly in the `PrepayChannel` struct.

### 3.3 PrepayVoucher EIP-712 type

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

The channelId binds the voucher to a specific channel. No need for a separate expiry on the voucher because the channel itself has an expiry.

### 3.4 Marketplace entry point with fail-soft batch settlement

```solidity
struct PrepayVoucherInput {
    address requester;
    bytes32 channelId;
    uint128 cumulativeAmount;
    uint256 requestCount;        // off-chain delivery count this voucher covers
    bytes voucherSig;
}

event MarketplaceVoucherSettlement(
    address indexed mech,
    uint256 totalVouchers,
    uint256 totalSuccessful,
    uint256 totalRequests
);

event VoucherSettlementFailed(
    address indexed mech,
    address indexed requester,
    bytes32 indexed channelId,
    uint128 cumulativeAmount,
    bytes reason
);

function settleBatchByVouchers(PrepayVoucherInput[] calldata vouchers) external {
    if (_locked == 2) revert ReentrancyGuard();
    _locked = 2;

    address mech = msg.sender;
    checkMech(mech);

    bytes32 paymentType = IMech(mech).paymentType();
    address balanceTracker = mapPaymentTypeBalanceTrackers[paymentType];
    if (balanceTracker == address(0)) revert ZeroAddress();

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
            emit VoucherSettlementFailed(mech, v.requester, v.channelId, v.cumulativeAmount, reason);
            // continue, no revert
        }
    }

    if (totalSuccessfulRequests > 0) {
        IKarma(karma).changeMechKarma(mech, int256(totalSuccessfulRequests));
        mapMechDeliveryCounts[mech] += totalSuccessfulRequests;
        numTotalRequests += totalSuccessfulRequests;
        IMech(mech).updateNumRequests(totalSuccessfulRequests);
    }

    emit MarketplaceVoucherSettlement(mech, vouchers.length, totalSuccessful, totalSuccessfulRequests);

    _locked = 1;
}
```

For a batch with one bad voucher in 50, you get 49 successful settlements and one `VoucherSettlementFailed` event. The transaction completes. No DOS vector.

The per-voucher try/catch is the structural fix for atomic-batch problem. It's safe because `settleByVoucher` has its own reentrancy guard and is idempotent on success (it advances `settled[channel]`). A failure leaves the channel state unchanged.

### 3.5 Mech-side response persistence (no on-chain delivery records)

Following the wildcard pattern (`wildcard/server/src/session/store.py`), the mech persists delivery data outside the blockchain.

Two layers:

**Layer 1, `synchronized_data` (already exists in open-autonomy):**
- Channel state per active `(requester, mech)` pair: `{channelId, deposit, expiry, highestAcceptedCumulative, lastSettledOnChain, latestVoucherSig}`
- Pending voucher acceptance log: list of accepted vouchers waiting for the next batch settlement
- Survives agent restart and is consistent across the ensemble

**Layer 2, optional Postgres (or any durable store) for delivery results:**
- `(request_id, requester, channel_id, cumulative_at_acceptance, ipfs_hash_of_result, accepted_at)` per off-chain request
- This is what wildcard does in production. Mirrors that.
- Indexed by request_id so clients can poll for results via the existing HTTP `GET /fetch_offchain_info` route
- Does not need to be on the critical path of settlement; it's a record-keeping store

**No on-chain `Deliver` events per request.** The only on-chain events from this flow are:
- `ChannelOpened` (per channel open)
- `VoucherSettled` (per successful voucher in a batch)
- `VoucherSettlementFailed` (per failed voucher in a batch)
- `MarketplaceVoucherSettlement` (one per batch)
- `ChannelClosed` (per channel close)

Subgraphs that want per-request data must consume the mech's Postgres store directly or hit the mech HTTP API. This is acceptable because clients (mech-client, mech-interact, browser-style agents) already poll the mech's HTTP endpoint for results, not the subgraph.

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
                                                ────▶ moves Y from
                                                       mapRequesterBalances[client]
                                                       to mapEncumberedAmount[client]
                                                ────▶ mapChannels[channelId] = {
                                                          deposit: Y, settled: 0,
                                                          expiry: now+24h, ...
                                                       }
                                                ────▶ ChannelOpened event


Phase 3, off-chain request loop (no on-chain anything)
──────────────────────────────────────────────────────
Request 1:
   Client → POST /predict { tool, prompt, ... }
   Mech → 402 { scheme: "olas-prepay-voucher",
                channelId, eip712_domain,
                current_cumulative: 0,
                would_be_cumulative: 10200 }
   Client signs PrepayVoucher(mech, client, channelId, 10200)
   Client → POST /predict { ..., voucher: {...} }
   Mech verifies signature, cumulative monotonicity, cumulative ≤ channel.deposit
   Mech runs tool, returns 200 { result, accepted_cumulative: 10200 }
   Mech persists:
      synchronized_data: latestVoucher[(client, mech)] = {10200, sig}
      Postgres: (request_id_1, client, channelId, 10200, ipfs_hash, now)

Request 2..N:
   Same shape; each new voucher bumps cumulative by `quote`
   At the end of N requests: latestVoucher = {N × 10200, sig_N}


Phase 4, batched on-chain settlement with fail-soft
───────────────────────────────────────────────────
Mech Safe collects latest voucher per active (requester, mech) pair.
Per batch window:

   OlasMech.settleBatchByVouchers([
      { requester: 0xAlice, channelId: cA, cumulative: 81600,  count: 8,  sig: sA },
      { requester: 0xBob,   channelId: cB, cumulative: 30600,  count: 3,  sig: sB },
      { requester: 0xCarol, channelId: cC, cumulative: 122400, count: 12, sig: sC },
      ...
   ])

   ────▶ MechMarketplace.settleBatchByVouchers
         for each voucher:
            try BalanceTracker.settleByVoucher(...)
               on success:
                  debit mapEncumberedAmount[requester] by delta
                  credit mapMechBalances[mech] by delta
                  set mapChannels[channelId].settled = cumulative
                  karma + counter updates for that requester
               on failure:
                  emit VoucherSettlementFailed; continue

         aggregate karma + counter updates for mech
         emit MarketplaceVoucherSettlement


Phase 5, channel close (whenever)
─────────────────────────────────
Happy path, mech-initiated:
   Mech Safe submits BalanceTracker.closeChannel(channelId, finalCumulative, finalSig)
                                                ────▶ settles the last voucher first
                                                ────▶ refunds (deposit - finalCumulative) to
                                                       mapRequesterBalances[client]
                                                ────▶ marks channel.finalized = true
                                                ────▶ ChannelClosed event

Safety path, payer-initiated:
   Client → BalanceTracker.requestClose(channelId)        emits ChannelCloseRequested
   (wait CLOSE_TIMEOUT = 24h)
   Client → BalanceTracker.forceClose(channelId)          refunds residual, marks finalized

Phase 6, withdraw free balance (existing mech-prepay)
─────────────────────────────────────────────────────
Client → BalanceTracker.withdrawRequester(amount)
                                                ────▶ allowed only on
                                                      mapRequesterBalances[client]
                                                      minus mapEncumberedAmount[client]
                                                ────▶ refunds USDC to client wallet
```

The race is gone. The atomic batch is gone. Per-request on-chain records are gone (replaced by mech-side Postgres).

---

## 5. Worked example

Setup:
- Alice has $1.00 deposited in the BalanceTracker. `mapRequesterBalances[Alice] = 1_000_000`. Encumbered: 0.
- Mech rate: $0.01 per request. Quote (Policy A): $0.01 = 10_000 units.
- Alice opens a channel with the mech: `openChannel(mech, deposit=500_000, expiry=now+24h)`.
  - `mapRequesterBalances[Alice]` = 500_000 (free, withdrawable)
  - `mapEncumberedAmount[Alice]` = 500_000 (locked, NOT withdrawable)
  - `mapChannels[cA].deposit = 500_000`, `settled = 0`

Over the next 15 minutes, Alice makes 8 requests:
- Each request, Alice signs a fresh voucher with the next cumulative
- After 8 requests: `latestVoucher = 80_000, sig_8`
- 0 on-chain transactions during these 15 minutes
- Mech persists results in Postgres keyed by request_id

If Alice tries to drain her free balance during the 15 minutes:
- `withdrawRequester(amount)` is allowed up to `mapRequesterBalances[Alice] - mapEncumberedAmount[Alice]` = `500_000 - 0` (free balance only, encumbrance is independent of free)
- Wait, the actual check is: `mapRequesterBalances[Alice] >= amount`. The encumbrance was already subtracted at openChannel.
- So Alice can withdraw up to 500_000 (her free balance)
- She CANNOT touch the channel's 500_000 deposit
- Mech is safe: vouchers up to 500_000 are guaranteed claimable

At the 15-minute batch boundary, mech submits:
```
settleBatchByVouchers([
  { requester: Alice, channelId: cA, cumulative: 80_000, count: 8, sig: sig_8 }
])
```

Inside the contract:
- voucher signature verified
- `cumulative (80_000) > settled (0)` ✓
- `cumulative (80_000) ≤ deposit (500_000)` ✓
- delta = 80_000
- `mapEncumberedAmount[Alice] -= 80_000`  (now 420_000)
- `mapMechBalances[mech] += 80_000`
- `mapChannels[cA].settled = 80_000`
- karma + counter updates

Now Alice's state:
- `mapRequesterBalances[Alice]` = 500_000 (free)
- `mapEncumberedAmount[Alice]` = 420_000 (channel residual)
- Channel `cA`: deposit 500_000, settled 80_000

She continues making requests, channel cycles, until eventually:

Alice (or mech) decides to close:
- Mech calls `closeChannel(cA, 92_000, sig_latest)` if there's one more voucher to settle
- BalanceTracker settles the last voucher (delta = 12_000), then refunds 500_000 - 92_000 = 408_000 back to `mapRequesterBalances[Alice]`
- Now Alice has free balance = 500_000 + 408_000 = 908_000 and 0 encumbered

Alice withdraws what she wants via `withdrawRequester`.

Total on-chain transactions for 9 requests: 1 deposit + 1 openChannel + 1 batched settle + 1 closeChannel = 4 transactions, regardless of how many requests Alice made within the channel.

---

## 6. What we need to build

### 6.1 Smart contracts

**BalanceTrackerFixedPriceTokenChannel** (extends `BalanceTrackerFixedPriceToken`):

- New mappings: `mapChannels`, `mapEncumberedAmount`
- New events: `ChannelOpened`, `VoucherSettled`, `VoucherSettlementFailed`, `ChannelCloseRequested`, `ChannelClosed`
- New functions: `openChannel`, `settleByVoucher` (called only by marketplace), `closeChannel`, `requestClose`, `forceClose`
- Override `withdrawRequester` to enforce `amount <= mapRequesterBalances - 0` (since encumbered is already separated at openChannel, withdraw on free balance is naturally safe; only condition is `mapRequesterBalances[msg.sender] >= amount`)
- EIP-712 domain + voucher digest helper
- Custom errors: `ChannelAlreadyOpen`, `ChannelNotOpen`, `ChannelFinalized`, `VoucherExpired`, `NonMonotonicCumulative`, `ExceedsDeposit`, `InvalidVoucherSignature`, `CloseNotRequested`, `CloseTimeoutNotReached`, `PastExpiry`

Total: ~300 lines.

**MechMarketplace**:

- Add `settleBatchByVouchers(PrepayVoucherInput[])` with per-voucher try/catch
- Add `MarketplaceVoucherSettlement` event
- Add `IBalanceTrackerChannel` interface reference
- Forward `openChannel` / `closeChannel` / `requestClose` / `forceClose` so callers can hit the marketplace as the front door if desired (optional; direct calls to the BalanceTracker also work)

Total: ~100 lines.

**OlasMech**:

- Add `settleBatchByVouchers(PrepayVoucherInput[]) external onlyOperator` forwarder

Total: ~10 lines.

**Registration**:

```solidity
mechMarketplace.setPaymentTypeBalanceTrackers(
    [keccak256("MECH_PREPAY_CHANNEL_USDC")],
    [BalanceTrackerFixedPriceTokenChannel_address]
);
```

### 6.2 Mech side

In `mech/packages/valory/skills/task_execution/handlers.py`:

- New routes:
  - `POST /open_channel_hint`: returns the data a client needs to call `openChannel` (channelId derivation, recommended deposit, EIP-712 domain)
  - `POST /submit_voucher`: accepts a voucher-bearing request body, verifies the EIP-712 signature, checks `cumulative > storedCumulative`, checks `cumulative <= channelDeposit`, runs the tool
- Existing `/send_signed_requests` route stays for backwards compat (per-request signature path)
- Existing `/fetch_offchain_info` route stays for response polling

In `mech/packages/valory/skills/task_submission_abci/behaviours.py`:

- New behaviour: collect latest voucher per `(requester, mech)` pair from synchronized_data, build the `PrepayVoucherInput[]` array, submit via `OlasMech.settleBatchByVouchers`
- Coexists with the existing per-request signature batching; mech operator chooses one or both

In `mech/packages/valory/skills/.../synchronized_data.py` (or wherever the persistent state lives):

- Add channel-state slot: per active channel, store `{channelId, deposit, expiry, highestAcceptedCumulative, lastSettledOnChain, latestVoucherSig}`
- Add a pending voucher acceptance log

Add optional Postgres-backed response store. The mech operator deploys Postgres alongside the mech. Schema:

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

Estimated effort: ~500 lines of new behaviour + handler code, plus the Postgres adapter.

### 6.3 Client side

**mech-client** (`mech_client/services/marketplace_service.py`):

- Add `_send_voucher_request` alongside the existing `_send_offchain_request`
- Build channel open flow: client signs an `openChannel` transaction once per (mech, expiry) tuple
- Track latest signed voucher per `(requester, mech)` pair in local state
- Handle the `submit_voucher` 402: parse the voucher hint, sign the next voucher, retry
- Add CLI commands: `mech-client open-channel`, `mech-client close-channel`, `mech-client request-close`

Estimated effort: ~400 lines.

**mech-interact** (`mech_interact_abci/behaviours/`):

- New `MechVoucherChannelBehaviour`: manages channel state in `synchronized_data`, signs vouchers, submits via HTTP
- New params: `mech_http_url`, `prefer_voucher_path`, `default_channel_deposit`, `default_channel_expiry_hours`
- Reuse the existing approval / deposit multisend helper

Estimated effort: ~400 lines.

### 6.4 Total scope

| Layer | Lines | Notes |
|-------|-------|-------|
| `BalanceTrackerFixedPriceTokenChannel.sol` | ~300 | New subclass with channels + vouchers |
| `MechMarketplace.sol` | ~100 added | `settleBatchByVouchers` + event |
| `OlasMech.sol` | ~10 added | Forwarder |
| `IBalanceTracker*.sol` | ~50 added | New interface for the channel-tracker |
| Mech behaviour | ~500 | HTTP routes + batch settlement + state |
| Mech Postgres adapter | ~150 | Schema + queries |
| mech-client adapter | ~400 | Voucher signing, channel lifecycle CLI |
| mech-interact behaviour | ~400 | Voucher signing, channel lifecycle |
| **Total new code** | **~1900 lines** | |

Compare to MPP session spec: roughly comparable lines, one fewer contract (no separate escrow), one fewer audit boundary.

---

## 7. Contract change summary

| Component | Change | Notes |
|-----------|--------|-------|
| `BalanceTrackerFixedPriceTokenChannel` | New subclass | Adds channels + voucher settlement; ~300 lines |
| `MechMarketplace` | Add `settleBatchByVouchers` + event | Per-voucher try/catch makes batch fail-soft |
| `OlasMech` | Add forwarder | `onlyOperator` |
| `BalanceTrackerBase` | None | All hooks already exist |
| `BalanceTrackerFixedPriceToken` | None | Parent class, unchanged |
| Karma | None | Receives per-requester + aggregate updates |
| Fee logic | None | `processPaymentByMultisig` works on `mapMechBalances` as today |
| Existing payment families | None | All untouched, coexist via the registry |

The marketplace gets one new function. Otherwise the marketplace core is untouched.

---

## 8. Known constraints (genuine ones, not race or batch)

The constraints that DO remain:

- **Channel deposit upfront.** Clients commit USDC to a specific mech when they call `openChannel`. The committed amount is locked until the channel closes (cooperatively) or until the payer waits out `CLOSE_TIMEOUT` and force-closes. This is the cost of race elimination.
- **Per-channel scope.** A channel binds a specific `(payer, mech)` pair. A client talking to N mechs opens N channels. Each is independent.
- **Channel expiry.** Pick a window the mech can settle within. Recommended: 24 hours. The channel's `expiry` field is independent of any per-voucher expiry; the voucher is bound to the channel and inherits the channel's expiry.
- **No on-chain per-request records.** As designed. Mech-side Postgres is the source of truth for delivery details. Subgraph indexers watching `MarketplaceDeliveryWithSignatures` won't see voucher-path traffic.
- **Operator key surface.** The mech Safe submits `settleBatchByVouchers` and (optionally) `closeChannel`. Same trust model as today's mech Safe ops; no new keys.
- **Voucher monotonicity is strict on-chain.** If two batched settlement attempts happen simultaneously with the same cumulative (very unlikely operational mistake), one wins, the other emits `VoucherSettlementFailed` with `NonMonotonicCumulative`. The mech reconciles off-chain.

The constraints that this spec EXPLICITLY removes:

- ~~Settlement race~~ eliminated by encumbrance
- ~~Atomic batch revert~~ eliminated by per-voucher try/catch in `settleBatchByVouchers`
- ~~Need on-chain per-request records~~ replaced by Postgres-backed mech-side store

---

## 9. Honest comparison vs MPP session

This spec gives you everything MPP session gives you, structurally, with these differences:

| Aspect | This spec | MPP session |
|--------|-----------|-------------|
| Fund custody contract | BalanceTracker (existing) | MppEscrow (new) |
| Channel state location | `mapChannels` inside BalanceTracker | `channels` inside MppEscrow |
| Voucher format | Same EIP-712 shape, Olas-specific domain | Same EIP-712 shape, MPP / Tempo-specific domain |
| Cumulative monotonicity | Enforced on-chain | Enforced on-chain |
| Settlement race | Eliminated | Eliminated |
| Atomic batch revert | Eliminated via try/catch | Not addressed in MPP spec (could be added) |
| Per-request on-chain records | None (intentional) | None |
| Audit boundary | One contract (the BalanceTracker) | Two contracts (MppEscrow + BalanceTrackerMppSession) |
| MPP protocol compatibility | None | Partial (we're extending MPP for EVM, see `mpp_session_spec.md` §1 caveat) |
| Discoverable on MPPscan | No (would need OpenAPI doc add-on) | No (would need same OpenAPI add-on) |
| Standardization | Valory-only | IETF-track framework, Valory extension of session intent on EVM |

Practically the same outcome. The decision between this and MPP session reduces to:

- **Choose this spec** if you want one contract to audit, no MPP terminology, and a clean integration with the existing Olas marketplace + BalanceTracker.
- **Choose MPP session** if you specifically want to be named "MPP" externally, or if you anticipate wanting MPPscan integration / `mppx` client compatibility later (even then, this spec can add an OpenAPI doc to be discoverable, just not protocol-compatible).

Given the constraint that we don't need MPP protocol compatibility, this spec is the recommended path. It's MPP's outcome without the structural separation cost.

---

## 10. Testing strategy

### 10.1 Contract tests

1. **Happy path channel lifecycle**: open → 5 vouchers off-chain → batched settle → close. Balances correct end to end.
2. **Encumbrance enforcement**: open channel for $0.50, try `withdrawRequester` for more than free balance, expect revert.
3. **Voucher monotonicity**: settle voucher at cumulative 100, try to settle at cumulative 100 again, expect `NonMonotonicCumulative` event from try/catch.
4. **Cumulative exceeds deposit**: voucher with `cumulative > channel.deposit`, expect `VoucherSettlementFailed`.
5. **Channel expiry**: voucher submitted after expiry, expect `VoucherExpired`.
6. **Forged signature**: voucher signed by attacker, not the payer, expect `InvalidVoucherSignature`.
7. **Channel finalized**: settle after `closeChannel` called, expect `ChannelFinalized`.
8. **forceClose timeout**: try `forceClose` before `CLOSE_TIMEOUT` elapsed, expect revert.
9. **Atomic batch isolation**: submit a batch of 5 vouchers, 1 bad (expired). 4 successful, 1 emits `VoucherSettlementFailed`. Transaction succeeds. Verify `mapMechBalances` reflects only the 4 successful settlements.
10. **Fee accounting**: `processPaymentByMultisig` works on the accumulated `mapMechBalances` after batched voucher settlement.
11. **Reentrancy**: malicious token reenters during `transfer`, blocked by `_locked`.
12. **Multi-mech**: Alice opens channels with Mech A and Mech B simultaneously, both settle independently, encumbrance tracks each.

### 10.2 End-to-end integration

1. Hardhat fork with USDC + new contracts deployed
2. mech-client `--use-voucher`: opens channel, sends 5 requests, mech batch-settles, channel closes
3. Verify all events emitted: `ChannelOpened`, 5 `VoucherSettled`, `MarketplaceVoucherSettlement`, `ChannelClosed`
4. Verify Postgres has 5 rows for the requests with correct ipfs hashes
5. Verify final `mapRequesterBalances[client]` includes the refunded residual

### 10.3 Adversarial tests

1. Race-elimination test: client tries to `withdrawRequester` after the mech has accepted vouchers but before settlement. Withdraw is bounded to free balance. Mech still successfully settles encumbered amount.
2. Fail-soft test: 100-voucher batch with 10 bad vouchers in random positions. 90 settle, 10 emit failure events. Transaction succeeds.

---

## 11. References

- `docs/mech_prepay_spec.md`, the minimum-viable baseline this builds on
- `docs/mpp_session_spec.md`, the alternative that uses a separate escrow contract
- `docs/x402_spec.md`, the per-request EIP-3009 alternative
- `docs/x402_vs_mpp.md`, decision guide between the two ecosystem-protocol options
- `wildcard/server/src/session/store.py`, the Postgres-backed channel store pattern this spec mirrors
- `wildcard/server/src/session/voucher.py`, the EIP-712 voucher verification reference
- `mech-client/mech_client/services/marketplace_service.py`, the existing HTTP off-chain integration that gets a voucher branch
- `mech/packages/valory/skills/task_execution/handlers.py`, the off-chain HTTP handler that gets the voucher routes
