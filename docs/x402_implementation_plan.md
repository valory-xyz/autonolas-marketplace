# x402 Compatibility — Spec Review & Implementation Plan

## Part 1: Spec Review

### What's Correct

1. **Core approach is sound.** Using a new `BalanceTrackerX402` contract that extends `BalanceTrackerFixedPriceToken` is the right call. The `paymentData` field already flows through the entire chain (`OlasMech` -> `MechMarketplace` -> `BalanceTracker`) and is currently unused — this is clearly designed as an extension point.

2. **Zero changes to MechMarketplace and OlasMech** — confirmed. `paymentData` is passed through untouched in both contracts.

3. **Dual signature approach** — correct. The existing `deliverMarketplaceWithSignatures` already verifies the request signature (`ecrecover` on `requestData`). Adding a separate EIP-3009 payment signature that travels in `paymentData` is non-conflicting.

4. **Native token limitation** — correctly identified. WETH9/wxDAI does not support EIP-3009.

5. **Registration via `mapPaymentTypeBalanceTrackers`** — correct. A new payment type (e.g., `X402_USDC`) maps to the new `BalanceTrackerX402` address. This requires a corresponding `MechFixedPriceTokenX402` contract with the matching `PAYMENT_TYPE` constant (following the `MechFixedPriceTokenUSDC` pattern).

6. **Mech as Facilitator** — reasonable. Eliminates an external dependency.

### Issues Found in the Spec

#### Issue A — Wrong Function Override Target (Critical)

The spec (Section 3.1 and Step 10 in the end-to-end flow) says:
> "When `checkAndRecordDeliveryRates` receives non-empty paymentData..."

This is **incorrect** for the `deliverMarketplaceWithSignatures` flow. Tracing the actual code:

```
OlasMech.deliverMarketplaceWithSignatures()
  -> MechMarketplace.deliverMarketplaceWithSignatures()  [line 833]
       -> IBalanceTracker.adjustMechRequesterBalances()   [line 864]
            -> _adjustInitialBalance()                    [line 320]
```

`checkAndRecordDeliveryRates` is only called during the **request phase** (`_requestBatch`), which does NOT exist in the x402 flow (the whole point is atomic request+delivery).

**Correct override target:** `_adjustInitialBalance` (internal virtual function in `BalanceTrackerBase`, line 90). This function:
- Is called by BOTH `checkAndRecordDeliveryRates` and `adjustMechRequesterBalances`
- Already accepts `paymentData` as `bytes memory` (unnamed/ignored in base)
- If balance < deliveryRate, it calls `_getRequiredFunds` to pull tokens via `transferFrom`
- For x402, override to decode EIP-3009 from `paymentData` instead of using `transferFrom`

#### Issue B — End-to-End Flow Steps 10-11 Reference Wrong Functions

Step 10 says "BalanceTrackerX402.checkAndRecordDeliveryRates" — should say `adjustMechRequesterBalances` (which internally calls the overridden `_adjustInitialBalance`).

Step 11 says "BalanceTrackerX402.adjustMechRequesterBalances" as a separate step — in reality, steps 10 and 11 happen inside the same `adjustMechRequesterBalances` call. The requester balance credit (from EIP-3009) and debit (delivery rate) happen together in `_adjustInitialBalance`, and the mech balance credit happens on the next line.

#### Issue C — Missing MechFixedPriceTokenX402 and MechFactoryFixedPriceTokenX402

The spec mentions only `BalanceTrackerX402` as a new contract. However, the payment type routing requires a **Mech contract** with the matching `PAYMENT_TYPE` constant. Looking at the existing pattern:

- `MechFixedPriceTokenUSDC` has `PAYMENT_TYPE = keccak256("FixedPriceTokenUSDC")`
- The marketplace resolves the balance tracker via `mapPaymentTypeBalanceTrackers[mech.paymentType()]`

For x402 to route to `BalanceTrackerX402`, we also need:
- `MechFixedPriceTokenX402` with `PAYMENT_TYPE = keccak256("X402USDC")` (or similar)
- `MechFactoryFixedPriceTokenX402` to create these mechs

