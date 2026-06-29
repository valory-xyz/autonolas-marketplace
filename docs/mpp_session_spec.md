# Mech Marketplace, MPP Session Compatibility Specification

## 1. Overview

This document specifies how to add MPP (Machine Payments Protocol) session support to the Mech Marketplace as an additional payment family, parallel to the planned x402 USDC family in `docs/x402_spec.md`. The approach reuses the existing `deliverMarketplaceWithSignatures` function, adds a new `BalanceTrackerMppSession` contract that delegates settlement to a standalone `MppEscrow` contract, and lets the Mech run the MPP Facilitator role in-process. No changes are required to `MechMarketplace` or `OlasMech`, and all existing payment flows remain completely untouched.

### Roles in MPP

| MPP role | Maps to |
|-----------|---------|
| **Client** | The agent or application calling the mech HTTP endpoint. Opens a payment channel by depositing USDC into `MppEscrow`, then signs EIP-712 vouchers off-chain. |
| **Resource Server** | The Mech. Provides the AI tool service and handles the full 402 handshake with `WWW-Authenticate: Payment`. |
| **Facilitator** | Also the Mech. The mech verifies vouchers in-process (no external service), and submits on-chain settlement during its batch cycle. |
| **Channel Operator** | Mech Safe (or a hot key delegated by the Safe). Submits `MppEscrow.settle()` and `MppEscrow.close()` calls. |

> **Key design principle**
>
> Vouchers are verified off-chain on every request, identical to how the wildcard prediction server already runs MPP for pearl-mini. On-chain settlement happens only at batch time, routed through `deliverMarketplaceWithSignatures` so the marketplace keeps recording karma, fees, and subgraph events for every delivery.

### Existing MPP Infrastructure

Valory already runs MPP in production in the pearl-mini Chrome extension and the wildcard prediction server. We can reuse most of the off-chain pieces and the on-chain pattern, but with one important caveat about what is and is not standardized.

- **Client SDK**: `mppx@0.4.11` on npm (TypeScript). Already used by pearl-mini (`src/core/prediction/mpp-client.ts`). Provides EIP-712 voucher signing, channel state management, automatic 402 retry. **Important caveat:** `mppx` ships session machinery only via its `tempo()` method, which is hard-coded to Tempo chain (chainId 4217) and Tempo's `TempoStreamChannel` deployment. To target our `MppEscrow` on Gnosis / Base, we ship a Valory adapter (see Section 6.3). This is not a "configure tempo() differently" operation; it's a new method.
- **Server SDK**: `pympp` plus a custom `SessionIntent` in Python. Already used by the wildcard server (`server/src/session/`). Provides voucher verification (`voucher.py`), monotonic cumulative store (`store.py`), and channel lifecycle handling (`intent.py`). The constructor already accepts `escrow_address` and `chain_id` as configuration, so the server-side port is mostly a domain rename and the module being lifted into the mech behaviour.
- **Escrow contract reference**: Tempo's `TempoStreamChannel` (chainId 4217). Functionally identical in shape to what we deploy, but Tempo's deployment is theirs and our deployment is ours.

### What is and is not standardized

The MPP protocol's challenge / credential / receipt framework is on the IETF standards track ([draft-ryan-httpauth-payment](https://datatracker.ietf.org/doc/draft-ryan-httpauth-payment/)). The framework is stable.

