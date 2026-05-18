# Contracts vulnerabilities

## Vulnerabilities list

### Involved contracts and level of the bugs

| # | Vulnerability | Contracts | Severity |
|---|---------------|-----------|----------|
| 1 | `deliverMarketplaceWithSignatures` reentrancy guard | OlasMech | Low |
| 2 | `getRequestId` EIP-712 typeHash | MechMarketplace | Low |
| 3 | Unchecked ERC-20 transfer return values | BalanceTrackerFixedPriceToken, BalanceTrackerFixedPriceNative | Low |
| 4 | Nevermined subscription refund denomination | BalanceTrackerNvmSubscriptionNative, BalanceTrackerNvmSubscriptionToken | Low |
| 5 | Mech created without balance tracker validation | MechMarketplace | Low |
| 6 | `numUndeliveredRequests` counter inconsistency | OlasMech | Low |
| 7 | No refund for expired undelivered requests | BalanceTrackerBase | Low |
| 8 | Signature v-value accepts 0-3 | MechMarketplace | Low |
| 9 | Storage used as inter-function message passing | BalanceTrackerNvmSubscriptionNative | Informative |
| 10 | Zero-address requesters in arrays passed to `finalizeDeliveryRates` | MechMarketplace | Informative |
| 11 | KarmaProxy fallback not payable | KarmaProxy | Informative |
| 12 | `totalDeliveryRate` overflow | BalanceTrackerBase | Informative |
| 13 | Karma `int256` theoretical overflow | Karma | Informative |
| 14 | `trackerBalance` not decremented on withdrawal | BalanceTrackerNvmSubscriptionNative | Informative |
| 15 | `SubscriptionProvider.fulfill()` permissionless | SubscriptionProvider | Informative |

The present document aims to point out some vulnerabilities in the autonolas-marketplace
contracts.

## Vulnerabilities

### 1. `deliverMarketplaceWithSignatures` reentrancy guard
**Severity**: Low

The following function is implemented in the OlasMech contract:
```solidity
function deliverMarketplaceWithSignatures(
    address requester,
    DeliverWithSignature[] calldata deliverWithSignatures,
    uint256[] calldata deliveryRates,
    bytes calldata paymentData
) external onlyOperator
```
This function calls into `MechMarketplace.deliverMarketplaceWithSignatures()` without the `_locked`
reentrancy guard that is present on the sibling function `deliverToMarketplace()`.

Upon analysis, the function cannot be re-entered in practice. The only caller is restricted by the
`onlyOperator` modifier to the service multisig. The marketplace sets its own `_locked = 2` before
making any external calls, and the balance tracker independently guards itself with its own `_locked`.
The external calls in the chain are:
- `IKarma.changeRequesterMechKarma()` — pure state write, no callbacks.
- `IKarma.changeMechKarma()` — pure state write, no callbacks.
- `IMech.updateNumRequests()` — calls back to OlasMech but is gated by `MarketplaceOnly`, and the
  marketplace is already locked.
- `IBalanceTracker.adjustMechRequesterBalances()` — has its own reentrancy guard.
- Token transfers — only standard ERC-20 tokens (OLAS, USDC, wrapped natives) with no transfer hooks.

No practical re-entry path exists. We recommend treating this as a documentation point for
defense-in-depth consistency. In a future major version update, the guard may be added for code symmetry.

### 2. `getRequestId` EIP-712 typeHash
**Severity**: Low

The following function is implemented in the MechMarketplace contract:
```solidity
function getRequestId(
    address mech,
    address requester,
    bytes memory data,
    uint256 deliveryRate,
    bytes32 paymentType,
    uint256 nonce
) public view returns (bytes32 requestId)
```
This function computes an EIP-712 hash without including a `typeHash` as the first field of the inner
`abi.encode`. Per EIP-712 specification: `hashStruct(s) = keccak256(typeHash || encodeData(s))`.

Upon analysis, no practical collision or replay path exists. The hash includes `address(this)` as the
first field, and the domain separator includes the contract address and `chainId`. Cross-contract
collision requires an identical domain separator (impossible with different addresses) AND identical
struct layout.

Adding a `typeHash` would change the `requestId` computation, making this a breaking change that
would invalidate any existing undelivered requests. We recommend documenting this deviation from
the EIP-712 standard. In a future marketplace version where contracts are redeployed, the `typeHash`
should be added for full EIP-712 compliance.

### 3. Unchecked ERC-20 transfer return values
**Severity**: Low