Without these, there's no mech whose `paymentType()` maps to the x402 balance tracker.

#### Issue D — Quote Generation Underspecified

Section 3.3 says "run tool with delivery_rate=0 to get cost estimate." This is vague:
- Who pays for the compute of running the tool at rate=0?
- Is this exploitable (free tool execution to get results without paying)?
- Fixed-price mechs "use max_delivery_rate as the estimate" — this contradicts running the tool, since the price is already known.

For fixed-price mechs, the quote should simply be `maxDeliveryRate + fee`. No tool execution needed for the estimate.

#### Issue E — Batch Semantics Unclear

`deliverMarketplaceWithSignatures` processes multiple requests per call (array of `DeliverWithSignature`), but `paymentData` is a single `bytes` value. The spec's worked example shows a single request. For batches:
- One EIP-3009 authorization must cover `value >= sum(deliveryRates)`
- This should be explicitly stated since the client signs the authorization before knowing exact batch composition

#### Issue F — _getRequiredFunds Conflict

In the base `_adjustInitialBalance` (line 97-101), when `balance < deliveryRate`, it calls `_getRequiredFunds(requester, balanceDiff)` which does a `transferFrom`. For x402, we don't want this `transferFrom` fallback — we want the EIP-3009 path exclusively. The override of `_adjustInitialBalance` must **not** call `super` (or must bypass the `_getRequiredFunds` call) when `paymentData` is present.

---

## Part 2: Implementation Plan

### Phase 1 — Smart Contracts

#### 1.1 Create `BalanceTrackerX402` contract

**Location:** `contracts/mechs/token/x402/BalanceTrackerX402.sol`

**Extends:** `BalanceTrackerFixedPriceToken`

**Override:** `_adjustInitialBalance(address requester, uint256 balance, uint256 deliveryRate, bytes memory paymentData)`

Logic:
```
if paymentData is empty:
    return super._adjustInitialBalance(requester, balance, deliveryRate, "")
    // Falls back to standard transferFrom behavior

// Decode EIP-3009 params from paymentData
(address from, address to, uint256 value, uint256 validAfter, uint256 validBefore, bytes32 nonce, uint8 v, bytes32 r, bytes32 s) = abi.decode(paymentData, ...)

// Validations
require(from == requester)
require(to == address(this))
require(value + balance >= deliveryRate)

// Execute atomic transfer
IUSDC(token).transferWithAuthorization(from, to, value, validAfter, validBefore, nonce, v, r, s)

// Update balance: add received funds, subtract delivery rate
return (balance + value - deliveryRate)
```

**Constructor:** Same as `BalanceTrackerFixedPriceToken` — `(mechMarketplace, drainer, usdcTokenAddress)`

**Interface needed:** Add `IEIP3009` interface with `transferWithAuthorization` signature.

#### 1.2 Create `MechFixedPriceTokenX402` contract

**Location:** `contracts/mechs/token/x402/MechFixedPriceTokenX402.sol`

**Extends:** `MechFixedPriceBase`

**Pattern:** Identical to `MechFixedPriceTokenUSDC` but with:
```solidity
bytes32 public constant PAYMENT_TYPE = keccak256("X402USDC");
```

#### 1.3 Create `MechFactoryFixedPriceTokenX402` contract

**Location:** `contracts/mechs/token/x402/MechFactoryFixedPriceTokenX402.sol`

**Extends:** `MechFactoryBase`

**Pattern:** Identical to `MechFactoryFixedPriceTokenUSDC` but creates `MechFixedPriceTokenX402` instances.

#### 1.4 Add error definitions

In `contracts/interfaces/IErrorsMarketplace.sol` or a new `IErrorsX402.sol`:
- `X402InvalidSender(address provided, address expected)`
- `X402InvalidRecipient(address provided, address expected)`
- `X402InsufficientPayment(uint256 provided, uint256 required)`

### Phase 2 — Tests

#### 2.1 Create test file

**Location:** `test/MechFixedPriceTokenX402.js`

