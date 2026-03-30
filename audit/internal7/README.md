# Internal Audit 7 — autonolas-marketplace

**Audit Date**: March 30, 2026
**Commit**: 8938b12 (branch: main)
**Repository**: `valory-xyz/autonolas-marketplace`
**Scope**: All contracts in `contracts/` (3,481 LOC, 28 .sol files)
**Methodology**: Internal security audit playbook v2.21 (268 DeFi patterns, 30 rules), Slither static analysis, manual code review

## Auditor

**Claude Opus 4.6** (Anthropic) operating as Claude Code CLI, guided by human security researcher. Methodology built from 22+ external sources and 40+ completed protocol audits.

## Tools Used

| Tool | Version | Results |
|------|---------|---------|
| **Slither** | 0.10.4 | 79 results: 0 High/Medium, all Low/Info (naming, missing inheritance, constants) |
| **Forge** | nightly-2026 | Compilation successful |
| **Manual Review** | Playbook v2.21 | 16 findings (0M/9L/7N) |

## Summary

| Severity | Count |
|----------|-------|
| Critical | 0 |
| High | 0 |
| Medium | 0 |
| Low | 9 |
| Notes | 7 |
| **Total** | **16** |

---

## Low Findings

### L-1: Missing reentrancy guard on OlasMech.deliverMarketplaceWithSignatures

**File**: `OlasMech.sol:285-293`

`deliverMarketplaceWithSignatures()` lacks the `_locked` reentrancy check present on `deliverToMarketplace()`. The marketplace and balance tracker have their own guards, but the mech's state (counters, linked lists) is unprotected during this call path.

**Exploit analysis**: No practical exploit path exists. The only external calls in this flow are `IToken.transferFrom()` on trusted tokens (OLAS, USDC), which do not callback to OlasMech. The marketplace's `_locked` and balance tracker's `_locked` prevent re-entry into those contracts.

**Recommendation**: Add reentrancy guard for defense-in-depth consistency with `deliverToMarketplace()`.

### L-2: EIP-712 signature missing typeHash

**File**: `MechMarketplace.sol:895-905`

`getRequestId()` computes an EIP-712 hash without including a `typeHash` as the first field of the inner `abi.encode`. Per EIP-712 spec: `hashStruct(s) = keccak256(typeHash || encodeData(s))`.

**Exploit analysis**: No practical collision or replay path exists. The hash includes `address(this)` as the first field, and the domain separator includes the contract address and chainId. Cross-contract collision requires identical domain separator (impossible — different addresses) AND identical struct layout.

**Recommendation**: Add proper `typeHash` for EIP-712 standards compliance.

### L-3: Unchecked ERC-20 transfer/transferFrom return values

**Files**: `BalanceTrackerFixedPriceToken.sol:52,74,86,98,112`, `BalanceTrackerFixedPriceNative.sol:45`

All `IToken.transfer()` and `IToken.transferFrom()` calls ignore the boolean return value.

**Production analysis**: All currently deployed tokens are standard ERC-20:
- **OLAS**: standard, returns bool (all 7 chains)
- **USDC**: Circle native deployments, all return bool (ETH, Arb, Base, Celo, Opt, Polygon)
- **Wrapped natives**: WETH/WMATIC/WXDAI/WCELO — standard, return bool

The developer is aware (comment at `BalanceTrackerFixedPriceToken.sol:8`: "Note that if the safe version is needed, make sure to update this contract"). Conscious design choice for gas optimization.

**Recommendation**: If USDT or other non-standard tokens are ever added, use SafeERC20.

### L-4: Nevermined subscription refund in wrong denomination

**Files**: `BalanceTrackerNvmSubscriptionNative.sol`, `BalanceTrackerNvmSubscriptionToken.sol`

When delivery rate is lower than agreed, the refund goes to `mapRequesterBalances[requester]` (native/token), not back as NFT subscription credits. Requester paid with NFT credits but gets refunded in a different denomination.

### L-5: Mech created without balance tracker validation

**File**: `MechMarketplace.sol:555-585`

`create()` does not verify `mapPaymentTypeBalanceTrackers[paymentType] != address(0)`. Mech appears valid but requests to it revert.

### L-6: Mech numUndeliveredRequests counter inconsistency

