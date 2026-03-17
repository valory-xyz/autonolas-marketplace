# x402 Compatibility — Spec Review & Implementation Plan

**Based on:** `docs/x402_spec.md` (updated spec)

---

## Part 1: Spec Review

### What's Correct

1. **Core approach is sound.** Using a new `BalanceTrackerX402` contract that extends `BalanceTrackerFixedPriceToken` is the right call. The `paymentData` field already flows through the entire chain (`OlasMech` -> `MechMarketplace` -> `BalanceTracker`) and is currently unused — this is clearly designed as an extension point.

2. **Zero changes to MechMarketplace and OlasMech** — confirmed. `paymentData` is passed through untouched in both contracts.

3. **Dual signature approach** — correct. The existing `deliverMarketplaceWithSignatures` already verifies the request signature (`ecrecover` on `requestData`). Adding a separate EIP-3009 payment signature that travels in `paymentData` is non-conflicting.

4. **Native token limitation** — correctly identified. WETH9/wxDAI does not support EIP-3009.

5. **Registration via `mapPaymentTypeBalanceTrackers`** — correct. A new payment type `keccak256("X402USDC")` maps to the new `BalanceTrackerX402` address, with matching `MechFixedPriceTokenX402` and `MechFactoryFixedPriceTokenX402`.

6. **Mech as Facilitator** — reasonable. Eliminates an external dependency.

7. **Override target `_adjustInitialBalance`** — correctly identified (Section 3.1). The call chain, the need to bypass `_getRequiredFunds`/`transferFrom`, and the `super` fallback for empty `paymentData` are all accurately described.

8. **Three-contract set** — the spec now correctly requires `BalanceTrackerX402`, `MechFixedPriceTokenX402`, and `MechFactoryFixedPriceTokenX402` (Section 3.1 "Required contract set").

9. **Quote generation** — Section 3.3 correctly distinguishes fixed-price (deterministic `maxDeliveryRate + fee`, no tool execution) from NVM/dynamic (future scope).

10. **x402 protocol conformance** — Section 3.5 defines exact header schemas (`X-Payment`, `X-Payment-Response`, 402 body) aligned with the Coinbase x402 standard.

11. **Existing client infrastructure** — The spec identifies `valory-xyz/genai` x402 client, `x402-poc` facilitator, and Optimus as existing infrastructure. No new client SDK needed.

12. **Settlement failure handling** — Section 3.6 takes an explicit position (accepted risk, bounded by `maxDeliveryRate`) with four mitigations.

13. **Nonce management** — Section 3.7 covers on-chain protection (USDC nonce tracking), off-chain protection (mech-side nonce set), and multi-mech isolation.

14. **End-to-end testing** — Section 10.2 specifies a concrete integration test plan using the genai x402 client against a local fork.

### Remaining Issues

#### Issue A — Batch Loop Claim (Corrected in Spec)

Section 3.3 originally stated `_adjustInitialBalance` "is called once per request inside the batch loop." This was incorrect and has been corrected. The spec now accurately describes that `_adjustInitialBalance` is called once per `adjustMechRequesterBalances` invocation with the summed total, making per-request settlement (single-element arrays) the only practical approach for x402.

#### Issue B — Gnosis USDC EIP-3009 Support Unverified

The spec lists Gnosis USDC (`0x2a22f9c3b484c3629090FeED35F17Ff8F88f76F0`) as a target but notes "Verify EIP-3009 support on the specific USDC deployment before targeting." This is bridged USDC, not native Circle USDC — EIP-3009 support is not guaranteed. This must be verified before choosing the v1 target chain. Base or Optimism (native Circle USDC) may be safer initial targets.

#### Issue C — Mech Request Signature Extension Undecided

Section 6.3 states the mech request signature (Signature 2) "must be added as an extension to the genai x402 client — either as a custom `PaymentPayload.extra` field or as a separate body parameter." No decision is made. This needs to be resolved before implementation since it affects both the client library change and the mech's parsing logic.

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
(address from, address to, uint256 value, uint256 validAfter, uint256 validBefore,
 bytes32 nonce, uint8 v, bytes32 r, bytes32 s) = abi.decode(paymentData, ...)

// Validations
require(from == requester)          // X402InvalidSender
require(to == address(this))        // X402InvalidRecipient
require(value + balance >= deliveryRate)  // X402InsufficientPayment

// Execute atomic transfer — bypasses _getRequiredFunds/transferFrom entirely
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
// keccak256("X402USDC")
bytes32 public constant PAYMENT_TYPE = 0x...;
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

#### 2.1 Create contract test file

**Location:** `test/MechFixedPriceTokenX402.js`

**Test cases:**
1. **Happy path:** Client signs EIP-3009, mech delivers via `deliverMarketplaceWithSignatures` with `paymentData`, `_adjustInitialBalance` override executes `transferWithAuthorization`, funds move atomically, balances update correctly
2. **Fallback:** Empty `paymentData` falls back to standard `transferFrom` pre-deposit flow via `super._adjustInitialBalance`
3. **Validation failures:** Wrong `from` address, wrong `to` address, insufficient `value`, expired `validBefore`, already-used nonce
4. **Per-request settlement:** Single-element arrays with individual EIP-3009 authorizations
5. **Fee accounting:** Verify `processPaymentByMultisig` fee calculation is unchanged
6. **Reentrancy:** Attempt reentrancy via malicious token (reuse existing `MechReentrancyAttacker` pattern)

