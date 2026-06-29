# x402 Integration Review — autonolas-marketplace

**Date**: 2026-03-18
**Branch**: `402` of `valory-xyz/autonolas-marketplace`
**Status**: Contracts NOT YET IMPLEMENTED — review based on specification documents

## Executive Summary

The x402 integration proposes adding EIP-3009 (`transferWithAuthorization`) based USDC payments to the Olas Mech Marketplace. The design is **architecturally sound**: it extends existing contracts without modifying them, uses a well-defined override point (`_adjustInitialBalance`), and follows established patterns in the codebase.

However, there are **several security-critical areas** that require careful attention during implementation and subsequent audit.

## Scope

### Documents Reviewed
- `docs/x402_spec.md` — Full technical specification
- `docs/x402_implementation_plan.md` — Implementation roadmap
- `docs/x402scan_integration.md` — Ecosystem integration guide
- `CLAUDE.md` — Project overview

### Contracts Reviewed (existing, to be extended)
- `BalanceTrackerBase.sol` — Abstract base with `_adjustInitialBalance` virtual
- `BalanceTrackerFixedPriceToken.sol` — Token variant (parent for x402)
- `MechMarketplace.sol` — Central orchestrator (unchanged)
- `OlasMech.sol` — Base mech (unchanged)

### Proposed Contracts (not yet written)
1. `BalanceTrackerX402USDC.sol` — EIP-3009 settlement handler
2. `MechFixedPriceTokenX402USDC.sol` — Mech with `paymentType = keccak256("X402USDC")`
3. `MechFactoryFixedPriceTokenX402USDC.sol` — CREATE2 factory

---

## Architecture Assessment

### What's Good

1. **Non-breaking design**: Zero modifications to MechMarketplace, OlasMech, or existing BalanceTrackers. X402 is a parallel opt-in path.

2. **Clean extension point**: `_adjustInitialBalance()` virtual override is the correct hook — the existing architecture was designed for this kind of extension.

3. **Dual signature model**: Separating payment signature (EIP-3009) from request signature avoids conflating authentication concerns. Each has its own verification path.

