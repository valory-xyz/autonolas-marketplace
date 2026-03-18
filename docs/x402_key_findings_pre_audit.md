# x402 Integration — Key Security Findings

**Date**: 2026-03-18
**Branch**: `402` of `valory-xyz/autonolas-marketplace`
**Status**: Pre-implementation review (contracts not yet written)

## Findings Summary

| # | Severity | Finding | Component |
|---|----------|---------|-----------|
| H-1 | High | Settlement race condition — client can drain USDC between tool execution and on-chain settlement | BalanceTrackerX402 |
| H-2 | High | EIP-3009 cross-chain replay risk (theoretical — mitigated by different USDC addresses per chain) | BalanceTrackerX402 |
| M-1 | Medium | `paymentData` ABI decode safety — malformed data can revert entire batch | BalanceTrackerX402 |
| M-2 | Medium | Nonce persistence — in-memory nonce set lost on mech crash, risk of tool re-execution | Off-chain (mech app) |
| M-3 | Medium | **BLOCKER**: Gnosis bridged USDC EIP-3009 support unverified on-chain | Deployment |
| L-1 | Low | Fee rounding to zero when `maxDeliveryRate` is very small | Dynamic pricing |
| L-2 | Low | Circuit breaker scope (per-chain vs global) and reset mechanism undefined | Off-chain (mech app) |
| N-1 | Note | Request signature transport mechanism undecided (Issue C in spec) | Protocol design |
| N-2 | Note | Fork-based integration tests required alongside mock unit tests | Testing |

## H-1: Settlement Race Condition

The x402 flow separates tool execution (immediate, off-chain) from payment settlement (delayed, on-chain batch). Between these two events, the client's EIP-3009 authorization is outstanding but unsecured. The client could transfer their USDC balance elsewhere before the mech settles on-chain.

**Spec's position**: Settlement failure risk is accepted as operational cost, bounded by `maxDeliveryRate` (typically ~$0.05 per request).

**Concern**: The architecture allows arbitrary `maxDeliveryRate`. If a mech charges $100/request, the unsecured window becomes meaningful.

**Recommendations**:
- Document maximum acceptable `maxDeliveryRate` for x402 flow
- Enforce off-chain balance check at verification time (Step 6)
- Circuit breaker (503 after 3 consecutive failures) is a good existing mitigation

## H-2: EIP-3009 Cross-Chain Replay

EIP-3009 `transferWithAuthorization` uses EIP-712 domain separator which includes `chainId`. The spec deploys `BalanceTrackerX402` on multiple chains (Base, Optimism, Polygon, Gnosis). Cross-chain replay is prevented at the USDC contract level because Circle deploys USDC at different addresses per chain.

**Residual risk**: If the same USDC address were to exist on two chains (e.g., via CREATE2), replay would be possible.

**Recommendation**: `BalanceTrackerX402` constructor should validate `block.chainid` matches expected chain and store it as immutable.

## M-1: paymentData ABI Decode Safety

`BalanceTrackerX402._adjustInitialBalance()` will `abi.decode(paymentData, ...)` to extract EIP-3009 parameters. Malformed `paymentData` could cause a revert. Although the spec mandates per-request settlement (isolating failures), the decode must be robust.

**Recommendations**:
- Validate `paymentData.length` before decoding
- Use try/catch around `transferWithAuthorization` call
- Emit failure event with reason for debugging

## M-2: Nonce Management Consistency

EIP-3009 uses random 32-byte nonces. The mech maintains a local nonce set for off-chain dedup, persisted to `synchronized_data`. If the mech crashes between verification and settlement, the nonce set may be lost. USDC's on-chain nonce tracking prevents double-payment, but the mech may re-execute the tool (computational cost, not financial loss).

**Recommendation**: Persist nonces to disk/DB, not just in-memory. The spec's `synchronized_data` approach is correct but must survive restarts.

## M-3: Gnosis Bridged USDC — BLOCKER

Gnosis USDC (`0x2a22f9c3b484c3629090FeED35F17Ff8F88f76F0`) is bridged, not native Circle USDC. Bridged USDC implementations often lack `transferWithAuthorization`. Calling it on a contract that doesn't implement it will revert, freezing all x402 settlements on that chain.

**Recommendation**:
- **MUST** verify on-chain before deployment
- If not supported, exclude Gnosis from v1 targets
- Base and Optimism (native Circle USDC) are confirmed safe targets

## Overall Assessment

The x402 integration design is architecturally sound and security-conscious. The key risk is the settlement window between tool execution and on-chain payment (H-1), which the spec explicitly accepts for small amounts. The biggest blocker is Gnosis USDC EIP-3009 verification (M-3).

**Critical function to audit post-implementation**: `BalanceTrackerX402._adjustInitialBalance()` — the only new on-chain logic touching user funds.

**Full review**: See [README.md](README.md) for complete analysis including contract checklist, architecture assessment, and recommendations.