**Mock contract needed:** `MockUSDC` with EIP-3009 `transferWithAuthorization` support (in `contracts/test/`). Alternatively, fork a chain with real USDC deployed.

#### 2.2 End-to-end integration test (Phase 4 dependency)

Per spec Section 10.2 — use `genai` x402 client against a local Hardhat/Anvil fork:
1. Deploy x402 contracts + register on MechMarketplace
2. HTTP 402 response with correct `x402PaymentRequiredResponse` schema
3. Client auto-retries with `X-Payment` header -> HTTP 200 with result
4. Trigger batch settlement, verify on-chain USDC movement and fee distribution

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
);
mechMarketplace.setMechFactoryStatuses(
    [mechFactoryX402Address],
    [true]
);
```

#### 3.3 Chain targets

Start with one chain where USDC has verified EIP-3009 support. Base and Optimism have native Circle USDC and are safer initial targets. Gnosis USDC (`0x2a22...`) is bridged — verify `transferWithAuthorization` support before targeting.

Per-chain deployment: each chain requires its own `BalanceTrackerX402` instance with that chain's USDC address.

### Phase 4 — Mech-Side (Off-Chain, Out of This Repo)

This is mech application code (not in this repo). Key deliverables per spec Sections 6.2-6.3:

**Mech (Resource Server + Facilitator):**
- HTTP 402 response body conforming to `x402PaymentRequiredResponse` schema (Section 3.5)
- Parse `X-Payment` header (base64-decoded `PaymentPayload`)
- Return `X-Payment-Response` header on 200 responses
- Quote calculation: `maxDeliveryRate * (10000 + feeBps) / 10000` for fixed-price mechs
- In-process `/verify`, `/supported`, `/health` endpoints
- Nonce tracking: in-memory set persisted to `synchronized_data` (Section 3.7)
- Health circuit breaker: 503 after 3 consecutive settlement timeouts (Section 3.6)
- Flow routing based on `X-Payment` header presence (Section 4)
- Per-request settlement: single-element arrays for `deliverMarketplaceWithSignatures`

**Client (genai x402 library extension):**
- No new SDK — extend existing `valory-xyz/genai` x402 client
- Add mech request signature (Signature 2) as custom `PaymentPayload.extra` field or separate body parameter (decision needed — Issue C above)
- Optional auto-funding: swap native -> USDC when balance below threshold (Optimus pattern)

### Dependency Order

```
Phase 1.4 (errors)
  -> Phase 1.1 (BalanceTrackerX402)
  -> Phase 1.2 (MechFixedPriceTokenX402)  [independent of 1.1]
  -> Phase 1.3 (MechFactoryX402)           [depends on 1.2]
  -> Phase 2.1 (contract tests)            [depends on all of Phase 1]
  -> Phase 3   (deployment)                [depends on Phase 2.1 passing]
Phase 4 (mech + client off-chain)          [independent, can parallel]
  -> Phase 2.2 (E2E integration test)      [depends on Phase 3 + Phase 4]
```

### Files to Create

| File | Purpose |
|------|---------|
| `contracts/mechs/token/x402/BalanceTrackerX402.sol` | EIP-3009 payment settlement |
| `contracts/mechs/token/x402/MechFixedPriceTokenX402.sol` | Mech with X402USDC payment type |
| `contracts/mechs/token/x402/MechFactoryFixedPriceTokenX402.sol` | Factory for x402 mechs |
| `contracts/test/MockUSDCEIP3009.sol` | Mock USDC with `transferWithAuthorization` |
| `test/MechFixedPriceTokenX402.js` | Contract test suite |
| `scripts/deployment/deploy_08_balance_tracker_x402.js` | Deployment script |
| `scripts/deployment/deploy_08_balance_tracker_x402.sh` | Deployment wrapper |
| `scripts/deployment/deploy_09_mech_factory_x402.js` | Factory deployment |
| `scripts/deployment/deploy_09_mech_factory_x402.sh` | Factory deployment wrapper |

### Files to Modify

None — all existing contracts remain untouched as the spec intends. Only `docs/configuration.json` updates post-deployment.

---

## Part 3: Remaining Open Items

Most gaps identified in the earlier review have been addressed by the updated spec. The following items remain:

### ~~Open Item 1 — Batch Loop Claim~~ (Resolved)

Spec Section 3.3 has been corrected. It now accurately describes that `_adjustInitialBalance` is called once with the summed total, and that per-request settlement is the only practical approach for x402.

### Open Item 2 — Gnosis USDC EIP-3009 Verification

Blocking for chain selection. Bridged USDC on Gnosis may not support `transferWithAuthorization`. Needs an on-chain check (`cast call 0x2a22... "transferWithAuthorization(address,address,uint256,uint256,uint256,bytes32,uint8,bytes32,bytes32)"` or inspect the contract source) before committing to Gnosis as v1 target. See Issue B above.

### Open Item 3 — Mech Request Signature Transport

How Signature 2 (request hash) is transmitted alongside the x402 `X-Payment` header needs a decision. Options: `PaymentPayload.extra` field, separate body parameter, or separate header. This affects both the genai client extension and the mech's parsing logic. See Issue C above.