**Test cases:**
1. **Happy path:** Client signs EIP-3009, mech delivers via `deliverMarketplaceWithSignatures` with paymentData, funds move atomically, balances update correctly
2. **Fallback:** Empty paymentData falls back to standard `transferFrom` pre-deposit flow
3. **Validation failures:** Wrong `from` address, wrong `to` address, insufficient `value`, expired `validBefore`, already-used nonce
4. **Batch delivery:** Multiple requests in one call, single EIP-3009 covering total
5. **Fee accounting:** Verify `processPaymentByMultisig` fee calculation is unchanged
6. **Reentrancy:** Attempt reentrancy via malicious token (reuse existing `MechReentrancyAttacker` pattern)

**Note:** Tests need a mock USDC with EIP-3009 support, or use a fork of a chain where USDC is deployed.

### Phase 3 — Deployment

#### 3.1 Deployment scripts

Following the existing numbered pattern in `scripts/deployment/`:
- `deploy_08_balance_tracker_x402.js` / `.sh`
- `deploy_09_mech_factory_x402.js` / `.sh`

#### 3.2 Registration

After deployment, the MechMarketplace owner calls:
```solidity
mechMarketplace.setPaymentTypeBalanceTrackers(
    [keccak256("X402USDC")],
    [balanceTrackerX402Address]
)
```

And whitelists the new factory:
```solidity
mechMarketplace.setMechFactoryStatuses(
    [mechFactoryX402Address],
    [true]
)
```

#### 3.3 Chain targets

Start with one chain where USDC supports EIP-3009 (Ethereum mainnet, Arbitrum, or Base). Gnosis (xDAI/USDC) should be verified for EIP-3009 support before targeting.

### Phase 4 — Mech-Side (Off-Chain, Out of This Repo)

This is mech application code, not smart contract code. Included for completeness:

- HTTP 402 response with `PAYMENT-REQUIRED` header
- Parse `PAYMENT-SIGNATURE` header (dual signatures)
- In-process `/verify`, `/supported`, `/health` endpoints
- Quote calculation: `maxDeliveryRate * (10000 + feeBps) / 10000` for fixed-price mechs
- Flow routing based on header presence
- Batch accumulation and periodic `deliverMarketplaceWithSignatures` submission

### Dependency Order

```
Phase 1.4 (errors)
  -> Phase 1.1 (BalanceTrackerX402)
  -> Phase 1.2 (MechFixedPriceTokenX402)  [independent of 1.1]
  -> Phase 1.3 (MechFactoryX402)           [depends on 1.2]
  -> Phase 2.1 (tests)                     [depends on all of Phase 1]
  -> Phase 3   (deployment)                [depends on Phase 2 passing]
Phase 4 (mech off-chain)                   [independent, can parallel]
```

### Files to Create

| File | Purpose |
|------|---------|
| `contracts/mechs/token/x402/BalanceTrackerX402.sol` | EIP-3009 payment settlement |
| `contracts/mechs/token/x402/MechFixedPriceTokenX402.sol` | Mech with X402USDC payment type |
| `contracts/mechs/token/x402/MechFactoryFixedPriceTokenX402.sol` | Factory for x402 mechs |
| `test/MechFixedPriceTokenX402.js` | Test suite |
| `scripts/deployment/deploy_08_balance_tracker_x402.js` | Deployment script |
| `scripts/deployment/deploy_08_balance_tracker_x402.sh` | Deployment wrapper |
| `scripts/deployment/deploy_09_mech_factory_x402.js` | Factory deployment |
| `scripts/deployment/deploy_09_mech_factory_x402.sh` | Factory deployment wrapper |

### Files to Modify

None — all existing contracts remain untouched as the spec intends. Only `docs/configuration.json` updates post-deployment.

---

## Part 3: Gaps for Full x402 Compatibility

Phases 1–3 cover the on-chain settlement layer. The following gaps remain for a production-ready, fully x402-compatible system.

### Gap 1 — No x402 Protocol Compliance Verification

