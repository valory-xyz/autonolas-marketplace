# x402 Integration — Key Security Findings

**Date**: 2026-03-18 (last refreshed 2026-06-29)
**Branch**: `402` of `valory-xyz/autonolas-marketplace`
**Status**: Pre-implementation review (contracts not yet written)
**Line numbers in this document** reference `MechMarketplace.sol` as of commit `6b26aa5` on this branch. They may have drifted on `main` (e.g. `getRequestId` is at line 883 on `main` at time of writing). Re-check against the target SHA before quoting.

## Findings Summary

| # | Severity | Finding | Component |
|---|----------|---------|-----------|
| H-1 | High | Settlement race condition — client can drain USDC between tool execution and on-chain settlement | BalanceTrackerX402USDC |
| M-1 | Medium | Nonce persistence — in-memory nonce set lost on mech crash, risk of tool re-execution | Off-chain (mech app) |
| M-2 | Medium | **BLOCKER**: Gnosis bridged USDC EIP-3009 support unverified on-chain | Deployment |
| L-1 | Low | Circuit breaker scope (per-chain vs global) and reset mechanism undefined | Off-chain (mech app) |
| N-1 | Note | Request signature transport mechanism undecided (Issue C in spec) | Protocol design |
| N-2 | Note | Fork-based integration tests required alongside mock unit tests | Testing |
| N-3 | Note | Multi-mech isolation mechanism mis-identified in spec (shared BalanceTracker, not per-mech) | Spec correction |
| ~~H-2~~ | ~~High~~ | ~~EIP-3009 cross-chain replay~~ — Removed: USDC's own EIP-712 domain separator handles this | N/A |
| ~~old M-1~~ | ~~Medium~~ | ~~paymentData ABI decode safety~~ — Removed: `abi.decode` revert is correct; try/catch would allow unpaid deliveries | N/A |
| ~~old L-1~~ | ~~Low~~ | ~~Fee rounding to zero~~ — Removed: ceil division already prevents this | N/A |

## H-1: Settlement Race Condition

The x402 flow separates tool execution (immediate, off-chain) from payment settlement (delayed, on-chain batch). Between these two events, the client's EIP-3009 authorization is outstanding but unsecured. The client could transfer their USDC balance elsewhere before the mech settles on-chain.

**Spec's position**: Settlement failure risk is accepted as operational cost, bounded by `maxDeliveryRate` (typically ~$0.05 per request).

**Concern**: The architecture allows arbitrary `maxDeliveryRate`. If a mech charges $100/request, the unsecured window becomes meaningful.

**Mitigating factor**: The requester explicitly signs the delivery rate as part of the requestId (`getRequestId` includes `deliveryRate` at MechMarketplace line 232), and `_verifySignedHash` validates this signature (line 236). The mech cannot inflate the rate beyond what the requester agreed to.

**Recommendations**:
- Document maximum acceptable `maxDeliveryRate` for x402 flow
- Enforce off-chain balance check at verification time (Step 6)
- Circuit breaker (503 after 3 consecutive failures) is a good existing mitigation

## ~~H-2: EIP-3009 Cross-Chain Replay~~ — REMOVED

**Original claim**: `BalanceTrackerX402USDC` should store `block.chainid` to prevent cross-chain replay.

**Why removed**: `BalanceTrackerX402USDC` does not verify EIP-3009 signatures — USDC does. USDC's own EIP-712 domain separator already includes both `chainId` and `verifyingContract` (the USDC contract address, which differs per chain). Adding chainId validation to the BalanceTracker would be redundant gas cost with zero security benefit. The theoretical "same USDC address on two chains via CREATE2" scenario is not realistic — Circle deploys USDC via proxies with chain-specific governance.

## ~~M-1: paymentData ABI Decode Safety~~ — REMOVED

**Original recommendations**: Validate `paymentData.length`, use try/catch around `transferWithAuthorization`, emit failure events.

