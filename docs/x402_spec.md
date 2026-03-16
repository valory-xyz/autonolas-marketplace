# Mech Marketplace — x402 Compatibility Specification

## 1. Overview

This document specifies how to make the Mech Marketplace x402-compatible. The approach extends the existing `deliverMarketplaceWithSignatures` function with a new `BalanceTrackerX402` contract, and designates the Mech itself as the x402 Facilitator. No changes are required to `MechMarketplace` or `OlasMech`, and all existing payment flows remain completely untouched.

### Roles in x402

| x402 Role | Maps To |
|-----------|---------|
| **Client** | The agent or application calling the mech HTTP endpoint. Signs EIP-3009 and request authorizations off-chain. |
| **Resource Server** | The Mech — provides the AI tool service and handles the full 402 handshake. |
| **Facilitator** | Also the Mech. The mech runs its own `/verify` and `/health` endpoints internally, eliminating the need for a separate facilitator service. Signature verification and pre-checks happen in-process before tool execution. |

> **Key design principle**
> The x402 protocol is not modified — we plug into it using its built-in extension points.
> Mechs stay as Resource Servers. By also acting as Facilitator, the mech handles verification in-process,
> keeping the architecture simple and removing the dependency on an external facilitator service.

### Existing x402 Infrastructure

Valory already has a production x402 client SDK in `valory-xyz/genai` (`packages/valory/connections/x402/`), adapted from the [Coinbase x402 Python SDK](https://github.com/coinbase/x402). This includes:

- **`exact.py`** — EIP-3009 `TransferWithAuthorization` signing via EIP-712 typed data
- **`clients/httpx.py`** and **`clients/requests.py`** — automatic 402 retry transports
- **`types.py`** — `PaymentRequirements`, `EIP3009Authorization`, `PaymentPayload`, `x402PaymentRequiredResponse` models
- **`chains.py`** — USDC addresses per chain (Base, Optimism, Gnosis, Polygon, Avalanche)

A facilitator PoC exists in `valory-xyz/x402-poc` using the Coinbase TypeScript SDK (`x402/facilitator`). Optimus (`valory-xyz/optimus`) already uses the x402 client for CoinGecko API payments with auto-funding logic.

This spec reuses the existing x402 client library and header conventions. **No new client SDK is needed.**

---

## 2. Issues

The following issues in the current architecture need to be addressed to support x402 payments.

### Issue 1 — No Pre-deposit in x402

In the standard off-chain mech flow, clients pre-deposit funds into the BalanceTracker via `MechMarketplace.request()` before a request is processed. The mech checks `mapRequesterBalances[client] >= delivery_rate` before executing.

In the x402 flow there is no pre-deposit. The client holds funds in their wallet and signs an EIP-3009 `transferWithAuthorization`. The BalanceTracker has no mechanism to accept these signed authorizations and update its internal accounting. If a raw ERC20 transfer is directed to the BalanceTracker address, the tokens arrive but `mapRequesterBalances` is not updated — the tokens are effectively stuck with no accounting.

### Issue 2 — Client Signature Format Mismatch

The existing off-chain delivery path (`deliverMarketplaceWithSignatures`) requires the client to sign the `requestData` directly. This signature is stored in `DeliverWithSignature.signature` and verified on-chain via `ecrecover(hash(requestData), signature) == requester`.

An x402 client signs a `transferWithAuthorization` (EIP-3009) — a structurally different message. Passing this signature where the `requestData` signature is expected would fail the on-chain `ecrecover` check.

### Issue 3 — Dynamic Pricing Not Universally Supported

x402 requires the mech to return a cost estimate per request before the client signs a payment. Currently:
- NVM subscription mechs support variable delivery rates (below `max_delivery_rate`) and can generate per-request estimates.
- Fixed-price mechs (NATIVE, OLAS_TOKEN, USDC_TOKEN) have a single `max_delivery_rate` — every request costs the same and there is no cost estimation path.

### Issue 4 — Native Token Mechs Cannot Use EIP-3009

The majority of deployed mechs accept payment in native tokens (xDAI on Gnosis). The x402 standard flow requires EIP-3009 `transferWithAuthorization`, which is an ERC20 extension. wxDAI (the wrapped native token on Gnosis) is a WETH9-style contract and does not support EIP-3009. This means the standard x402 payment scheme cannot be used for native-payment mechs on Gnosis without a separate workaround.

---

## 3. Proposed Solution

The solution builds on `deliverMarketplaceWithSignatures` — a function that already provides two properties critical for x402 compatibility: it takes `requester` as an explicit parameter (preserving correct subgraph attribution), and it registers and delivers a request atomically in a single on-chain call (eliminating the need for a separate `request()` step).

Two targeted changes address the remaining issues: a new `BalanceTrackerX402` contract handles EIP-3009 payment settlement, and the client signs both a payment authorization and a request signature in a single off-chain step.

### 3.1 BalanceTrackerX402 — Addressing Issue 1

The `paymentData` field already flows through the entire call chain (`MechMarketplace` → `OlasMech` → `BalanceTracker`) and is currently empty for all existing flows. The solution is to deploy a new `BalanceTrackerX402` contract that interprets non-empty `paymentData` as an EIP-3009 `transferWithAuthorization`.

**Delivery call chain:**

```
OlasMech.deliverMarketplaceWithSignatures()
  -> MechMarketplace.deliverMarketplaceWithSignatures()
       -> IBalanceTracker.adjustMechRequesterBalances()
            -> _adjustInitialBalance()  <-- override point
```

> **Note:** `checkAndRecordDeliveryRates` is only called during the **request phase** (`MechMarketplace.request`/`requestBatch`), which does NOT exist in the x402 flow — the whole point is atomic request+delivery. The override target is `_adjustInitialBalance` because it: is called by both `checkAndRecordDeliveryRates` and `adjustMechRequesterBalances`; already accepts `paymentData` as `bytes memory` (unnamed/ignored in the base); and controls the fund acquisition path (calling `_getRequiredFunds` → `transferFrom` when balance is insufficient).

**When `_adjustInitialBalance` receives non-empty `paymentData`**, the `BalanceTrackerX402` override fully reimplements the balance logic (does NOT call `super`, bypassing `_getRequiredFunds` / `transferFrom` entirely):

1. Decode `paymentData` to extract: `from`, `to`, `value`, `validAfter`, `validBefore`, `nonce`, `v`, `r`, `s`
2. Verify `from == requester` (the client address passed to the function)
3. Verify `to == address(this)` (the BalanceTrackerX402 contract itself)
4. Verify `value + existing balance >= deliveryRate`
5. Call `USDC.transferWithAuthorization(from, to, value, validAfter, validBefore, nonce, v, r, s)` — tokens move atomically from client wallet to BalanceTrackerX402
6. Return updated balance: `(existing balance + value - deliveryRate)`

**When `paymentData` is empty**, the override delegates to `super._adjustInitialBalance(requester, balance, deliveryRate, "")`, preserving standard `transferFrom` behavior for pre-deposited funds. All existing payment flows are completely unchanged.

#### Contract scope

- `BalanceTrackerX402` extends `BalanceTrackerFixedPriceToken`, overriding only `_adjustInitialBalance`.
- Everything else (`adjustMechRequesterBalances`, `processPaymentByMultisig`, `mapMechBalances`, fee logic) is fully inherited.
- Registered via: MechMarketplace owner sets `mapPaymentTypeBalanceTrackers[keccak256("X402USDC")] = BalanceTrackerX402 address`.
- **MechMarketplace: ZERO changes. OlasMech: ZERO changes. Existing BalanceTrackers: ZERO changes.**

#### Required contract set

The marketplace resolves the balance tracker via `mapPaymentTypeBalanceTrackers[mech.paymentType()]`. For x402 to route correctly, **three** contracts are required (following the existing `MechFixedPriceTokenUSDC` pattern):

| Contract | Purpose |
|----------|---------|
| `BalanceTrackerX402` | EIP-3009 payment settlement (overrides `_adjustInitialBalance`) |
| `MechFixedPriceTokenX402` | Mech contract with `PAYMENT_TYPE = keccak256("X402USDC")`, routes to the x402 balance tracker |
| `MechFactoryFixedPriceTokenX402` | Factory to create `MechFixedPriceTokenX402` instances via CREATE2 |

### 3.2 Dual Off-Chain Signatures — Addressing Issue 2

The x402 client signs two messages in a single off-chain step. Both are free (no gas).

- **Signature 1 — Payment (EIP-3009):** client signs `TransferWithAuthorization` via EIP-712 typed data (domain: `{name, version, chainId, verifyingContract=USDC}`; message: `{from=client, to=BalanceTrackerX402, value, validAfter, validBefore, nonce}`). This is base64-encoded into a `PaymentPayload` and sent as the `X-Payment` header. The mech extracts the EIP-3009 parameters from the payload and encodes them into `paymentData` for on-chain settlement.
- **Signature 2 — Request (standard mech):** client signs `hash(requestData)` using the same private key. This goes into `DeliverWithSignature.signature` for MechMarketplace's on-chain `ecrecover` verification.

Both signatures are sent to the mech: the payment signature in the `X-Payment` header (per x402 standard), the request signature in the request body. The existing `valory-xyz/genai` x402 client library handles the payment signing transparently via `exact.sign_payment_header()`. The mech request signature is added as a second step before dispatch.

### 3.3 Dynamic Pricing — Addressing Issue 3

For the initial x402 implementation, quote generation depends on the mech type:

**Fixed-price mechs (including x402):** the quote is deterministic and requires no tool execution:

```
quote = maxDeliveryRate + (maxDeliveryRate * fee_bps / 10000)
```

The mech queries `MechMarketplace.fee()` for fee bps and returns this quote in the HTTP 402 response body.

**NVM/dynamic-price mechs (future scope):** on requests without payment headers, run tool with `delivery_rate=0` to get cost estimate, then inflate: `quote = tool_cost + (tool_cost * fee_bps / 10000)`.

#### Batch semantics

Each request in a `deliverMarketplaceWithSignatures` batch carries its **own** `paymentData` with its own EIP-3009 authorization and unique nonce. The `_adjustInitialBalance` override is called once per request inside the batch loop. The client signs one EIP-3009 authorization **per request**, not one covering the total batch.

**Critical: atomic batch revert.** Unlike `deliverMarketplace` (which uses `continue` to skip failed deliveries and returns a `bool[]`), `deliverMarketplaceWithSignatures` reverts the **entire transaction** if any single delivery fails — there is no partial success. Failure causes include bad signatures (`SignatureNotValidated`), duplicate request IDs (`AlreadyRequested`), and insufficient funds (`InsufficientBalance`). Per-request settlement (single-element arrays) is recommended to isolate failures and avoid one bad payment killing unrelated deliveries. The mech should pre-validate each EIP-3009 signature off-chain before submission to minimize on-chain reverts.

### 3.4 Mech as Facilitator

Rather than deploying a separate facilitator service, the mech itself exposes the facilitator endpoints. This keeps the architecture simple: the mech handles EIP-3009 signature verification, nonce checks, and balance checks in-process before executing the tool. There is no external service dependency and no cross-service communication for the verification step.

**Facilitator endpoints exposed by the mech:**

- `POST /verify` — validates the EIP-3009 signature, client balance, nonce, and timestamps. Returns `{ valid: true/false, reason }`.
- `GET /supported` — returns supported payment configurations (see Section 3.5 for schema).
- `GET /health` — liveness check. Returns 503 after repeated settlement timeouts (see Section 3.6).

On-chain settlement is **NOT** handled by the facilitator endpoint. It is handled by the mech's existing batch cycle via `deliverMarketplaceWithSignatures` — the same path used today for off-chain deliveries.

### 3.5 x402 Protocol Conformance

All headers and response schemas follow the [Coinbase x402 standard](https://github.com/coinbase/x402) as implemented in `valory-xyz/genai`.

**HTTP 402 response body** (returned when no `X-Payment` header is present):

```json
{
  "x402Version": 1,
  "accepts": [
    {
      "scheme": "exact",
      "network": "gnosis",
      "maxAmountRequired": "10200",
      "resource": "/predict",
      "description": "AI tool execution",
      "mimeType": "application/json",
      "payTo": "0xBalanceTrackerX402",
      "maxTimeoutSeconds": 900,
      "asset": "0x2a22f9c3b484c3629090FeED35F17Ff8F88f76F0",
      "extra": {
        "name": "USD Coin",
        "version": "2"
      }
    }
  ],
  "error": "Payment required"
}
```

**`X-Payment` request header** (client → mech): base64-encoded JSON `PaymentPayload` containing the signed `TransferWithAuthorization` parameters. Generated by `exact.sign_payment_header()` from the genai x402 client.

**`X-Payment-Response` response header** (mech → client): base64-encoded JSON with settlement status. For the batch-settled mech flow: `{ "success": true, "status": "pending_settlement" }`.

**`GET /supported` response:**

```json
{
  "kinds": [
    {
      "x402Version": 1,
      "scheme": "exact",
      "network": "gnosis"
    }
  ]
}
```

### 3.6 Settlement Failure Handling

The client receives their result at HTTP 200 (step 8), but on-chain settlement happens later in the mech's batch cycle (steps 9-10). This creates a window where settlement can fail. The following mitigations are adopted:

**Accepted risk model:** The mech accepts settlement failure risk as an operational cost, consistent with how Optimus handles x402 payments today. The economic risk per request is bounded by `maxDeliveryRate` (typically < $0.05 for AI tool calls), making the expected loss from occasional failures negligible.

**Mitigation 1 — Validity window sizing:** The client's `validBefore` timestamp is set to `now + maxTimeoutSeconds` (from `PaymentRequirements`). The mech sets `maxTimeoutSeconds` to cover at least 2x the expected batch cycle (recommended: 900 seconds / 15 minutes). The genai client sets `validAfter = now - 60s` to handle clock skew.

**Mitigation 2 — Client balance pre-check:** At verification time (step 6), the mech checks the client's on-chain USDC balance >= quote. This reduces (but does not eliminate) the risk of insufficient funds at settlement time.

**Mitigation 3 — Health-based circuit breaker:** Following the `x402-poc` facilitator pattern, the mech tracks `WaitForTransactionReceiptTimeoutError` counts. After 3 consecutive settlement timeouts, the `/health` endpoint returns 503, signaling the orchestrator to restart or pause the x402 flow. This prevents the mech from accumulating unbounded unsettled deliveries.

**Mitigation 4 — Settlement failure logging:** Failed settlements are logged with `(requestId, requester, nonce, failureReason)` for post-hoc analysis. Clients with repeated settlement failures can be flagged for manual review.

### 3.7 Nonce Management

EIP-3009 nonces are random `bytes32` values (not sequential), generated per-request via `secrets.token_bytes(32)` in the genai x402 client.

**On-chain protection:** USDC's contract-level nonce tracking prevents double-execution — if the same nonce is submitted twice, the second `transferWithAuthorization` call reverts. This is the authoritative replay protection layer.

**Off-chain protection (mech-side):** The mech maintains a local nonce set to reject duplicate authorizations **before** executing the tool:

1. On receiving an `X-Payment` header (step 5), the mech decodes the `PaymentPayload` and extracts the EIP-3009 `nonce`.
2. The nonce is checked against an in-memory set of accepted nonces.
3. If the nonce has been seen, the request is rejected with HTTP 409 (Conflict).
4. If the nonce is fresh, it is added to the set and the request proceeds.
5. The nonce set is persisted to the mech's shared state (`synchronized_data`) so it survives agent restarts and is consistent across the agent ensemble.

**Multi-mech isolation:** Each mech has its own `BalanceTrackerX402` address (the `to` field in the EIP-3009 authorization). An authorization signed for one mech's balance tracker cannot be replayed against a different mech. Cross-mech nonce tracking is not required.

---

## 4. End-to-End Flow

All HTTP steps are new. The on-chain batch cycle (steps 9-11) reuses the existing `deliverMarketplaceWithSignatures` path — the only new behavior is inside the overridden `_adjustInitialBalance`.

| Step | Layer | Description |
|------|-------|-------------|
| **1** | HTTP — off-chain | Client sends `POST /predict {tool, prompt}` to Mech. No `X-Payment` header present. |
| **2** | Mech — off-chain | Mech generates a cost estimate. For fixed-price mechs: `quote = maxDeliveryRate + (maxDeliveryRate * fee_bps / 10000)` — no tool execution needed. For NVM/dynamic mechs (future): run tool with `delivery_rate=0` to get cost estimate, then inflate with fee. Queries `MechMarketplace.fee()` for current fee bps. |
| **3** | HTTP — off-chain | Mech returns HTTP 402 with JSON body: `{ "x402Version": 1, "accepts": [PaymentRequirements], "error": "Payment required" }`. The `PaymentRequirements` includes `scheme: "exact"`, `network`, `maxAmountRequired: quote`, `payTo: BalanceTrackerX402`, `asset: USDC address`, `maxTimeoutSeconds: 900`, and `extra: { name, version }` for EIP-712 domain. |
| **4** | Client — off-chain | Client's x402 library (`genai/connections/x402`) selects a matching `PaymentRequirements` entry, calls `exact.sign_payment_header()` which: generates a random 32-byte nonce, sets `validAfter = now - 60s` / `validBefore = now + maxTimeoutSeconds`, signs the EIP-712 `TransferWithAuthorization` typed data, and base64-encodes the result as a `PaymentPayload`. Client also signs `hash(requestData)` for the mech request signature. |
| **5** | HTTP — off-chain | Client sends `POST /predict {tool, prompt}` with `X-Payment` header (base64-encoded `PaymentPayload`) and the request signature in the body. |
| **6** | Mech (`/verify`) — off-chain | Mech decodes `X-Payment` header, verifies: valid EIP-3009 signature, client USDC balance >= quote, nonce not in local set, `validBefore` is in the future. Adds nonce to local set. Proceeds if all pass. |
| **7** | Mech — off-chain | Mech executes tool, gets result. |
| **8** | HTTP — off-chain | Mech returns HTTP 200. Body: `{ result }`. `X-Payment-Response` header: base64-encoded `{ "success": true, "status": "pending_settlement" }`. Client has their result. |
| **9** | On-chain — batch | Mech Safe calls `OlasMech.deliverMarketplaceWithSignatures(requester=client, deliverWithSignatures=[{requestData, sig_4b, deliveryData}], deliveryRates=[quote], paymentData=<EIP-3009 params from step 4>)`. |
| **10** | On-chain — batch | MechMarketplace calls `BalanceTrackerX402.adjustMechRequesterBalances(mech, client, deliveryRates[], paymentData)`. Inside, the overridden `_adjustInitialBalance` decodes `paymentData`, calls `USDC.transferWithAuthorization` — funds move from client wallet to BalanceTrackerX402 atomically. Requester balance is credited with received funds and debited by deliveryRate; mech balance is credited. This is a single call — `checkAndRecordDeliveryRates` is NOT involved (that function is only used in the `request()` path, which x402 skips). |
| **11** | On-chain — batch | `BalanceTrackerX402.processPaymentByMultisig` (UNCHANGED): carves out marketplace fee, transfers remainder to Mech Safe. `collectedFees` updated. |

### What subgraphs see

- `MarketplaceDeliveryWithSignatures`: `deliveryMech=0xMech`, `requester=0xActualClient` — correct per-client attribution.
- Same event type as existing off-chain deliveries — no indexer changes required.
- `processPaymentByMultisig` fee logic: completely unchanged.

### Flow Routing

All four request paths coexist in the mech with no breaking changes to existing flows:

| Condition | Flow |
|-----------|------|
| `X-Payment` header present | x402 flow — verify in-process → execute → HTTP 200 |
| No headers, no `delivery_rate` | x402 quote — return deterministic quote (`maxDeliveryRate + fee`) → HTTP 402 |
| `delivery_rate` in body | Existing off-chain flow (unchanged) |
| On-chain event | Existing on-chain flow (unchanged) |

---

## 5. Worked Example

A single request with the following setup:

> **Tool cost:** 0.01 USDC | **Marketplace fee:** 2% (200 bps) | **Quote:** 0.0102 USDC
> **Client:** `0xClient` | **Mech:** `0xMech` (paymentType = X402_USDC) | **BalanceTrackerX402:** `0xBalX402`

### HTTP Phase

Client sends `POST /predict` with no `X-Payment` header. Mech calculates `0.01 + (0.01 * 200 / 10000) = 0.0102 USDC` and returns HTTP 402 with body:

```json
{
  "x402Version": 1,
  "accepts": [{
    "scheme": "exact",
    "network": "gnosis",
    "maxAmountRequired": "10200",
    "payTo": "0xBalX402",
    "asset": "0x2a22f9c3b484c3629090FeED35F17Ff8F88f76F0",
    "maxTimeoutSeconds": 900,
    "resource": "/predict",
    "description": "AI tool execution",
    "mimeType": "application/json",
    "extra": { "name": "USD Coin", "version": "2" }
  }],
  "error": "Payment required"
}
```

Client's x402 library signs both messages and retries with `X-Payment` header. Mech verifies in-process, executes the tool, returns HTTP 200 with result and `X-Payment-Response` header.

### On-Chain Batch Phase

Mech Safe submits:

```
requester     = 0xClient
deliveryRates = [10200]
paymentData   = abi.encode(from=0xClient, to=0xBalX402, value=10200,
                           validAfter, validBefore, nonce, v, r, s)
```

BalanceTrackerX402 settlement:

```
USDC.transferWithAuthorization: 10200 units moves 0xClient -> 0xBalX402
mapRequesterBalances[0xClient] += 10200, then -= 10200
mapMechBalances[0xMech] += 10200
```

`processPaymentByMultisig` (after 10 accumulated requests @ 10200 = 102000 total):

```
Fee: (102000 * 200 + 9999) / 10000 = 2040 -> marketplace treasury
Mech payment: 102000 - 2040 = 99960 -> Mech Safe
mapMechBalances[0xMech] reset to 0
```

---

## 6. What We Need to Build

### 6.1 Smart Contracts

**BalanceTrackerX402**
- Extends `BalanceTrackerFixedPriceToken`
- Overrides `_adjustInitialBalance` to decode and execute EIP-3009 `paymentData` when present, bypassing `_getRequiredFunds` → `transferFrom` entirely
- Falls back to `super._adjustInitialBalance` when `paymentData` is empty (standard pre-deposit flow)
- Constructor: `(mechMarketplace, drainer, usdcTokenAddress)` — same as `BalanceTrackerFixedPriceToken`

**MechFixedPriceTokenX402**
- Extends `MechFixedPriceBase`
- Defines `PAYMENT_TYPE = keccak256("X402USDC")` — routes to the x402 balance tracker
- Identical to `MechFixedPriceTokenUSDC` except for the `PAYMENT_TYPE` constant

**MechFactoryFixedPriceTokenX402**
- Extends `MechFactoryBase`
- Creates `MechFixedPriceTokenX402` instances via CREATE2
- Identical to `MechFactoryFixedPriceTokenUSDC` except it deploys `MechFixedPriceTokenX402`

**Registration (by MechMarketplace owner):**

```solidity
mechMarketplace.setPaymentTypeBalanceTrackers(
    [keccak256("X402USDC")],
    [BalanceTrackerX402_address]
);
mechMarketplace.setMechFactoryStatuses(
    [MechFactoryFixedPriceTokenX402_address],
    [true]
);
```

### 6.2 Mech Side (Resource Server + Facilitator)

**x402 Header Handling**
- Parse incoming `X-Payment` header to detect x402 requests (base64-decoded `PaymentPayload`)
- Return HTTP 402 with JSON body conforming to `x402PaymentRequiredResponse` schema (see Section 3.5)
- Return `X-Payment-Response` header on 200 responses with settlement status

**Quote Generation**
- For fixed-price mechs (including x402): `quote = maxDeliveryRate + (maxDeliveryRate * fee_bps / 10000)`. No tool execution needed.
- For NVM/dynamic mechs (future scope): run tool with `delivery_rate=0` to get cost estimate, then inflate with fee.
- Query `MechMarketplace.fee()` for current fee bps.

**In-Process Verification (Facilitator)**
- `POST /verify` — decode `X-Payment` header, validate EIP-3009 signature, check client on-chain USDC balance >= quote, check nonce not in local set, check `validBefore` is in future. Return `{ valid, reason }`.
- `GET /supported` — return `{ kinds: [{ x402Version: 1, scheme: "exact", network: "<chain>" }] }` per chain the mech supports
- `GET /health` — liveness check; returns 503 after 3 consecutive settlement timeouts (see Section 3.6)

**Nonce Tracking**
- Maintain in-memory nonce set, persist to `synchronized_data` for crash recovery
- Reject requests with previously seen nonces (HTTP 409)
- See Section 3.7 for details

**Flow Routing**
- Detect which flow applies based on headers (see Section 4 routing table)
- All four flows coexist — no breaking changes to existing paths

### 6.3 Client Side

**No new client SDK is required.** The existing x402 connection (`packages/valory/connections/x402/`) provides all client-side functionality:

- `exact.sign_payment_header(account, payment_requirements)` — signs EIP-3009 `TransferWithAuthorization` with random nonce, returns base64-encoded `PaymentPayload`
- `clients/requests.x402_requests(account)` — sync `requests.Session` with automatic 402 retry
- `clients/httpx.x402_httpx(account)` — async `httpx.AsyncClient` with automatic 402 retry
- `types.PaymentRequirements` — parsed from the 402 response body, used to select payment scheme and chain

**Integration pattern** (following Optimus):

```python
from x402.clients.requests import x402_requests

session = x402_requests(account=eoa_account)
response = session.post(f"{mech_url}/predict", json={"tool": "...", "prompt": "..."})
# First attempt returns 402 -> client auto-signs and retries -> second attempt returns 200
result = response.json()
```

The mech request signature (Signature 2) must be added as an extension to the genai x402 client — either as a custom `PaymentPayload.extra` field or as a separate body parameter. This is a small extension to the existing library, not a new SDK.

**Auto-funding** (optional, following Optimus pattern):
- Monitor USDC balance on the client EOA against a configurable threshold
- If below threshold, auto-swap native token to USDC via LiFi or similar DEX aggregator
- Configuration: `x402_payment_requirements: { "threshold": 200000, "topup": 250000 }` (USDC atomic units)

---

## 7. Contract Change Summary

| Component | Change Required | Notes |
|-----------|----------------|-------|
| `BalanceTrackerX402` | New deployment | Extends `BalanceTrackerFixedPriceToken`. Overrides `_adjustInitialBalance` to handle EIP-3009 `paymentData`, bypassing `_getRequiredFunds`/`transferFrom` when `paymentData` is present. |
| `MechFixedPriceTokenX402` | New deployment | Extends `MechFixedPriceBase`. Defines `PAYMENT_TYPE = keccak256("X402USDC")`. Routes to `BalanceTrackerX402` via marketplace. |
| `MechFactoryFixedPriceTokenX402` | New deployment | Extends `MechFactoryBase`. Creates `MechFixedPriceTokenX402` instances. Registered via `setMechFactoryStatuses`. |
| `MechMarketplace` | None | `paymentData` flows through unchanged. Owner registration call only. |
| `OlasMech` | None | `paymentData` passed through unchanged. |
| `BalanceTrackerNATIVE` | None | Completely untouched. |
| `BalanceTrackerTOKEN` | None | Completely untouched. |
| `BalanceTrackerNVM` | None | Completely untouched. |

---

## 8. Known Constraints

- **Native token mechs** (xDAI on Gnosis): not supported in this iteration. wxDAI does not implement EIP-3009. These mechs continue on their existing payment path unaffected.
- **Dynamic pricing:** fixed-price mechs quote their `max_delivery_rate`. Full per-request dynamic pricing for all mech types is a separate workstream.
- **EIP-3009 validity window:** the `validBefore` timestamp in the client's signed authorization must be long enough to cover the mech's batch cycle. The genai client uses `maxTimeoutSeconds` from `PaymentRequirements` (recommended: 900 seconds / 15 minutes).
- **On-chain settlement timing:** the client receives their result immediately (HTTP 200) but funds are not settled on-chain until the mech's next batch cycle. The `X-Payment-Response` header reflects this with `status: pending_settlement`.
- **Token coverage:** EIP-3009 (`transferWithAuthorization`) is not widely implemented — v1 supports USDC only. If broader token support is desired, a `BalanceTrackerX402Permit` variant using EIP-2612 (`permit` + `transferFrom`) could expand coverage to any EIP-2612 token. This is out of scope for v1.
- **Settlement failure risk:** accepted as operational cost for v1 — bounded by `maxDeliveryRate` per request. Mitigated by balance pre-checks, validity window sizing, and health-based circuit breaker (see Section 3.6).

---

## 9. Multi-Chain Support

USDC addresses with EIP-3009 support (from `genai/connections/x402/chains.py`):

| Network | Chain ID | USDC Address |
|---------|----------|-------------|
| Gnosis | 100 | `0x2a22f9c3b484c3629090FeED35F17Ff8F88f76F0` |
| Base | 8453 | `0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913` |
| Optimism | 10 | `0x0b2C639c533813f4Aa9D7837CAf62653d097Ff85` |
| Polygon | 137 | `0x2791Bca1f2de4661ED88A30C99A7a9449Aa84174` |
| Avalanche | 43114 | `0xB97EF9Ef8734C71904D8002F8b6Bc66Dd9c48a6E` |

Each chain requires its own `BalanceTrackerX402` deployment (with the chain's USDC address). The `GET /supported` endpoint returns the list of `{ x402Version, scheme, network }` entries for all chains where the mech has a registered balance tracker.

**v1 target chain:** Start with one chain where USDC supports EIP-3009. Gnosis is the primary mech chain and has USDC available. Verify EIP-3009 support on the specific USDC deployment before targeting.

---

## 10. Testing Strategy

### 10.1 Contract-Level Tests

Unit tests for the three new contracts, covering:

1. **Happy path:** Client signs EIP-3009, mech delivers via `deliverMarketplaceWithSignatures` with `paymentData`, `_adjustInitialBalance` override executes `transferWithAuthorization`, funds move atomically, balances update correctly
2. **Fallback:** Empty `paymentData` falls back to standard `transferFrom` pre-deposit flow via `super._adjustInitialBalance`
3. **Validation failures:** Wrong `from` address, wrong `to` address, insufficient `value`, expired `validBefore`, already-used nonce
4. **Batch delivery:** Multiple requests in one call, each with its own EIP-3009 authorization and unique nonce
5. **Fee accounting:** Verify `processPaymentByMultisig` fee calculation is unchanged
6. **Reentrancy:** Attempt reentrancy via malicious token (reuse existing `MechReentrancyAttacker` pattern)

Tests need a mock USDC with EIP-3009 support, or a fork of a chain where USDC is deployed.

### 10.2 End-to-End Integration Test

An integration test proving a standard x402 client can complete the full flow:

1. Spin up a local Hardhat/Anvil fork with USDC deployed
2. Deploy the three x402 contracts and register them on MechMarketplace
3. Use the `genai` x402 `requests` client to send a request to a test mech HTTP server
4. Verify: HTTP 402 response with correct `x402PaymentRequiredResponse` schema → client auto-retries with `X-Payment` header → HTTP 200 with result and `X-Payment-Response` header
5. Trigger the mech's batch settlement cycle
6. Verify: on-chain USDC moved from client to BalanceTrackerX402, `mapMechBalances` updated, `processPaymentByMultisig` distributes fees correctly

This validates "x402 compatible" as a claim with the actual Coinbase/genai client library.