The spec references x402 headers (`PAYMENT-REQUIRED`, `PAYMENT-SIGNATURE`, `PAYMENT-RESPONSE`) but does not specify the exact header schema or validate conformance to the x402 standard. If the mech claims x402 compatibility, clients using standard x402 libraries need to interoperate — header formats must match the protocol spec exactly. A conformance checklist or test against a reference x402 client is needed.

### Gap 2 — No Client SDK / Library

The spec assumes clients will sign dual signatures (EIP-3009 + request hash) transparently. This requires either:
- An integration with an existing x402 client library that supports custom payment schemes, or
- A purpose-built client library that handles dual signing, quote parsing, and retry-on-402

Phase 4 covers the mech (server) side but says nothing about the client side. Without a client SDK, no one can actually use the x402 flow.

### Gap 3 — EIP-3009 Token Coverage Is USDC-Only

The plan hardcodes USDC as the only supported token. EIP-3009 (`transferWithAuthorization`) is not widely implemented — most ERC20s (including OLAS) do not support it. This means x402 compatibility is limited to USDC-denominated mechs.

If broader token support is desired, EIP-2612 (`permit`) is a more widely supported alternative. A `BalanceTrackerX402Permit` variant could use `permit` + `transferFrom` instead of `transferWithAuthorization`, expanding coverage to any EIP-2612 token. This is not a blocker for v1 but should be a conscious scope decision.

### Gap 4 — Settlement Failure Handling (Architectural Risk)

The client receives their result at HTTP 200 (step 8), but on-chain settlement happens later in a batch (step 9). If settlement fails, the mech has delivered the service but cannot collect payment. Failure scenarios:

- **Client moves USDC** between HTTP 200 and batch submission — `transferWithAuthorization` reverts due to insufficient balance
- **`validBefore` expires** before the batch lands on-chain (gas spikes, sequencer delays, operator downtime)
- **Nonce collision** if the client reuses the nonce in another transaction before settlement

There is no retry mechanism, no escrow, and no recourse defined. This is a real economic risk for mech operators. Possible mitigations:
- **Short-circuit settlement:** settle on-chain immediately per request instead of batching (higher gas, but eliminates the window)
- **Escrow pattern:** pull funds into escrow at verification time, release on delivery (requires a different EIP-3009 flow)
- **Off-chain reputation:** track clients who cause settlement failures and refuse future requests
- **Over-collateralization:** require clients to pre-deposit a bond that covers potential failures

The spec should take an explicit position on acceptable settlement failure risk and define at least one mitigation strategy.

### Gap 5 — Nonce Management (Off-Chain State)

EIP-3009 nonces are arbitrary `bytes32` values (not sequential). Between receiving the client's signed authorization (step 5) and on-chain settlement (step 9), the mech must track which nonces it has accepted to prevent:
- Replay attacks (same authorization submitted twice to different mechs)
- Double-spending (client signs two authorizations with the same nonce for different mechs)

On-chain, USDC's nonce tracking prevents double-execution. But off-chain, the mech needs its own nonce registry to avoid executing a tool for an authorization it has already seen or that another mech has already claimed. In a multi-mech environment, this may require a shared nonce registry or at minimum per-mech nonce tracking with persistence across restarts.

### Gap 6 — Multi-Chain x402 Discovery

The x402 `PAYMENT-REQUIRED` response must tell the client which chain and which `BalanceTrackerX402` address to target. If the same mech service operates across multiple chains (e.g., Ethereum + Arbitrum), the client needs to:
- Know which chains are supported
- Select the appropriate chain based on their token holdings
- Get the correct `BalanceTrackerX402` address for that chain

The `/supported` endpoint is mentioned in the spec but its schema is not defined. It should include at minimum: `chainId`, `tokenAddress`, `balanceTrackerAddress`, and `paymentType` for each supported configuration.

### Gap 7 — No End-to-End Integration Test

The test plan (Phase 2) covers contract-level unit tests but not an end-to-end test proving a standard x402 client library can complete the full flow (HTTP 402 → sign → HTTP 200 → on-chain settlement). Without this, "x402 compatible" is a claim without verification. An integration test should use a reference x402 client against a test mech on a local fork.