**Why removed**:
- **try/catch is harmful**: If `transferWithAuthorization` fails but the delivery is recorded (not reverted), the mech gets credited without funds arriving. The atomic revert is the correct behavior — it prevents unpaid deliveries.
- **Length validation is redundant**: `abi.decode` already reverts on malformed input. An explicit length check adds gas for no benefit.
- **Emit + revert is impossible**: Cannot emit an event and revert in the same transaction (the event is rolled back).
- **Per-request settlement already isolates failures**: The spec recommends single-element arrays, so one bad `paymentData` cannot affect unrelated deliveries.

## M-1: Nonce Management Consistency

EIP-3009 uses random 32-byte nonces. The mech maintains a local nonce set for off-chain dedup, persisted to `synchronized_data`. If the mech crashes between verification and settlement, the nonce set may be lost. USDC's on-chain nonce tracking prevents double-payment, but the mech may re-execute the tool (computational cost, not financial loss).

**Recommendation**: Persist nonces to disk/DB, not just in-memory. The spec's `synchronized_data` approach is correct but must survive restarts.

## M-2: Gnosis Bridged USDC — BLOCKER

Gnosis USDC (`0x2a22f9c3b484c3629090FeED35F17Ff8F88f76F0`) is bridged, not native Circle USDC. Bridged USDC implementations often lack `transferWithAuthorization`. Calling it on a contract that doesn't implement it will revert, freezing all x402 settlements on that chain.

**Recommendation**:
- **MUST** verify on-chain before deployment
- If not supported, exclude Gnosis from v1 targets
- Base and Optimism (native Circle USDC) are confirmed safe targets

## ~~L-1: Fee Rounding to Zero~~ — REMOVED

**Original claim**: Fee can round to zero when `maxDeliveryRate` is very small.

**Why removed**: `_processPayment` in BalanceTrackerBase (line 158) uses **ceil division**:
```solidity
marketplaceFee = (balance * fee + (MAX_FEE_FACTOR - 1)) / MAX_FEE_FACTOR;
```
When `fee > 0` and `balance >= 1`, `marketplaceFee` is always `>= 1`. Additionally, fees are calculated on accumulated `mapMechBalances[mech]` (after multiple deliveries), not per-request — so small individual delivery rates aggregate before the fee is taken.

## ~~N-3: Multi-Mech Isolation Mechanism Mis-Identified in Spec~~ (Resolved)

**Resolved.** The current `x402_spec.md` §3.7 ("Multi-mech isolation") already describes the shared tracker correctly: `BalanceTrackerX402USDC` is shared per payment type, isolation comes from USDC nonce consumption and request-signature binding. The finding remains here as a struck-through record of the historical mismatch.

Original text:
> Spec Section 3.7 states: "Each mech has its own `BalanceTrackerX402USDC` address (the `to` field in the EIP-3009 authorization)." This is incorrect. There is ONE `BalanceTrackerX402USDC` per payment type, shared by ALL x402 mechs. Cross-mech replay is still prevented, but by USDC nonce consumption and by `requestId` including the mech address in `getRequestId`. (Cites "Issue C" in the original; the spec's current labeling is Issue 2 / Signature 2.)

## Overall Assessment

The x402 integration design is architecturally sound and security-conscious. The key risk is the settlement window between tool execution and on-chain payment (H-1), which the spec explicitly accepts for small amounts. The biggest blocker is Gnosis USDC EIP-3009 verification (M-2).

Three original findings were removed after code review:
- **H-2** (cross-chain replay): USDC's own domain separator handles this; BalanceTracker doesn't verify signatures.
- **M-1** (ABI decode safety): Atomic revert on bad `paymentData` is correct behavior; try/catch would allow unpaid deliveries.
- **L-1** (fee rounding): Ceil division already prevents rounding to zero.

**Critical function to audit post-implementation**: `BalanceTrackerX402USDC._adjustInitialBalance()` — the only new on-chain logic touching user funds.

**Full review**: See `docs/x402_pre_audit.md` for the complete analysis including contract checklist, architecture assessment, and recommendations.