4. **Per-request settlement**: The spec correctly identifies that batch settlement is incompatible with EIP-3009 (clients can't pre-sign aggregate amounts). Per-request isolation is the right call.

5. **Fallback behavior**: Empty `paymentData` falls back to standard `transferFrom` — graceful degradation.

---

## Security Findings & Concerns

### HIGH — H-1: Atomic Settlement Race Condition

**Risk**: The spec describes an 11-step flow where:
- Step 7: Mech executes tool (off-chain, immediate)
- Step 10: `BalanceTrackerX402USDC._adjustInitialBalance()` calls `USDC.transferWithAuthorization()` (on-chain, delayed batch)

Between steps 7 and 10, the client's EIP-3009 authorization is outstanding. The client could:
- Transfer their USDC balance elsewhere before settlement
- Revoke authorization (EIP-3009 does NOT support revocation, but balance drain achieves the same effect)

**Spec's position**: "Settlement failure risk is accepted as operational cost, bounded by maxDeliveryRate (~$0.05)."

**Assessment**: For small amounts ($0.05) this is acceptable. But the architecture allows arbitrary `maxDeliveryRate`. If a mech charges $100/request, the unsecured window becomes meaningful.

**Recommendation**:
- Document max acceptable `maxDeliveryRate` for x402 flow
- Consider off-chain balance check at verification time (Step 6) — the spec already mentions this
- The circuit breaker (503 after 3 failures) is a good mitigation

### HIGH — H-2: EIP-3009 Signature Replay Across Chains

**Risk**: EIP-3009 `transferWithAuthorization` uses EIP-712 domain separator which includes `chainId`. However:
- The spec deploys `BalanceTrackerX402USDC` on multiple chains (Base, Optimism, Polygon, Gnosis)
- Each has different USDC contract addresses, so cross-chain replay is prevented at the USDC contract level
- BUT: if the same USDC address exists on two chains (e.g., via CREATE2 deployment), replay is possible

**Assessment**: Low practical risk because Circle deploys USDC at different addresses per chain. But worth a defensive check.

**Recommendation**: `BalanceTrackerX402USDC` constructor should validate `block.chainid` matches expected chain and store it as immutable. Verify EIP-712 domain separator includes the correct chain ID.

### MEDIUM — M-1: `paymentData` ABI Decode Safety

**Risk**: `BalanceTrackerX402USDC._adjustInitialBalance()` will `abi.decode(paymentData, ...)` to extract EIP-3009 parameters. Malformed `paymentData` could:
- Cause revert (losing the entire batch if not isolated)
- Pass unexpected values through to `transferWithAuthorization`

**Assessment**: The spec mandates per-request settlement (single-element arrays), which isolates failures. But the decode itself must be robust.

**Recommendation**:
- Validate `paymentData.length` before decoding
- Use try/catch around `transferWithAuthorization` call to handle USDC-level reverts gracefully
- Emit failure event with reason for debugging

### MEDIUM — M-2: Nonce Management Consistency

**Risk**: The spec uses random 32-byte nonces (EIP-3009 standard). Mech maintains local nonce set for off-chain dedup, persisted to `synchronized_data`. But:
- If mech crashes between verification (Step 6) and settlement (Step 10), the nonce set may be lost
- USDC's on-chain nonce tracking is authoritative, so double-execution is prevented
- But the mech may re-execute the tool (computational cost, not financial loss)

**Assessment**: The spec acknowledges this and relies on USDC's contract-level protection. Tool re-execution is bounded.

**Recommendation**: Persist nonces to disk/DB, not just in-memory. The spec's `synchronized_data` approach is correct but must survive restarts.

### MEDIUM — M-3: Gnosis Bridged USDC — EIP-3009 Support Unverified

**Risk**: The spec explicitly flags this as "Issue B". Gnosis USDC (`0x2a22f9c3b484c3629090FeED35F17Ff8F88f76F0`) is bridged, not native Circle USDC. Bridged USDC implementations often lack `transferWithAuthorization`.

**Assessment**: This is a **blocker** for Gnosis deployment. Calling `transferWithAuthorization` on a contract that doesn't implement it will revert, freezing all x402 settlements on that chain.

**Recommendation**:
- **MUST** verify on-chain before deployment: `cast call 0x2a22...76F0 "transferWithAuthorization(address,address,uint256,uint256,uint256,bytes32,uint8,bytes32,bytes32)" --rpc-url <gnosis_rpc>`
- If not supported, exclude Gnosis from v1 targets
- Base and Optimism (native Circle USDC) are safe targets

### LOW — L-1: Dynamic Pricing Formula Precision

**Risk**: Quote formula: `maxDeliveryRate * (10000 + fee_bps) / 10000`

If `maxDeliveryRate` is very small (e.g., 1 wei) and `fee_bps` < 10000, the fee rounds to zero. The mech receives the full amount, marketplace gets nothing.

**Assessment**: Unlikely in practice (USDC has 6 decimals, minimum practical price is 1 USDC = 1e6). But worth documenting.

**Recommendation**: Enforce minimum `maxDeliveryRate` in mech configuration or document the rounding behavior.

### LOW — L-2: Health Endpoint Circuit Breaker Timing

**Risk**: The spec defines: "503 after 3 consecutive settlement timeouts." But:
- Who resets the counter?
- Is it per-chain or global?
- What happens to in-flight requests when circuit opens?

**Assessment**: This is off-chain logic, not a smart contract concern. But affects mech availability.

**Recommendation**: Define circuit breaker scope (per-chain) and recovery mechanism (time-based reset or manual).

### LOW — L-3: `X-Payment` Header Parsing (Off-chain)

**Risk**: The `X-Payment` header contains base64-encoded `PaymentPayload`. Malformed base64 or unexpected JSON structure could crash the mech's HTTP handler.

**Assessment**: Standard input validation concern. Not smart contract related.

**Recommendation**: Defensive parsing with try/catch in mech application code.

### NOTE — N-1: Request Signature Transport Unresolved

The spec flags "Issue C": no decision on how Signature 2 (request hash) travels alongside the x402 `X-Payment` header. Three options proposed:
- `PaymentPayload.extra` field
- Separate body parameter
- Additional HTTP header

**Recommendation**: `PaymentPayload.extra` is cleanest — keeps both signatures in the same transport. Aligns with x402 spec's extension mechanism.

### NOTE — N-2: Testing Strategy — Fork vs Mock

The spec proposes a `MockUSDCEIP3009.sol` for testing. This is fine for unit tests but:
- Fork testing against real USDC on Base/Optimism should be required for integration tests
- Our Hyperlane experience shows Immunefi-level scrutiny expects fork-based PoCs

**Recommendation**: Both mock (unit) and fork (integration) testing required.

---

## Contract Implementation Checklist

When `BalanceTrackerX402USDC.sol` is implemented, verify:

| # | Check | Status |
|---|-------|--------|
| 1 | `_adjustInitialBalance` correctly decodes `paymentData` | Pending |
| 2 | Validates `from == requester` (sender matches) | Pending |
| 3 | Validates `to == address(this)` or `to == balanceTracker` (recipient matches) | Pending |
| 4 | Validates `value >= totalDeliveryRate` (sufficient amount) | Pending |
| 5 | Validates `validAfter <= block.timestamp <= validBefore` (time window) | Pending |
| 6 | Handles `paymentData.length == 0` → fallback to parent | Pending |
| 7 | Handles `transferWithAuthorization` revert gracefully | Pending |
| 8 | No reentrancy via `transferWithAuthorization` callback | Pending |
| 9 | Custom errors defined and used consistently | Pending |
| 10 | `PAYMENT_TYPE` constant matches keccak256("X402USDC") | Pending |
| 11 | CREATE2 factory produces correct bytecode hash | Pending |
| 12 | Registration script calls `setPaymentTypeBalanceTrackers` correctly | Pending |
| 13 | Per-request settlement enforced (single-element arrays) | Pending |
| 14 | Fee accounting unchanged from parent class | Pending |
| 15 | Events emitted for settlement success/failure | Pending |

---

## Comparison with Existing Payment Models

| Aspect | Native | Token (OLAS) | USDC | x402 (USDC) |
|--------|--------|-------------|------|-------------|
| Pre-deposit required | Yes | Yes | Yes | **No** (EIP-3009) |
| Settlement timing | Batch | Batch | Batch | **Per-request** |
| Signature model | Request only | Request only | Request only | **Dual** (payment + request) |
| External dependency | None | None | None | **USDC EIP-3009** |
| Mech modification | No | No | No | New mech type |
| Marketplace modification | No | No | No | **No** |

---

## Recommendations Summary

### Before Implementation
1. **Verify Gnosis USDC EIP-3009 support on-chain** (blocker)
2. **Decide on request signature transport** (Issue C)
3. **Define max acceptable `maxDeliveryRate`** for x402 flow

### During Implementation
4. Robust `paymentData` decoding with length check and try/catch
5. Validate all EIP-3009 parameters (`from`, `to`, `value`, `validAfter`, `validBefore`)
6. Use custom errors (not string reverts) per codebase convention
7. Per-request settlement isolation (single-element delivery arrays)

### Testing
8. Unit tests with `MockUSDCEIP3009.sol`
9. Fork tests against Base mainnet USDC
10. Settlement failure scenarios (insufficient balance, expired auth, nonce reuse)
11. Fallback path (empty `paymentData` → standard flow)

### Deployment
12. Target Base and Optimism first (confirmed EIP-3009)
13. Gnosis only after on-chain verification
14. Registration via marketplace owner multisig

---

## Conclusion

The x402 integration design is **well-thought-out and security-conscious**. The key risk is the settlement window between tool execution and on-chain payment (H-1), which the spec explicitly accepts for small amounts. The biggest blocker is Gnosis USDC EIP-3009 verification (M-3).

**Overall assessment**: Ready for implementation with the above recommendations. The audit of the actual contracts should focus on `BalanceTrackerX402USDC._adjustInitialBalance()` as the critical function — it's the only new on-chain logic touching user funds.