Per [mpp.dev/payment-methods/evm/](https://mpp.dev/payment-methods/evm/), the MPP EVM payment method standardizes the **charge intent only**: EIP-3009-based per-request payment, essentially the same shape as x402. **There is no canonical MPP EVM session intent.** Session intent is standardized for Tempo and Stellar (SEP-41) only.

If we ship MPP session on Gnosis or Base, we are extending the protocol with a Valory-specific session intent. Consequences:

- The on-chain contracts and the off-chain code stay as designed in this spec. The on-chain piece is what we own anyway.
- We become spec authors for the session-intent-on-EVM details: voucher EIP-712 type, 402 challenge body schema, credential format, MppEscrow ABI as reference. Plan to publish this as a Valory extension document.
- Agents using generic MPP clients (e.g. `mppx` with EVM charge method or any future standardized EVM client) cannot pay our session-mode mech without our adapter installed per mech.

This is not a blocker. It is honest scope. The protocol authorship work is roughly one week on top of the contract and SDK work.

---

## 2. Issues This Addresses

The following gaps in the current architecture need to be closed to support MPP sessions.

### Issue 1, No pre-deposit in the standard MPP flow

In the standard off-chain mech flow, clients pre-deposit funds into a BalanceTracker via `MechMarketplace.request()` before a request is processed. The mech checks `mapRequesterBalances[client] >= delivery_rate` before executing.

In MPP, the client deposits into `MppEscrow.open()` instead, which holds funds against a specific `(payer, payee, token)` channel. The BalanceTracker has no native mechanism to read from the escrow, so without a new payment family the deposit cannot be applied against deliveries.

### Issue 2, Voucher format is not a request signature

The existing off-chain delivery path (`deliverMarketplaceWithSignatures`) requires the client to sign the `requestData` directly. This signature is stored in `DeliverWithSignature.signature` and verified on-chain via `ecrecover(hash(requestData), signature) == requester`.

An MPP client signs an EIP-712 voucher with the structure `{channelId, cumulativeAmount}`. This is structurally different and cannot be passed where the `requestData` signature is expected. The client must produce both signatures.

### Issue 3, Per-request settlement is expensive at volume

The planned x402 family settles per-request (one `deliverMarketplaceWithSignatures` call per HTTP request) because each EIP-3009 authorization is single-use. For clients that make many requests, this loses the gas amortization that the existing pre-deposit flow gives via batched delivery.

### Issue 4, Native token mechs cannot use EIP-712 USDC vouchers

The majority of deployed mechs accept payment in native tokens (xDAI on Gnosis). MPP session deposits flow through ERC-20 `transferFrom` into the escrow, so this family targets USDC (or any ERC-20). Native-token mechs continue on their existing payment path unchanged.

---

## 3. Proposed Solution

The solution introduces two new on-chain contracts (one shared escrow per chain, one BalanceTracker per family) plus the standard mech and factory contracts. The marketplace, OlasMech, karma, and fee contracts are unchanged.

### 3.1 MppEscrow, the channel custody contract

`MppEscrow` is a standalone contract, deployed once per chain, shared by all mechs that accept MPP session payments on that chain. It is functionally a port of `TempoStreamChannel` (the contract Tempo deploys for MPP on chainId 4217), adapted to live on the mech's home chain.

**Storage**:

```solidity
struct Channel {
    bool finalized;
    uint64 closeRequestedAt;
    address payer;            // client EOA
    address payee;            // BalanceTrackerMppSession address
    address token;            // USDC on this chain
    address authorizedSigner; // typically == payer
    uint128 deposit;          // total locked
    uint128 settled;          // cumulative already pulled out
}
mapping(bytes32 => Channel) public channels;
```

**Entry points**:

| Function | Caller | Effect |
|----------|--------|--------|
| `open(payee, token, deposit, salt, authorizedSigner)` | Client EOA | Pulls `deposit` via `token.transferFrom`, computes `channelId = keccak256(abi.encode(payer, payee, token, salt, authorizedSigner, address(this), chainId))`, stores `Channel`. |
| `settle(channelId, cumulativeAmount, voucherSig)` | Payee only (the BalanceTracker) | Verifies voucher EIP-712, requires `cumulativeAmount > settled`, transfers `(cumulativeAmount - settled)` to payee, updates `settled`. |
| `settleFrom(payer, paymentData)` | Payee only | Convenience wrapper. Decodes `paymentData = abi.encode(channelId, cumulative, sig)`, calls `settle`. Verifies the channel's `payer` matches the supplied `payer` argument. |
| `close(channelId, cumulativeAmount, voucherSig)` | Payee only | Settles, refunds `(deposit - cumulativeAmount)` to payer, marks `finalized = true`. |
| `requestClose(channelId)` | Payer | Sets `closeRequestedAt = block.timestamp`. After `CLOSE_TIMEOUT` (e.g. 24h), the payer can call `forceClose` if the payee never closed it. |
| `forceClose(channelId)` | Payer | Only callable after `closeRequestedAt + CLOSE_TIMEOUT`. Refunds the entire remaining deposit. Payee has had its window to claim. |
| `getChannel(channelId)` | Anyone (view) | Reads channel state. |

**EIP-712 domain**:

```
name              = "Olas MPP Channel"
version           = "1"
chainId           = block.chainid
verifyingContract = address(this) // MppEscrow
```

**Voucher type**:

```
Voucher(bytes32 channelId, uint128 cumulativeAmount)
```

This matches the structure used by `wildcard/server/src/session/voucher.py` so the off-chain code is directly portable.

### 3.2 BalanceTrackerMppSession, the override

`BalanceTrackerMppSession` extends `BalanceTrackerFixedPriceToken`. It overrides `_adjustInitialBalance` and exposes one additional external function (`closeChannel`). It is intentionally thin: it trusts `MppEscrow` to be authoritative about voucher correctness, and only checks that the expected delta arrived.

**Logic**:

```solidity
function _adjustInitialBalance(
    address requester,
    uint256 balance,
    uint256 deliveryRate,
    bytes memory paymentData
) internal override returns (uint256) {
    // Empty paymentData = pre-deposit flow (standard transferFrom path)
    if (paymentData.length == 0) {
        return super._adjustInitialBalance(requester, balance, deliveryRate, "");
    }

    uint256 before = IERC20(token).balanceOf(address(this));

    // Escrow does the full validation:
    //  - decodes paymentData
    //  - verifies voucher EIP-712 signature
    //  - requires cumulative > settled
    //  - transfers (cumulative - settled) USDC to this contract
    //  - reverts on any tampering or replay
    mppEscrow.settleFrom(requester, paymentData);

    uint256 received = IERC20(token).balanceOf(address(this)) - before;
    if (received < deliveryRate) {
        revert MppInsufficientSettlement(received, deliveryRate);
    }

    return balance + received - deliveryRate;
}
```

**Properties**:
- BalanceTrackerMppSession does NOT verify the voucher signature itself. The escrow already does, and re-checking would be redundant gas.
- If `paymentData` is malformed or tampered, `mppEscrow.settleFrom` reverts, the whole `deliverMarketplaceWithSignatures` call reverts, no delivery is recorded.
- `received >= deliveryRate` is the safety net: if the escrow somehow transferred less than expected, we abort. Belt-and-braces against future escrow upgrades.
- Existing payment families are unaffected because the override only runs when registered against `keccak256("MPP_SESSION_USDC")`.

**Surplus-settlement branch.** If the cumulative delta the escrow transfers is *greater* than the summed batch's `deliveryRate` (e.g. the mech under-batches by settling 8 voucher-accepted requests in a batch sized for 6), the override returns `balance + received - deliveryRate`, leaving the positive remainder in `mapRequesterBalances[requester]`. The escrow's `settled` cursor advances by the full delta, so the surplus is genuinely paid-for — it just lands as requester credit instead of being immediately debited. The next batch from the same requester nets it out (the override starts with `balance > 0` and the loop in `adjustMechRequesterBalances` debits from that balance first before pulling new funds). v1 has no requester withdrawal on `BalanceTrackerMppSession`, so a session that closes with surplus credit forfeits it; the `MppEscrow.close` refund path described in §5 is what protects the client end-to-end, and the credit-on-tracker case only matters when settlement runs ahead of batch settlement, which the mech operator controls. §10 test list adds a case for "settlement delta > summed batch rates" to lock the surplus behavior in.

**`closeChannel` entry point**:

The escrow's `close()` is callable only by the channel's `payee` (= this BalanceTracker). So the BalanceTracker must expose its own entry to forward the call. Suggested shape:

```solidity
function closeChannel(bytes32 channelId, uint128 cumulativeAmount, bytes calldata voucherSig)
    external
{
    // Access control: see open question below. v1 candidates:
    //   (a) onlyMech: msg.sender must be a registered mech (mapAgentMechFactories[msg.sender] != 0 via marketplace check)
    //   (b) onlyOperator-for-some-mech: msg.sender is a service multisig operating a mech for this paymentType
    //   (c) public: anyone can call, escrow validates the signature anyway
    mppEscrow.close(channelId, cumulativeAmount, voucherSig);
}
```

Without this entry, deposits would never refund and channels could only be unilaterally closed by the payer after `CLOSE_TIMEOUT` via `forceClose`. The simplest secure default is (c) public: the escrow's own EIP-712 sig check is the trust boundary, and anyone with the latest signed voucher can finalize. Pick the policy intentionally in v1.

### 3.3 Three-contract pattern matches existing families

The marketplace resolves the balance tracker via `mapPaymentTypeBalanceTrackers[mech.paymentType()]`. For MPP to route correctly, the same three-contract pattern used by `MechFixedPriceTokenUSDC` applies:

| Contract | Purpose |
|----------|---------|
| `MppEscrow` | Channel custody and voucher settlement. **One deployment per chain**, shared by all MPP mechs. |
| `BalanceTrackerMppSession` | Settlement adapter. Per chain, registered against `keccak256("MPP_SESSION_USDC")`. |
| `MechFixedPriceTokenMppSession` | Mech contract with `PAYMENT_TYPE = keccak256("MPP_SESSION_USDC")`, routes to the MPP balance tracker. |
| `MechFactoryFixedPriceTokenMppSession` | Factory creating `MechFixedPriceTokenMppSession` instances via CREATE2. |

### 3.4 Dual off-chain signatures

The client signs two messages in a single off-chain step. Both are free (no gas).

- **Signature 1, Voucher (EIP-712)**: client signs the `Voucher` typed data with domain pointing at `MppEscrow`. Provides `{channelId, cumulativeAmount}` and `(v, r, s)`. Encoded as `paymentData = abi.encode(channelId, cumulativeAmount, voucherSig)` for the on-chain settlement step.
- **Signature 2, Request (standard mech)**: client signs `hash(requestData)` using the same private key. Goes into `DeliverWithSignature.signature` for MechMarketplace's on-chain `ecrecover` verification.

The `mppx` client library handles voucher signing transparently. The mech request signature is a small extension on top, the same way the x402 family handles it.

### 3.5 Voucher Verification Strategy

The mech verifies vouchers **off-chain** on every request, identically to how `wildcard/server/src/session/voucher.py` does it today. This is what gives MPP its zero-gas-per-request property.

**Off-chain verification (in the mech behaviour, per request)**:

1. Decode `Payment-Credential` header.
2. Run `verify_voucher(escrow_address, chain_id, channel_id, cumulative_amount, signature, expected_signer)`. This calls `eth_account.recover_message` on the EIP-712 typed data and checks the recovered signer matches the channel's `authorizedSigner`.
3. Check the channel exists locally (cached from `MppEscrow.getChannel`) and is not finalized.
4. Check `cumulative_amount > highest_accepted_cumulative` for this channel. This is the monotonic invariant that `wildcard/server/src/session/store.py` enforces.
5. Check `cumulative_amount <= channel.deposit`.
6. If all pass, accept the voucher, run the tool, return 200.

**On-chain re-verification (at batch settlement)**:

The escrow re-runs voucher verification on-chain. This is non-redundant because the on-chain state is what controls the actual fund movement. If the off-chain layer had a bug or the mech operator tried to submit a bogus voucher, the escrow rejects it. Off-chain verification is for fast rejection of bad requests; on-chain verification is the authoritative settlement.

### 3.6 Dynamic Pricing

For the initial MPP implementation, pricing matches the x402 family and inherits the same policy decision.

**Fee model reminder**. `BalanceTrackerBase._processPayment` (lines 144-176) takes the fee out of `mapMechBalances[mech]` at payout time, not from the client at delivery. So:

```
mech_received ≈ quote * (10000 - fee_bps) / 10000   (ceil-rounded on the fee)
```

Two valid quote policies follow:

- **Policy A, client pays the listed rate**. `quote = maxDeliveryRate`. Mech absorbs fee, keeps `maxDeliveryRate * (1 - fee_bps/10000)`.
- **Policy B, client pays grossed-up**. `quote = ceil(maxDeliveryRate * 10000 / (10000 - fee_bps))`. Mech receives `maxDeliveryRate` net of fee.

**v1 ships Policy A** consistently with `docs/x402_spec.md` §3.3. Every worked example, schema sample, and batch math in this document uses Policy A at the live 15% marketplace fee (1500 bps, per governance proposal 01). Switching to Policy B would require re-running every example here and in the x402 spec — the two policies cannot be mixed inside a single spec because they produce different `pricing.perRequest` values for the same listed rate.

The mech queries `MechMarketplace.fee()` for fee bps and returns the quote in the HTTP 402 response body.

**NVM/dynamic-price mechs (future scope)**: on requests without payment credentials, run tool with `delivery_rate=0` to get cost estimate, then apply the same policy.

### 3.7 Batch settlement semantics

In `adjustMechRequesterBalances` (BalanceTrackerBase.sol), the batch loop sums `mechDeliveryRates[]` into `totalMechDeliveryRate`, then `_adjustInitialBalance` is called **once** with that total. This is exactly the shape MPP session settlement wants:

- The mech collects N vouchers off-chain across N requests from the same channel.
- Each voucher has a strictly increasing `cumulativeAmount`. The most recent voucher implicitly authorizes settlement of all prior amounts.
- At batch time, the mech submits `deliverMarketplaceWithSignatures` with N delivery entries and a **single** `paymentData` carrying the latest voucher.
- The escrow settles `(latestCumulative - prevSettled)` in one transfer, which equals `sum(deliveryRates)` if the off-chain accounting is consistent.

This is the property that breaks for x402 (each EIP-3009 sig is single-use). It works for MPP because a voucher represents cumulative state, not a single transfer.

**Critical, atomic batch revert**: as with x402, `deliverMarketplaceWithSignatures` reverts the entire transaction if any single delivery fails. The mech should pre-validate the latest voucher off-chain before submission to minimize on-chain reverts.

### 3.8 Mech as Facilitator

Rather than deploying a separate facilitator service, the mech itself exposes the facilitator endpoints. This keeps the architecture simple: the mech handles voucher verification, channel state lookup, and balance checks in-process before executing the tool. There is no external service dependency.

**Facilitator endpoints exposed by the mech**:

- `POST /verify`, validates a voucher against the local channel state. Returns `{ valid: true/false, reason }`. Optional, mainly for protocol conformance; in-process verification is the primary path.
- `GET /channel/lookup?payer=0x...`, returns the active channel for a given payer (with proof-of-ownership signature, same pattern as the wildcard server `lookupChannel`).
- `GET /health`, liveness check. Returns 503 after repeated settlement failures (same circuit-breaker pattern as x402).

On-chain settlement is **NOT** handled by these endpoints. It is handled by the mech's existing batch cycle via `deliverMarketplaceWithSignatures`.

### 3.9 Settlement Failure Handling

The client receives their result at HTTP 200, but on-chain settlement happens later in the mech's batch cycle. Failure modes differ from x402.

**Failure mode 1, Channel underfunded at settlement time**: cannot happen by construction. The escrow holds the full `deposit` from `open()`, and the off-chain layer rejects vouchers where `cumulative > deposit`. The settlement delta `(cumulative - settled) <= deposit` is always backed by funds.

**Failure mode 2, Client requests early close mid-batch**: the client could call `MppEscrow.requestClose()` after their last voucher but before settlement. The escrow keeps the channel open during `CLOSE_TIMEOUT` (recommended 24h) so the mech has time to submit `settle` or `close` first. After that window, the client can `forceClose` and recover any remaining deposit.

**Failure mode 3, Channel is on the wrong chain**: prevented by the EIP-712 domain. The voucher signature is bound to `(chainId, verifyingContract)`. A voucher signed for one chain's `MppEscrow` cannot be replayed against another chain's.

**Failure mode 4, Mech operator key compromise**: the mech Safe (or its delegated hot key) is the only address that can call `settle` / `close`. Compromise means an attacker can submit valid vouchers to drain accumulated cumulative amounts to the mech's payee. The payee is fixed to `BalanceTrackerMppSession`, not an attacker-controlled address, so funds end up in the marketplace anyway. The mech operator's earnings are at risk via the existing `processPaymentByMultisig` flow, not via the escrow itself.

**Mitigation, Circuit breaker**: following the wildcard pattern (`server/src/session/intent.py:84`), the mech tracks RPC failures and settlement timeouts. After 3 consecutive settlement failures, `/health` returns 503 and the orchestrator pauses MPP traffic.

### 3.10 Channel Lifecycle and State Persistence

The off-chain channel state must survive agent restarts and ensemble re-elections. The wildcard server uses postgres (`server/src/session/store.py`). The mech equivalent is `synchronized_data`, the ensemble-shared state already used by Valory autonomous services.

**Per-channel state stored**:

```
{
  channelId: bytes32,
  payer: address,
  authorizedSigner: address,
  deposit: uint128,
  highestAcceptedCumulative: uint128,
  lastSettledOnChain: uint128,
  pendingVoucherSig: bytes,  // latest sig from highestAccepted
  finalized: bool
}
```

**Invariants**:
- `highestAcceptedCumulative` is monotonic non-decreasing.
- `highestAcceptedCumulative <= deposit`.
- `lastSettledOnChain <= highestAcceptedCumulative` (settlement may lag acceptance).

**Recovery hint in 402**: when a client without local state retries `POST /predict`, the mech's 402 response includes `methodDetails: {channelId, currentCumulative}` if it has an active channel for the requester's EOA. The `mppx` library uses this hint to resume vouchers from the right offset. Same pattern as `wildcard/server/src/routes/predict.py`.

---

## 4. End-to-End Flow

All HTTP steps are new. The on-chain batch cycle reuses the existing `deliverMarketplaceWithSignatures` path. The only new on-chain behavior is inside the overridden `_adjustInitialBalance` (which calls `MppEscrow.settleFrom`).

| Step | Layer | Description |
|------|-------|-------------|
| **1** | HTTP, off-chain | Client sends `POST /predict {tool, prompt}` to Mech. No `Payment-Credential` header. |
| **2** | Mech, off-chain | Mech generates a cost estimate. For fixed-price mechs under Policy A: `quote = maxDeliveryRate` (mech absorbs the marketplace fee). The mech still queries `MechMarketplace.fee()` so the `processPaymentByMultisig` carve-out at settlement is recorded against the live bps. |
| **3** | HTTP, off-chain | Mech returns HTTP 402 with `WWW-Authenticate: Payment` header. Body includes `method = "session"`, `escrow = 0xMppEscrow`, `chainId`, `payee = 0xBalanceTrackerMppSession`, `token = USDC address`, `maxDeposit`, plus `methodDetails: {channelId, currentCumulative}` if an active channel exists. |
| **4** | Client, off-chain | If no active channel: client calls `MppEscrow.open(payee, token, deposit, salt, authorizedSigner)`. **This is one on-chain transaction**. Pulls `deposit` USDC from client into escrow. |
| **5** | Client, off-chain | Client signs voucher `{channelId, cumulative = prev + quote}` via EIP-712. Also signs `hash(requestData)` for the mech delivery signature. |
| **6** | HTTP, off-chain | Client re-sends `POST /predict {tool, prompt, requestSignature}` with `Payment-Credential: <base64 voucher>`. |
| **7** | Mech (`/verify`), off-chain | Mech runs `verify_voucher()`, checks monotonic cumulative against synchronized_data, checks `cumulative <= deposit`. If all pass, accept voucher, persist new `highestAcceptedCumulative`. |
| **8** | Mech, off-chain | Mech executes tool, gets result. |
| **9** | HTTP, off-chain | Mech returns HTTP 200. Body: `{ result }`. `Payment-Receipt` header: receipt of accepted voucher. Client has their result. |
| **10** | On-chain, batch | Mech Safe calls `OlasMech.deliverMarketplaceWithSignatures(requester=client, deliverWithSignatures=[N entries], deliveryRates=[N rates], paymentData=abi.encode(channelId, latestCumulative, latestVoucherSig))`. |
| **11** | On-chain, batch | MechMarketplace records N deliveries: emits `Deliver` events, increments karma, updates per-requester and per-mech counters. Then calls `BalanceTrackerMppSession.adjustMechRequesterBalances`. |
| **12** | On-chain, batch | `BalanceTrackerMppSession._adjustInitialBalance` calls `MppEscrow.settleFrom(client, paymentData)`. Escrow verifies voucher, checks monotonic, transfers `(latestCumulative - prevSettled)` USDC from escrow to BalanceTracker. |
| **13** | On-chain, batch (later) | Mech calls `processPaymentByMultisig` to carve out marketplace fee and transfer remainder to Mech Safe. **No changes to this function.** |
| **14** | On-chain, close | When channel is exhausted or client done, mech submits `MppEscrow.close(channelId, finalCumulative, sig)`. Remaining deposit refunds to client. One on-chain tx. |

### What subgraphs see

- `MarketplaceDeliveryWithSignatures` event: `deliveryMech=0xMech`, `requester=0xActualClient`. Correct per-client attribution. Same event type as existing off-chain deliveries.
- No indexer changes required.
- `processPaymentByMultisig` fee logic: completely unchanged.
- New events from `MppEscrow` (`ChannelOpened`, `ChannelSettled`, `ChannelClosed`) are optional to index, useful for dashboards but not required for marketplace accounting.

### Flow Routing

All payment paths coexist in the mech with no breaking changes to existing flows:

| Condition | Flow |
|-----------|------|
| `Payment-Credential` header with MPP voucher | MPP session, verify in-process, execute, HTTP 200 |
| `X-Payment` header (x402) | x402 flow (per `docs/x402_spec.md`) |
| No payment header, no `delivery_rate` | Return HTTP 402 with MPP and/or x402 challenge |
| `delivery_rate` in body | Existing off-chain flow (unchanged) |
| On-chain event | Existing on-chain flow (unchanged) |

---

## 5. Worked Example

A run of 10 requests from the same client with the following setup:

> **Listed rate (maxDeliveryRate)**: 0.01 USDC per request
> **Marketplace fee**: 15% (1500 bps, per governance proposal 01)
> **Quote per request (Policy A)**: 0.01 USDC = 10000 atomic units
> **Client**: `0xClient`
> **Mech**: `0xMech` (paymentType = MPP_SESSION_USDC)
> **BalanceTrackerMppSession**: `0xBalMpp`
> **MppEscrow**: `0xMppEscrow`
> **Initial deposit**: 0.50 USDC = 500_000 atomic units

### HTTP Phase (request 1)

Client sends `POST /predict`. Mech returns HTTP 402 with body:

```json
{
  "x402Version": null,
  "mppVersion": 1,
  "methods": [
    {
      "method": "session",
      "escrow": "0xMppEscrow",
      "chainId": 100,
      "payee": "0xBalMpp",
      "token": "0x...usdc",
      "maxDeposit": "500000",
      "pricing": { "perRequest": "10000" }
    }
  ],
  "error": "Payment required"
}
```

### On-Chain Channel Open

Client signs and submits:

```
USDC.approve(MppEscrow, 500000)
MppEscrow.open(
  payee  = 0xBalMpp,
  token  = USDC,
  deposit = 500000,
  salt   = random32,
  authorizedSigner = 0xClient
)
```

Escrow stores channel, pulls 500_000 USDC from client. **One on-chain tx.**

### HTTP Phase (requests 1 through 10)

For each request `i = 1..10`, client signs voucher `{channelId, cumulative = i * 10000}` and `hash(requestData_i)`. Posts both. Mech verifies voucher off-chain, checks `cumulative > prev`, accepts, runs tool, returns HTTP 200.

After 10 requests:
- `highestAcceptedCumulative = 100000`
- Off-chain on-chain settled count: 0
- Tool executions: 10
- On-chain transactions during this phase: 0

### On-Chain Batch Settlement

Mech Safe submits:

```
deliverMarketplaceWithSignatures(
  requester = 0xClient,
  deliverWithSignatures = [10 entries, each with requestData_i + sig_i + deliveryData_i],
  deliveryRates = [10000, 10000, ..., 10000],
  paymentData = abi.encode(channelId, 100000, voucherSig_10)
)
```

Inside the call:
- MechMarketplace verifies 10 request signatures, records 10 deliveries, increments karma by 10, updates counters.
- BalanceTrackerMppSession.adjustMechRequesterBalances:
  - sum of rates = 100000
  - balanceBefore = X
  - calls MppEscrow.settleFrom(0xClient, paymentData)
  - escrow verifies voucherSig_10 against channel's authorizedSigner
  - escrow requires 100000 > 0 (prev settled)
  - escrow transfers 100000 USDC from itself to 0xBalMpp
  - balanceAfter - balanceBefore = 100000
  - received >= 100000 check passes
- requesterBalance and mechBalance updated as usual.

**One on-chain tx for 10 deliveries.**

### Fee Carve-Out

After 10 accumulated requests at `mapMechBalances[0xMech] = 100000`:

```
fee = ceil(100000 * 1500 / 10000) = 15000 -> marketplace treasury
mech payment = 100000 - 15000 = 85000   -> Mech Safe
```

**Unchanged from existing flow.**

### Channel Close

When the client is done, or when the remaining deposit is below the next request cost:

```
MppEscrow.close(channelId, 100000, voucherSig_10)
```

Escrow refunds `500000 - 100000 = 400000` to the client. Marks channel finalized. **One on-chain tx.**

### Total Cost Summary

| Event | On-chain txs |
|-------|--------------|
| Channel open | 1 |
| 10 deliveries (batched) | 1 |
| Channel close | 1 |
| **Total for 10 requests** | **3** |

Compared to x402 (PR #148) which would be 10 on-chain transactions for the same 10 requests.

---

## 6. What We Need to Build

### 6.1 Smart Contracts

**MppEscrow** (`contracts/mechs/token/mpp/MppEscrow.sol`)
- Standalone contract, ~200 lines.
- Stores `Channel` struct per `channelId`.
- Implements `open`, `settle`, `settleFrom`, `close`, `requestClose`, `forceClose`, `getChannel`.
- EIP-712 domain `("Olas MPP Channel", "1", chainId, address(this))`.
- Voucher type `Voucher(bytes32 channelId, uint128 cumulativeAmount)`.
- Constructor: `(initialCloseTimeoutSeconds)`.
- One deployment per chain. Shared by all MPP mechs.

**BalanceTrackerMppSession** (`contracts/mechs/token/mpp/BalanceTrackerMppSession.sol`)
- Extends `BalanceTrackerFixedPriceToken`, ~30 lines.
- Overrides `_adjustInitialBalance` to call `mppEscrow.settleFrom`.
- Constructor: `(mechMarketplace, drainer, usdcTokenAddress, mppEscrowAddress)`.

**MechFixedPriceTokenMppSession** (`contracts/mechs/token/mpp/MechFixedPriceTokenMppSession.sol`)
- Extends `MechFixedPriceBase`, ~30 lines.
- Defines `PAYMENT_TYPE = keccak256("MPP_SESSION_USDC")`.

**MechFactoryFixedPriceTokenMppSession** (`contracts/mechs/token/mpp/MechFactoryFixedPriceTokenMppSession.sol`)
- Extends `MechFactoryBase`, ~30 lines.
- Creates `MechFixedPriceTokenMppSession` instances via CREATE2.

**Error definitions** (in a new `IErrorsMpp.sol` or appended to `IErrorsMarketplace.sol`):
- `MppInsufficientSettlement(uint256 received, uint256 required)`
- `MppChannelNotFound(bytes32 channelId)`
- `MppChannelFinalized(bytes32 channelId)`
- `MppNonMonotonicCumulative(uint128 provided, uint128 settled)`
- `MppOverflowsDeposit(uint128 cumulative, uint128 deposit)`
- `MppInvalidVoucher()`
- `MppInvalidPayer(address provided, address expected)`
- `MppInvalidPayee(address provided, address expected)`
- `MppCloseNotRequested()`
- `MppCloseTimeoutNotReached(uint64 requestedAt, uint64 now)`

**Registration (by MechMarketplace owner)**:

```solidity
mechMarketplace.setPaymentTypeBalanceTrackers(
    [keccak256("MPP_SESSION_USDC")],
    [BalanceTrackerMppSession_address]
);
mechMarketplace.setMechFactoryStatuses(
    [MechFactoryFixedPriceTokenMppSession_address],
    [true]
);
```

### 6.2 Mech Side (Resource Server + Facilitator)

**HTTP layer**:
- Return HTTP 402 with `WWW-Authenticate: Payment` header and MPP method body when no `Payment-Credential` is present.
- Parse `Payment-Credential` header (base64-encoded voucher JSON).
- Return `Payment-Receipt` header on 200 responses.
- Optional `/verify`, `/channel/lookup`, `/health` endpoints (see Section 3.8).

**Voucher verification**:
- Port `wildcard/server/src/session/voucher.py:verify_voucher` into the mech behaviour.
- Run on every request before tool execution.
- Use `eth_account.recover_message` with EIP-712 typed data.

**Channel state store**:
- Port `wildcard/server/src/session/store.py:accept_voucher` invariants:
  - require `cumulative > highestAcceptedCumulative`
  - require `cumulative <= deposit`
  - require `cumulative >= settledOnChain`
- Persist `{channelId, deposit, highestAccepted, settledOnChain, ...}` to `synchronized_data` so it survives agent restart and is consistent across the ensemble.

**On-chain channel verification at open time**:
- Port `wildcard/server/src/session/intent.py:_handle_open`.
- When the client signals a newly opened channel (via ChallengeEcho or a recovery hint), read `MppEscrow.getChannel(channelId)` via eth_call before accepting any vouchers.
- Confirm `payer`, `payee`, `token`, `deposit`, `authorizedSigner` match the 402 challenge values.

**Batch settlement trigger**:
- Periodic behaviour: every N accepted vouchers OR every T minutes OR when `(highestAccepted - settledOnChain) >= threshold`, build a `deliverMarketplaceWithSignatures` call:
  - Collect the N delivery entries since last settlement.
  - `deliveryRates = [each request's quote]`
  - `paymentData = abi.encode(channelId, highestAcceptedCumulative, latestVoucherSig)`
- Submit via the existing mech Safe transaction path.

**Close handler**:
- When `channel.deposit - highestAcceptedCumulative < nextRequestCost`, OR the client signals close, OR an idle timeout elapses, the mech Safe submits `MppEscrow.close(channelId, latestCumulative, sig)`.
- Clears the channel from `synchronized_data` only after on-chain confirmation.

**Circuit breaker**:
- Track `MppEscrow.settle` / `close` failures and RPC errors.
- After 3 consecutive failures, `/health` returns 503.
- See `wildcard/server/src/session/intent.py:84` for the reference pattern.

### 6.3 Client Side

**Client SDK requires a small adaptation**, not a from-scratch build. The `mppx` library used by pearl-mini is the right starting point, but its only built-in payment method (`tempo()`) is hard-coded to Tempo's `TempoStreamChannel` on chainId 4217. To target our `MppEscrow` on Gnosis/Base/etc., one of the following is needed:

- **Fork mppx** and add an `olas()` method (or rename / generalize `tempo()` to take chain + escrow as config). Lowest-risk for v1.
- **Upstream PR to mppx** parameterizing `tempo()` so it can point at any chain + escrow that implements the same interface. Cleanest long-term, but depends on upstream review.
- **Bypass mppx** and ship a thin Valory client that does voucher signing + 402 retry. Roughly mirrors what `mppx/client/Mppx.create` does internally. Smallest dependency footprint.

Whichever path is chosen, the wire format and EIP-712 typed data are unchanged from the pearl-mini ↔ wildcard server setup, so the off-chain protocol is interoperable.

Once the SDK is configured:

- `Mppx.create({ methods: [olasMethod({ account, escrow, chainId, ... })] })` exposes a fetch-compatible client.
- The client makes a normal `mppx.fetch(url, init)` call. On 402, mppx auto-signs the voucher and retries.
- Channel state is managed by the client SDK; persistence is the client's responsibility (e.g. `chrome.storage.local` for browser, file or DB for backend agents).

**The only extension needed**: the mech request signature (Signature 2) must accompany each request. Options:
- Pass as a body parameter alongside the prediction inputs.
- Pass as a custom header (e.g. `X-Mech-Request-Sig`).
- Pass via `mppx` context object as a custom field.

Decision needed before implementation (open item, see Section 8).

**Auto-funding** (optional): clients can auto-top-up the channel by closing and reopening when the deposit is exhausted, following the pearl-mini "cycle gate" pattern (`src/messaging/handlers/prediction.ts:666-722`).

---

## 7. Contract Change Summary

| Component | Change required | Notes |
|-----------|-----------------|-------|
| `MppEscrow` | New deployment | One per chain. Shared by all MPP mechs on that chain. |
| `BalanceTrackerMppSession` | New deployment | Per chain. Extends `BalanceTrackerFixedPriceToken`. Overrides `_adjustInitialBalance` to call `MppEscrow.settleFrom`. |
| `MechFixedPriceTokenMppSession` | New deployment | Defines `PAYMENT_TYPE = keccak256("MPP_SESSION_USDC")`. |
| `MechFactoryFixedPriceTokenMppSession` | New deployment | Factory for the above. Registered via `setMechFactoryStatuses`. |
| `MechMarketplace` | None | `paymentData` flows through unchanged. Owner registration call only. |
| `OlasMech` | None | `paymentData` passed through unchanged. |
| `BalanceTrackerBase` | None | Hooks are already in place. |
| `BalanceTrackerFixedPriceNative` | None | Untouched. |
| `BalanceTrackerFixedPriceToken` | None | Parent class for the new tracker, untouched. |
| `BalanceTrackerNvmSubscription*` | None | Untouched. |
| `BalanceTrackerX402` (PR #148) | None | Coexists in parallel. |
| Karma contract | None | Receives updates from existing marketplace calls. |
| Fee logic (`processPaymentByMultisig`) | None | Runs unchanged on `mapMechBalances`. |

---

## 8. Known Constraints

- **Channel deposit required upfront**. The client must lock `deposit` USDC at channel open. This is the cost of session-mode amortization. For single-request clients, x402 is cheaper because there is no deposit.
- **Client EOA needs native gas to open and force-close**. `MppEscrow.open()` and `MppEscrow.forceClose()` are submitted by the client EOA, so the client needs xDAI / ETH on the target chain for gas. Pearl-mini avoids this on Tempo by using Tempo's pay-gas-in-USDC.e tx type; on Gnosis or Base no equivalent exists by default. Options for v1: require clients to bring native gas (worst UX, blocks pure-USDC agents), or sponsor `open()` via ERC-4337 + a paymaster (significant additional scope, not in v1).
- **Single token per channel**. A channel binds one ERC-20 token. Switching tokens means closing and reopening. For USDC this is not a constraint.
- **Channel identity (channel-per-mech convention)**. The channel's `payee` is the shared `BalanceTrackerMppSession` address, not the mech itself. The `channelId` does NOT include the mech address. To avoid cumulative-amount coordination headaches when a client talks to multiple MPP mechs, the client SDK should use `salt = keccak256(abi.encode(mechAddress))` so each `(client, mech)` pair yields a distinct `channelId`. Security across mechs is enforced separately by the request signature (`getRequestId` includes `mech = msg.sender`) so the salt convention is purely an operational hygiene rule.
- **Native token mechs not supported**. xDAI/wxDAI on Gnosis. The escrow uses `transferFrom`. wxDAI is WETH9-style and lacks the integration we want (also the same constraint that excluded native from x402). These mechs continue on their existing payment path unaffected.
- **Authorized signer key management**. By default `authorizedSigner = payer` (the client EOA). Advanced setups can delegate signing to a separate key (useful for hot/cold wallet separation), but this adds complexity. v1 keeps `authorizedSigner = payer`.
- **No separate hot key for the mech side**. Settlement flows through the existing mech Safe via `OlasMech.deliverMarketplaceWithSignatures` → `MechMarketplace.deliverMarketplaceWithSignatures` → `BalanceTrackerMppSession._adjustInitialBalance` → `MppEscrow.settleFrom`. The escrow's `payee`-only access on `settle()` is satisfied because the BalanceTracker is the direct caller. The mech Safe is the only signing authority required.
- **Close timeout for unilateral close**. The escrow includes a `CLOSE_TIMEOUT` (recommended 24h) before a client can `forceClose`. This protects the mech from losing accumulated cumulative if the client tries to race-close.
- **EIP-712 domain bound to chain and escrow**. A voucher signed for one chain's `MppEscrow` cannot be replayed on another chain (chainId in domain) or on a redeployed escrow (verifyingContract in domain).
- **`closeChannel` access control on BalanceTrackerMppSession undecided**. See Section 3.2. Public, onlyMech, or onlyOperator are all defensible. Pin one in v1.
- **Mech request signature (Signature 2) transport mechanism undecided**. Body parameter, custom header, or mppx context field. Same open item as the x402 spec Issue C.

---

## 9. Multi-Chain Support

`MppEscrow` is chain-agnostic and can be deployed on any EVM chain where USDC (or any other ERC-20) is available.

| Network | Chain ID | USDC address |
|---------|----------|--------------|
| Gnosis | 100 | `0x2a22f9c3b484c3629090FeED35F17Ff8F88f76F0` (bridged, EIP-3009 unverified, irrelevant for MPP) |
| Base | 8453 | `0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913` (native Circle USDC) |
| Optimism | 10 | `0x0b2C639c533813f4Aa9D7837CAf62653d097Ff85` (native Circle USDC) |
| Polygon | 137 | `0x2791Bca1f2de4661ED88A30C99A7a9449Aa84174` |
| Avalanche | 43114 | `0xB97EF9Ef8734C71904D8002F8b6Bc66Dd9c48a6E` |

**MPP session does NOT depend on EIP-3009**. Unlike x402, it only needs vanilla `transferFrom` for the deposit. Gnosis bridged USDC works fine for MPP sessions even if it lacks `transferWithAuthorization`. This makes MPP a strictly broader chain target set than x402.

Each chain requires:
- One `MppEscrow` deployment.
- One `BalanceTrackerMppSession` deployment per token (USDC).
- Registration on `MechMarketplace` on that chain.

The mech's `GET /supported` endpoint returns the list of `{mpp_version, scheme, network, escrow}` entries for all chains where the mech has a registered BalanceTrackerMppSession.

---

## 10. Testing Strategy

### 10.1 Contract-Level Tests

Unit tests covering:

1. **Happy path**: client opens channel, signs N vouchers, mech batches `deliverMarketplaceWithSignatures`, escrow settles correct delta, balances update correctly.
2. **Pre-deposit fallback**: empty `paymentData` falls back to `super._adjustInitialBalance` (standard `transferFrom` flow). All existing payment families unaffected.
3. **Voucher validation failures**:
   - Wrong `from` (payer mismatch)
   - Wrong `payee`
   - `cumulativeAmount <= prevSettled` (non-monotonic)
   - `cumulativeAmount > deposit` (overflow)
   - Forged signature (not signed by authorizedSigner)
   - Voucher for a finalized channel
   - Voucher for nonexistent channel
4. **Channel lifecycle**:
   - `open` pulls correct deposit, computes correct `channelId`
   - `settle` transfers correct delta, updates `settled`
   - `close` settles + refunds remainder
   - `requestClose` + `forceClose` after timeout
   - `forceClose` before timeout reverts
5. **Batch settlement**: multiple deliveries from same channel in one `deliverMarketplaceWithSignatures` call, single `paymentData` carrying latest voucher.
6. **Fee accounting**: `processPaymentByMultisig` fee calculation unchanged on accumulated `mapMechBalances`.
7. **Reentrancy**: malicious token attempting reentrancy through `transferFrom` / `transfer` (reuse `MechReentrancyAttacker` pattern).
8. **Chain isolation**: a voucher signed against one chain's escrow domain cannot be used on another chain (test by changing chainId in the EIP-712 domain).
9. **Authorized signer != payer** (if supporting this in v1): voucher signed by `authorizedSigner` accepted; voucher signed by `payer` (when delegated to other signer) rejected.

Tests need a mock USDC supporting `transferFrom` (no special EIP-3009 support needed, unlike x402). A standard ERC-20 mock from OpenZeppelin works.

### 10.2 End-to-End Integration Test

An integration test proving the `mppx` client can complete the full flow against a local hardhat node:

1. Spin up local hardhat fork with USDC deployed (or mock USDC).
2. Deploy `MppEscrow`, `BalanceTrackerMppSession`, mech and factory. Register on `MechMarketplace`.
3. Use `mppx` configured with our escrow address and chain ID to send a request to a test mech HTTP server.
4. Verify HTTP 402 with correct `WWW-Authenticate: Payment` and method body.
5. mppx auto-opens the channel via `MppEscrow.open`, retries the request with `Payment-Credential` voucher header.
6. Verify HTTP 200 with `Payment-Receipt`. Tool executed.
7. Send 9 more requests, each with an incrementing cumulative voucher. All accepted off-chain.
8. Trigger batch settlement: `OlasMech.deliverMarketplaceWithSignatures` with all 10 deliveries and a single `paymentData`.
9. Verify on-chain: USDC moved from escrow to BalanceTracker, `mapMechBalances` updated, `MarketplaceDeliveryWithSignatures` event emitted with 10 request IDs.
10. Trigger fee carve-out via `processPaymentByMultisig`, verify treasury and mech Safe balances.
11. Close the channel, verify residual deposit refunded to client.

This validates the full session-mode flow with the actual `mppx` client, mirroring the production setup at pearl-mini ↔ wildcard server.

### 10.3 Cross-Family Coexistence Tests

For each combination of {pre-deposit, x402, MPP session}, verify:
- Two mechs with different payment types can deliver concurrently without interfering.
- A client with funds in `BalanceTrackerFixedPriceToken` (pre-deposit) and a channel in `MppEscrow` can use either path.
- `processPaymentByMultisig` correctly drains all three BalanceTrackers' `collectedFees` without overlap.

---

## 11. Comparison vs x402

| Aspect | x402 (PR #148) | MPP Session (this spec) |
|--------|-----------------|--------------------------|
| Per-request on-chain cost | 1 `transferWithAuthorization` per request (settled in batched tx, but each auth is its own settle call) | 0 (off-chain voucher only between open and settle) |
| Batch settlement | Possible by array-encoding multiple EIP-3009 auths in `paymentData`; the marketplace overhead amortizes but each auth still pays its own settle gas. See x402 spec Section 3.3 "Batch semantics". | Native: a single voucher carries the cumulative state for all prior requests, settles in one transfer regardless of N. |
| Token requirements | EIP-3009 USDC only | Any ERC-20 with `transferFrom` |
| Gnosis bridged USDC | Untested, likely unsupported | Works (no EIP-3009 needed) |
| First-call UX | Sign, retry, done | Open channel (1 tx), then sign + retry |
| Steady-state UX | Sign every request | Sign voucher locally, no on-chain |
| Funds locked | None (per-request transfer) | Channel deposit until close |
| Ecosystem | x402scan ~14k services, Bazaar, Coinbase | MPPscan ~419 servers (multi-chain via OpenAPI self-registration; same operator as x402scan) |
| Client SDK | `valory-xyz/genai`, Coinbase x402 SDK | `mppx` (same as pearl-mini) |
| Standardization | Informal Coinbase spec | IETF-track framework; session intent standardized only for Tempo and Stellar, our EVM session intent is a Valory extension |
| New contracts on mech chain | 3 (BalanceTrackerX402, mech, factory) | 4 (MppEscrow, BalanceTrackerMppSession, mech, factory) |
| Marketplace changes | None | None |

Both families can coexist behind separate payment types. Clients pick whichever fits their access pattern: x402 for casual one-off calls, MPP session for high-frequency repeat callers.