The following functions are implemented in the BalanceTrackerFixedPriceToken contract:
```solidity
IToken(token).transfer(drainer, amount);        // _drain
IToken(token).transferFrom(requester, ...);      // _getRequiredFunds
IToken(token).transfer(account, amount);         // _withdraw
IToken(token).transferFrom(msg.sender, ...);     // deposit
IToken(token).transferFrom(msg.sender, ...);     // depositFor
```
And in the BalanceTrackerFixedPriceNative contract:
```solidity
IToken(wrappedNativeToken).transfer(drainer, amount);  // _drain
```
All `IToken.transfer()` and `IToken.transferFrom()` calls ignore the boolean return value.

This is a conscious design choice for gas optimization, as documented in the contract source
(`BalanceTrackerFixedPriceToken.sol` line 8: "Note that if the safe version is needed, make sure to
update this contract"). All currently deployed tokens are standard ERC-20 that correctly return `bool`:
- **OLAS**: standard ERC-20, returns bool (all 7 chains).
- **USDC**: Circle native deployments, all return bool (ETH, Arb, Base, Celo, Opt, Polygon).
- **Wrapped natives**: WETH/WMATIC/WXDAI/WCELO — standard, return bool.

We recommend that if USDT or other non-standard ERC-20 tokens are ever added to the marketplace,
a new balance tracker contract using OpenZeppelin's `SafeERC20` library must be deployed. The
existing in-code comment serves as a sufficient reminder for this constraint.

### 4. Nevermined subscription refund denomination
**Severity**: Low

The following balance adjustment logic is implemented in the BalanceTrackerNvmSubscriptionNative
and BalanceTrackerNvmSubscriptionToken contracts:
```solidity
function _adjustInitialBalance(
    address requester,
    uint256 balance,
    uint256 maxDeliveryRate,
    bytes memory
) internal virtual override returns (uint256)
```
When a delivery rate is lower than the agreed-upon rate, the refund is credited to
`mapRequesterBalances[requester]` in native tokens or ERC-20 tokens, not as NFT subscription
credits. This means a requester who paid with NFT subscription credits receives a refund in a
different denomination.

This is a design limitation of the Nevermined subscription model. NFT credits, once burned during
`_adjustInitialBalance`, cannot be partially "un-burned." Minting back subscription credits on refund
would require the balance tracker to have minter permissions on the subscription NFT contract,
which is a significant architectural change.

We recommend documenting this behavior as a known limitation. Requesters using the subscription
model should be aware that partial refunds are denominated in native tokens or ERC-20 tokens,
not in subscription credits.

### 5. Mech created without balance tracker validation
**Severity**: Low

The following function is implemented in the MechMarketplace contract:
```solidity
function create(uint256 serviceId, address mechFactory, bytes memory payload)
    external returns (address mech)
```
This function does not verify that `mapPaymentTypeBalanceTrackers[paymentType] != address(0)` for
the created mech's payment type. A mech can be created and appear valid, but all requests to it
will revert because no balance tracker is registered for its payment type.

Since the marketplace owner controls which balance trackers are registered via
`setPaymentTypeBalanceTrackers()`, and mech creation is restricted to service owners, this is an
operational concern rather than a security vulnerability. A mech created without a corresponding
balance tracker is non-functional but causes no fund loss.

We recommend that service owners verify the balance tracker is registered for their intended
payment type before calling `create()`. Front-end interfaces should perform this validation
and warn users accordingly.

### 6. `numUndeliveredRequests` counter inconsistency
**Severity**: Low

The following logic is implemented in the OlasMech contract within the `_prepareDeliveries`
function:
```solidity
numUndeliveredRequests -= numSelfRequests;
```
When a non-priority mech delivers requests that have expired past their response timeout, the
`numUndeliveredRequests` counter may become inconsistent because expired requests are removed from
the linked list but the counter adjustment only accounts for self-initiated requests.

This counter is view-only and used for informational purposes. No on-chain logic depends on its
exact value for security-critical decisions. We recommend documenting this edge case as a known
limitation. Off-chain consumers of `numUndeliveredRequests` should treat it as an approximate value.

### 7. No refund for expired undelivered requests
**Severity**: Low

The following function is implemented in the BalanceTrackerBase contract:
```solidity
function checkAndRecordDeliveryRates(
    address requester,
    uint256 numRequests,
    uint256 deliveryRate,
    bytes calldata paymentData
) external virtual payable
```
Requester funds are debited on request creation via this function. If no mech delivers the request
(even after the response timeout expires), there is no mechanism for the requester to reclaim the
locked funds.

The current architecture tracks aggregate requester balances (`mapRequesterBalances[requester]`)
rather than per-request locked amounts, making a simple refund mechanism non-trivial to retrofit.
Implementing `reclaimExpiredRequest(bytes32 requestId)` would require:
- Tracking per-request locked amounts (new storage mapping).
- Determining expiration criteria (marketplace timeout + buffer).
- Preventing double-refund (marking reclaimed requests).
- Deciding access control (requester-only or permissionless).

We recommend that this feature be considered for a future marketplace version where per-request
accounting can be designed from the ground up. In the current version, requesters should be aware
that funds committed to a request are at risk if no mech delivers. Front-end interfaces should
clearly communicate this risk and the response timeout window.

### 8. Signature v-value accepts 0-3
**Severity**: Low

The following logic is implemented in the MechMarketplace contract within `_verifySignedHash`:
```solidity
if (v < 4) {
    v += 27;
}
```
This accepts `v` values `{0, 1, 2, 3}` and maps them to `{27, 28, 29, 30}`. Standard ECDSA
uses `v ∈ {0, 1}` (mapped to `{27, 28}`), but `v ∈ {2, 3}` is a valid (though astronomically
rare, ~3.73e-37 probability) ECDSA output where the recovered point has a y-coordinate
exceeding the curve's half-order.

With `v = 29` or `v = 30`, `ecrecover` recovers a valid but different address (the alternate
curve point). The subsequent address check (`multisigOwner != signer`) rejects the signature,
so no exploit is possible. The only consequence is that a legitimate signer who produces
`v ∈ {2, 3}` would have their valid signature rejected — they would simply sign again.

The current implementation is intentionally correct as documented in the code comments.
No change is needed.

### 9. Storage used as inter-function message passing
**Severity**: Informative

The BalanceTrackerNvmSubscriptionNative contract uses storage variables as a mechanism for
passing data between internal function calls during a single transaction, rather than using
function parameters or return values. While this pattern works correctly, it is unconventional
and may reduce code readability.

This is a design choice with no security impact. No change is recommended.

### 10. Zero-address requesters in arrays passed to `finalizeDeliveryRates`
**Severity**: Informative

In the MechMarketplace contract, when constructing the `requesters` array for
`finalizeDeliveryRates`, array elements for skipped requests (via `continue` statements) remain
as `address(0)`.

The `finalizeDeliveryRates` function in the balance tracker handles zero-address entries gracefully
by skipping them during processing. No security impact exists. No change is recommended.

### 11. KarmaProxy fallback not payable
**Severity**: Informative

The KarmaProxy contract's `fallback()` function is not marked `payable`:
```solidity
fallback() external {
    // delegatecall assembly
}
```
The Karma contract does not require receiving native tokens, so the absence of `payable` is
correct by design. This prevents accidental ETH transfers to the proxy. No change is recommended.

### 12. `totalDeliveryRate` overflow
**Severity**: Informative

In the BalanceTrackerBase contract:
```solidity
uint256 totalDeliveryRate = deliveryRate * numRequests;
```
If both values are very large, this multiplication could overflow. However, Solidity 0.8.x
provides built-in overflow protection and would revert safely. No funds are at risk.
No change is recommended.

### 13. Karma `int256` theoretical overflow
**Severity**: Informative

In the Karma contract:
```solidity
mapMechKarma[mech] += karmaChange;
mapRequesterMechKarma[requester][mech] += karmaChange;
```
The `karmaChange` parameter is `int256`. Theoretically, accumulated karma could overflow or
underflow. In practice, karma values are bounded by the number of deliveries (each contributing
a small delta), making overflow unreachable. Solidity 0.8.x would revert safely in any case.
No change is recommended.

### 14. `trackerBalance` not decremented on withdrawal
**Severity**: Informative

In the BalanceTrackerNvmSubscriptionNative contract, the `trackerBalance` variable is not
decremented when users withdraw funds. This variable is used as a sanity check
(`balance > trackerBalance` overflow check) during payment processing. The omission makes
the check slightly more permissive than intended but does not create a vulnerability, as the
actual contract balance is always the authoritative source.

We recommend documenting this behavior. The `trackerBalance` check serves as a secondary
guard and does not need to be exact for security purposes.

### 15. `SubscriptionProvider.fulfill()` permissionless
**Severity**: Informative

The following function is implemented in the SubscriptionProvider contract:
```solidity
function fulfill(
    bytes32 agreementId,
    bytes32 did,
    FulfillForDelegateParams memory fulfillForDelegateParams,
    FulfillParams memory fulfillParams
) external returns (...)
```
This function can be called by anyone to trigger Nevermined condition fulfillment. However, the
underlying NVM condition contracts (`transferNFTCondition`, `escrowPaymentCondition`) enforce
their own access control and state machine checks internally. A permissionless call that does
not meet the NVM preconditions will simply revert.

No change is recommended. The NVM framework's internal access control is sufficient.