**File**: `OlasMech.sol:192`

Non-priority mech delivering expired requests may have inconsistent counter. View-only, no security impact.

### L-7: Celo native token drain path

**File**: `BalanceTrackerFixedPriceNativeCelo.sol:18`

`_wrap()` is no-op on Celo, but `_drain()` tries to transfer wrapped token. Needs integration test verification.

### L-8: No refund for expired undelivered requests

**File**: `BalanceTrackerBase.sol:188-221`

Requester funds are debited on request creation. If no mech delivers (even after timeout), there is no mechanism to reclaim the locked funds.

**Recommendation**: Add `reclaimExpiredRequest(bytes32 requestId)` that refunds requester for expired, undelivered requests.

### L-9: Signature v-value accepts 0-3

**File**: `MechMarketplace.sol:438-441`

`_verifySignedHash` accepts `v` values 0-3 and adds 27. Standard ECDSA only uses v={0,1,27,28}. Values v=2,3 produce invalid recovery but are caught by the address check.

---

## Notes (7)

| ID | Title | File |
|----|-------|------|
| N-1 | Storage used as inter-function message passing | BalanceTrackerNvmSubscriptionNative.sol:121 |
| N-2 | Zero-address requesters in arrays passed to finalizeDeliveryRates | MechMarketplace.sol:735,818 |
| N-3 | KarmaProxy fallback not payable | KarmaProxy.sol:57 |
| N-4 | totalDeliveryRate overflow (reverts safely) | BalanceTrackerBase.sol:212 |
| N-5 | Karma int256 theoretical overflow (unreachable) | Karma.sol:130,146 |
| N-6 | trackerBalance not decremented on withdrawal | BalanceTrackerNvmSubscriptionNative.sol:49 |
| N-7 | SubscriptionProvider.fulfill() permissionless | SubscriptionProvider.sol:120 |

---

## Slither Analysis

| Detector Category | Count | Assessment |
|-------------------|:-----:|-----------|
| Naming conventions | 9 | Info — underscore params per Olas convention |
| Missing inheritance | 5 | Info — factories implement interface implicitly |
| State variable could be constant | 1 | Info — numUndeliveredRequests (mutable, not constant) |
| Other (various) | 64 | Info — standard detectors, no actionable findings |

**No High or Medium slither detectors triggered.**

---

## Cross-Reference with Previous Audits (internal1-6)

All Critical and Medium findings from 6 prior internal audits have been addressed:
- **internal2 Critical** (subscription credits bypass): Fixed by design change
- **internal3 Critical** (checkAndRecordDeliveryRate for native): Fixed
- **internal5 Critical** (transient reentrancy lock without reset): Fixed — reverted to uint256 lock pattern
- All Medium findings (payable fallback, typo in check, balance logic, silent function): Fixed

Our L-1 (missing reentrancy guard on deliverMarketplaceWithSignatures) and L-2 (EIP-712 typeHash) are **new findings not identified in previous audits** but have no practical exploit paths with current deployment.

---

## Checklist Compliance

| Area | Items Checked | Findings |
|------|:---:|:---:|
| Fund flow (request→deliver→pay) | 12 | L-3, L-8 |
| Reentrancy | 8 | L-1 |
| Access control | 10 | 0 |
| Signature/EIP-712 | 6 | L-2, L-9 |
| Request/delivery lifecycle | 8 | L-8 |
| Balance tracker accounting | 10 | N-6 |
| Karma reputation | 4 | N-5 |
| Proxy pattern | 4 | N-3 |
| ERC-20 compatibility | 5 | L-3 |
| Cross-contract trust | 6 | N-2, N-7 |
| Items 262-268 | 7 | 0 |

---

## Conclusion

The autonolas-marketplace codebase is well-structured with clear separation of concerns (marketplace, balance trackers, mechs, karma). No Critical, High, or Medium severity issues were found. All Low findings are either best-practice compliance issues with no practical exploit paths (L-1, L-2, L-3, L-9) or edge-case concerns in specific deployment configurations (L-4, L-5, L-7).

The most actionable finding is **L-8 (no expired request refund)** — requester funds are locked indefinitely for undelivered requests with no reclaim mechanism.

Previous 6 internal audits have hardened the codebase significantly. All prior Critical and Medium findings have been addressed.
