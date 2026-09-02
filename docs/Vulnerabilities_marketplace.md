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
| 16 | `BalanceTrackerNvmSubscriptionNative.depositFor()` allows direct deposits | BalanceTrackerNvmSubscriptionNative | Medium |
| 17 | Balance trackers remain fundable after all corresponding mech factories are disabled | BalanceTrackerBase, BalanceTrackerFixedPriceToken, BalanceTrackerFixedPriceNative | Informative |
| 18 | Celo native tracker fee-drain depends on the wrapped-native token configuration | BalanceTrackerFixedPriceNativeCelo | Low |
| 19 | Balance-tracker re-map strands residual requester balances | MechMarketplace, BalanceTrackerBase | Low |
| 20 | EIP-712 domain separator hashes `VERSION` via `abi.encode` | MechMarketplace | Informative |
| 21 | Mech payout keying vs. service multisig authorization | BalanceTrackerBase, OlasMech | Informative |
| 22 | Payment-type balance-tracker remap misroutes in-flight request settlement | MechMarketplace | Low |
| 23 | Fixed-price delivery is finalized and paid without a delivery payload | MechMarketplace, OlasMech, MechFixedPriceBase | Low |
| 24 | Subscription fulfilment is permissionless and forwards caller-supplied parameters | SubscriptionProvider, BalanceTrackerNvmSubscriptionNative | Low |
| 25 | Nevermined fallback delivery can settle above the mech's advertised maximum rate | MechMarketplace, OlasMech, MechNvmSubscriptionNative, BalanceTrackerBase | Low |
| 26 | Settlement is not atomic with delivery, and a requester's nonce serialises their concurrent requests | MechMarketplace, OlasMech | Low |
| 27 | No mechanism exists to reserve a requester's balance before settlement | BalanceTrackerBase, MechMarketplace | Low |
| 28 | Requester balances are spend-only by design; no withdraw is provided | BalanceTrackerBase, BalanceTrackerFixedPriceNative, BalanceTrackerFixedPriceToken | Informative |

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

**One clarification on "view-only".** The counter and the linked list behind it are the mech's
**work-discovery surface** — an agent calls `getUndeliveredRequestIds` to find what it should work
on. Two consequences follow that a purely informational reading misses:

- The stale entries are not merely a wrong number. A mech's agent is served request ids that are
  already settled and can never be paid for, so an unmonitored mech does useless work.
- The list is **third-party writable in effect**. Anyone may post requests naming a mech as priority
  mech, and any other mech may then deliver them once the response window expires; neither action
  touches the priority mech's own storage. So an unrelated party can inflate the affected mech's
  queue at will.

Clearing it is possible — the mech re-delivers the stale ids — and is roughly an order of magnitude
cheaper per entry than creating one, so the gas asymmetry favours the affected mech. But
`getUndeliveredRequestIds` traverses the list linearly, so a large enough backlog makes the view
expensive well before it becomes unusable.

The recommendation above is unchanged; one addition to it — a mech's work loop should not assume that
every id the list returns is still deliverable.

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

### 16. `BalanceTrackerNvmSubscriptionNative.depositFor()` allows direct deposits
**Severity**: Medium (raised from Low — see "Realisable impact" below)

`BalanceTrackerNvmSubscriptionNative` inherits from `BalanceTrackerFixedPriceNative`, which exposes
a payable `depositFor(address account)` that credits the account's balance:
```solidity
function depositFor(address account) external payable virtual {
    mapRequesterBalances[account] += msg.value;
    emit Deposit(account, address(0), msg.value);
}
```
Because the subscription variant did not override this function, anyone could send native funds
through `depositFor()` and inflate `mapRequesterBalances`, bypassing the NFT subscription model
(which is the only intended path for crediting balances on this contract). The companion
`_getOrRestrictNativeValue()` already rejects `msg.value > 0` on a request, so the only remaining
direct-funding path was `depositFor()`.

The fix overrides `depositFor()` to unconditionally revert:
```solidity
function depositFor(address) external payable virtual override {
    revert NoDepositAllowed(msg.value);
}
```
This aligns `BalanceTrackerNvmSubscriptionNative` with `BalanceTrackerNvmSubscriptionToken`, which
already reverts both `deposit()` and `depositFor()` on its token variant.

**Realisable impact.** The severity of this entry was originally recorded as Low, describing the
defect as bypassing the NFT subscription model. That understates it, because the wei written into
`mapRequesterBalances` are not spent at face value. They are consumed as subscription **credits**, and
`_processPayment` converts a mech's credit balance into native tokens before paying out:

```solidity
// Convert mech credits balance into tokens
balance = (balance * tokenCreditRatio) / 1e18;
mapMechBalances[mech] = balance;

// Check current contract balance
if (balance > trackerBalance) {
    revert Overflow(balance, trackerBalance);
}
```

`tokenCreditRatio` is the configured token-per-credit rate, so a deposit made through the unguarded
`depositFor()` is scaled by `tokenCreditRatio / 1e18` on the way out. On the live Gnosis instance that
ratio reads `9.9e29`, i.e. a factor of ~10^12, so a dust deposit converts into a payout of arbitrary
size within whatever bound applies.

**What actually bounds the payout.** The `Overflow` check compares against the `trackerBalance` *state
variable*, not against the contract's native balance — and those diverge, because item 14 of this
document records that `trackerBalance` is not decremented on withdrawal, so it drifts upward relative
to funds actually held. On the live Gnosis instance the two read:

| | value |
|---|---|
| `trackerBalance` | `50490000000000000000` (50.49 xDAI) |
| actual native balance | `148619998044` wei (~1.5e-7 xDAI) |

The guard therefore permits a computed payout well above the funds present; what prevents an actual
overdraw is the native transfer failing for insufficient balance, which is a revert rather than a
designed cap. Items 14 and 16 interact in this direction: the item-14 drift weakens the mitigation
item 16 relies on.

**Realisable exposure today.** The recoverable amount is bounded by the native balance actually held,
which is ~1.49e11 wei (~1.5e-7 xDAI) on Gnosis. On Base, `tokenCreditRatio` reads `0`, so the
conversion yields zero and the amplification cannot fire at all until a subscription is configured —
that instance is inert with respect to this defect, not merely dormant.

The severity is recorded as Medium for the **shape** of the risk — exposure scales with tracker
liquidity rather than with the attacker's outlay, and grows as subscription usage grows — not because
a Medium-value loss is presently available. It raises the priority of the redeployment below rather
than changing the fix, which is already correct.

**Deployment status:** the contract source has been updated, but the on-chain instances on
Gnosis (`0x7D686bD1fD3CFF6E45a40165154D61043af7D67c`) and Base
(`0x3d79737f05966c5925a04d1b04110006F5a072bE`) still run the pre-fix bytecode — re-confirmed by an
`eth_call` to `depositFor()` carrying value against both, which returns successfully where the fixed
source reverts `NoDepositAllowed`. (Checking the deployed bytecode for the `NoDepositAllowed` selector
does **not** distinguish the two versions: `_getOrRestrictNativeValue()` uses the same error and is
present pre-fix. The value-bearing call is the reliable test.) They need to be redeployed before this
vulnerability is closed on-chain.

**Redeployment note.** These trackers are deployed directly, not behind a proxy, so closing this means
deploying a new instance and re-pointing the payment type with
`MechMarketplace.setPaymentTypeBalanceTrackers`. That re-pointing is exactly the operation described in
item 19: any request already in flight for the affected payment type was debited on the old tracker and
would settle against the new one. In-flight requests should be settled or drained before the swap.

### 17. Balance trackers remain fundable after all corresponding mech factories are disabled
**Severity**: Informative

The marketplace owner can retire a payment branch by de-whitelisting its mech factories via
`setMechFactoryStatuses(mechFactories, statuses)` with `false` statuses. After that, no new mech
of that branch can be created, and if no such mech was ever created, no request can route to the
branch's balance tracker: `MechMarketplace.request()` requires a marketplace-registered priority
mech, and only the mech's payment type selects the balance tracker.

However, balance trackers are immutable, permissionless contracts. Nothing marketplace-side can
stop someone from calling `deposit()` / `depositFor()` on a retired branch's tracker, or from
raw-transferring the underlying token to the tracker address:
```solidity
function deposit(uint256 amount) external virtual {
    // Update account balances
    mapRequesterBalances[msg.sender] += amount;

    // Get tokens
    IToken(token).transferFrom(msg.sender, address(this), amount);

    emit Deposit(msg.sender, token, amount);
}
```
Such funds can never be processed as payment — with no mech there is no request path, so
`checkAndRecordDeliveryRates()`, `finalizeDeliveryRates()` and `processPayment()` are unreachable
for that branch. They can also never be reclaimed: balance trackers expose no requester-facing
withdraw function — the internal `_withdraw()` is only called to pay mechs during
`_processPayment()` — so a deposit to a retired branch's tracker is permanently stuck. This is a
corollary of vulnerability #7 for retired branches, and it is self-inflicted: it requires a
voluntary deposit to a branch that can never serve a request. The consequence is that "the
tracker balance is zero" is not something any governance action can guarantee forever. What can
be guaranteed is that the token can never flow through the payment lifecycle.

Note that this immutability is a deliberate trustlessness property, not a defect: no owner,
governance action, or upgrade can seize, freeze, or redirect requester deposits held by a
balance tracker, and `drain()` can only ever move `collectedFees` (which stay at zero when no
payments are processed). Non-seizability is distinct from retrievability, however — the
depositor cannot retrieve the funds either (see vulnerability #7). No change is recommended.
Off-chain monitoring should interpret a non-zero balance on a retired tracker as stuck funds,
not as payment activity.

### 18. Celo native tracker fee-drain depends on the wrapped-native token configuration
**Severity**: Low

`BalanceTrackerFixedPriceNativeCelo` overrides `_wrap(uint256)` to a no-op (on Celo the native
asset is itself an ERC-20, so no wrapping is required), while the inherited `_drain` transfers
the ERC-20 `wrappedNativeToken`:
```solidity
function _drain(uint256 amount) internal virtual override {
    // Wrap native tokens
    _wrap(amount);                                   // no-op on Celo
    // Transfer to drainer
    IToken(wrappedNativeToken).transfer(drainer, amount);
    ...
}
```
Requester deposits and mech payouts move native value, but the fee-drain path moves the ERC-20
token. This is only correct when `wrappedNativeToken` is configured to the Celo native-as-ERC-20
token, so that the contract's native balance is transferable through the ERC-20 interface. With
a distinct wrapped token configured, `drain()` would revert on insufficient balance and collected
fees would be undrainable (liveness only; requester and mech native paths are unaffected, no
theft possible).

The current deployment is verified correct: the on-chain `wrappedNativeToken` of the Celo tracker
(`0x2E008211f34b25A7d7c102403c6C2C3B665a1abe`) is `0x471EcE3750Da237f93B8E339c536989b8978a438`,
the CELO native-as-ERC-20 token.

We recommend re-verifying this configuration at any future Celo redeploy, or adding a
Celo-specific `_drain` that transfers native value directly.

### 19. Balance-tracker re-map strands residual requester balances
**Severity**: Low

`MechMarketplace.setPaymentTypeBalanceTrackers` re-points a payment type to a new balance
tracker without migrating state accrued in the previously-registered tracker. After a re-map,
new requests route to the new tracker.

The stranding is narrower than it first appears: `processPayment()`, `processPaymentByMultisig()`
and `drain()` live on the tracker itself and read the fee through the tracker's immutable
`mechMarketplace` reference, so accrued mech balances and `collectedFees` remain fully claimable
from the superseded tracker after the re-map. What is genuinely stranded is
`mapRequesterBalances`: requester balances are spend-only (see vulnerability #7), and after the
re-map no new request can route to the old tracker to spend them (see also vulnerability #17 for
the retired-branch variant).

The setter is owner-only and the marketplace owner is a governance contract, so this is an
operational concern rather than an attack vector. We recommend treating a tracker re-map as a
migration event: announce it in advance so requesters spend down their balances and mechs claim
their accrued payments, and drain collected fees before or as part of the re-map.

### 20. EIP-712 domain separator hashes `VERSION` via `abi.encode`
**Severity**: Informative

In the MechMarketplace contract, `_computeDomainSeparator` hashes the version field as
`keccak256(abi.encode(VERSION))` instead of the standard `keccak256(bytes(VERSION))`:
```solidity
DOMAIN_SEPARATOR_TYPE_HASH,
keccak256("MechMarketplace"),
keccak256(abi.encode(VERSION)),   // standard is keccak256(bytes(VERSION))
block.chainid,
address(this)
```
This deviates from EIP-712 and is inconsistent with the name field on the same lines. It is not
exploitable: signing and verification both go through `getRequestId`, so signer and verifier
compute the same value. The only consequence is that an external party using a standard EIP-712
library would derive a different domain separator. This is a sibling of the deviation documented
in vulnerability #2.

We recommend hashing the version as `keccak256(bytes(VERSION))` at the next marketplace redeploy,
together with the #2 typeHash fix.

### 21. Mech payout keying vs. service multisig authorization
**Severity**: Informative

Mech revenue accrues keyed by the stable mech address (`mapMechBalances[mech]` in
BalanceTrackerBase), while `processPaymentByMultisig` authorizes withdrawal through
`IMech(mech).isOperator(msg.sender)` → `OlasMech.getOperator()` → the service's current
`multisig` in the Service Registry, which is mutable across service redeployments. The multisig
authorized to withdraw at claim time is therefore not intrinsically the multisig that earned the
balance.

This is not exploitable by a third party: re-pointing `service.multisig` requires reaching
`PreRegistration`, which requires `unbond`, and `unbond` is gated to the genuine bonding operator
(`ServiceManager.unbond` forwards `msg.sender` as the operator; `ServiceRegistry.unbond` reverts
`OperatorHasNoInstances` for anyone else). A party that never bonded cannot unbond, cannot
redeploy, and never satisfies the `isOperator` check.

The residual concerns services where the owner and the operator are distinct parties. Once the
owner terminates the service, `getOperator()` reverts (service state is no longer `Deployed`),
so the operator can no longer withdraw accrued revenue. Recovering its bond requires `unbond`,
which re-opens redeployment — after which the owner's newly deployed multisig passes
`isOperator` and can claim the revenue accrued under the previous operator. The operator's
choice is to forfeit either its bond or the accrued revenue; this is an owner-vs-operator trust
assumption rather than a pure liveness property. In current deployments the service owner and
operator are the same party, so no change is recommended. Operators of services they do not own
should withdraw accrued balances promptly while the service is in `Deployed` state. A future
version could snapshot the payout recipient at accrual time or settle mech balances on service
state exit.


### 22. Payment-type balance-tracker remap misroutes in-flight request settlement

**Severity**: Low

`MechMarketplace` resolves the balance tracker for a request twice from live state, and the request
carries only the payment type in between. At request time the tracker is resolved and the requester
debited:

```solidity
// MechMarketplace.request*(...)
address balanceTracker = mapPaymentTypeBalanceTrackers[paymentType];
IBalanceTracker(balanceTracker).checkAndRecordDeliveryRates{value: msg.value}(msg.sender, numRequests,
    deliveryRate, paymentData);
```

`RequestInfo` stores `paymentType` but no tracker address, and at delivery time the tracker is
re-resolved from the same map:

```solidity
// MechMarketplace.deliverMarketplace*(...)
address balanceTracker = mapPaymentTypeBalanceTrackers[paymentType];
IBalanceTracker(balanceTracker).finalizeDeliveryRates(msg.sender, requesters, deliveredRequests,
    deliveryRates, requesterDeliveryRates);
```

If the owner re-points a payment type to a different balance tracker via
`setPaymentTypeBalanceTrackers(paymentTypes, balanceTrackers)` while requests are in flight, those
requests were debited on the old tracker but settle against the new one. `finalizeDeliveryRates` then
credits the delivering mech out of the new tracker's liquidity without a matching debit there, while the
reservation on the old tracker is left stranded.

**Reachability.** `setPaymentTypeBalanceTrackers` is owner-only, so this is not third-party exploitable;
it is a consequence of an administrative migration performed while requests are outstanding. It is
adjacent to item 19 (which concerns residual requester *balances* stranded by a remap) but distinct: here
a request *settles against the wrong custody bucket*.

**Mitigation / guidance for operators.** Settle or drain all in-flight requests for a payment type before
re-pointing its balance tracker. Note that replacing a directly-deployed balance tracker (for example the
redeployment tracked under item 16) is itself such a remap, because closing it requires pointing the
payment type at a new tracker address — the same sequencing precaution applies. A future version could
snapshot the resolved balance tracker into `RequestInfo` at request time and settle against that snapshot,
so a remap only affects requests created after it.

- Contract: `MechMarketplace` (`request`, `deliverMarketplace`, `deliverMarketplaceWithSignatures`, `setPaymentTypeBalanceTrackers`) — the tracker is re-resolved on **both** delivery paths, so a snapshot fix must cover both

### 23. Fixed-price delivery is finalized and paid without a delivery payload

**Severity**: Low
**Source**: internal review

An authorized service operator can finalize a funded fixed-price request with an empty `deliveryData`. The
request is marked `Delivered`, the full fixed rate is credited to the mech, and the operator can withdraw
it.

`deliveryData` is carried through `_prepareDeliveries` and `_preDeliver` and is then only ever emitted:

```solidity
emit Deliver(address(this), msg.sender, requestIds[i], deliveryRates[i], deliveryDatas[i]);
```

Settlement runs on `deliveryRates`. Nothing on the delivery path inspects the payload's length or content,
so a zero-length delivery settles exactly as a full one does. `deliverToMarketplace()` and
`deliverMarketplaceWithSignatures()` share this property.

The contract cannot judge whether a delivery is *correct* — the payload is opaque by design and the
requester chooses the mech and the rate, so quality is a trust relationship rather than something the
marketplace can enforce. What is recorded here is narrower: the contract does not enforce even the cheapest
available invariant, that something was delivered at all.

**Mitigation.** Reject a zero-length `deliveryData` on every production delivery path. That is a small
change and removes the provably-empty case without implying any guarantee about content. A verifiable
output commitment would be needed for a real authorization guarantee, and is a protocol design decision well
beyond this entry. Requesters should continue to select mechs on reputation, since on-chain settlement
attests to delivery having occurred, not to its usefulness.

### 24. Subscription fulfilment is permissionless and forwards caller-supplied parameters

**Severity**: Low
**Source**: internal review

`SubscriptionProvider.fulfill()` is `external` with no access control, while every other state-changing
function in the same contract — `addDIDProvider`, `removeDIDProvider`, `changeOwner` — is owner-gated:

```solidity
if (msg.sender != owner) { revert OwnerOnly(msg.sender, owner); }
```

`fulfill()` forwards its caller's parameters unvalidated into the external subscription conditions,
including the expiration the fulfilment is minted with. Because those conditions do not commit to every
forwarded parameter in the identifier they check, a caller other than the intended one can drive the
fulfilment with values of their choosing — for a finite subscription, minting it non-expiring — while the
balance trackers continue to accept the resulting balance as entitlement.

The conditions themselves are external dependencies and outside this repository. What is in scope is the
wrapper: an ungated entry point that forwards unvalidated parameters into them. Either validating the
forwarded parameters or gating `fulfill()` to the owner, consistently with the rest of the contract, closes
the reachability from this side.

### 25. Nevermined fallback delivery can settle above the mech's advertised maximum rate

**Severity**: Low
**Source**: internal review

A mech publishes a `maxDeliveryRate` that consumers read to bound what it will charge. On the registered
Nevermined fallback delivery path, that figure is not what is enforced: after a request times out, delivery
accepts the rate decoded from the operator's data and validates it only against the **requester's** reserved
cap, not against the mech's own advertised maximum.

The two can therefore diverge — a settlement above the published `maxDeliveryRate`, on a mech that still
advertises the lower figure.

**No request is overcharged.** The requester's reserved cap still binds, so nothing settles beyond what that
requester had already committed, and no third party's funds are involved. The consequence is narrower and
purely informational: `maxDeliveryRate` cannot be relied on off-chain as an upper bound on what a mech will
charge, which is precisely what a published parameter of that name invites a reader to assume.

Bounding the settled rate by the mech's own `maxDeliveryRate`, in addition to the requester cap, would make
the advertised figure enforced rather than merely published.

### 26. Settlement is not atomic with delivery, and a requester's nonce serialises their concurrent requests

**Severity**: Low
**Source**: internal review

This entry records two constraints the contracts impose on anyone integrating a mech. Neither is a defect in
the contracts; both are properties an integrator has to design around, and neither is stated elsewhere.

**Settlement can fail after the work is done, and the contracts cannot know the work was done.** A mech
performs a request off-chain and settles it on-chain afterwards. The contracts have no visibility of the
off-chain step, so there is nothing they can bind it to — a settlement that reverts leaves no on-chain trace
that anything was delivered. Settlement can revert for ordinary reasons: a stale signature, an insufficient
balance at settlement time, or the nonce condition below.

**A requester's nonce is consumed per settlement, not per request.** The signature path validates each
request against the requester's current nonce and advances it when the batch settles. Two batches prepared
against the same nonce value — which is what happens when a requester issues requests to two mechs before
either has settled — cannot both settle. The first advances the nonce; the second is then signed against a
value that no longer matches and reverts.

**Consequence for an integrator.** A mech that releases its result before settlement is confirmed is
extending unsecured credit: if settlement then fails, the result has been delivered and there is no on-chain
means to recover payment for it. The safe pattern is to treat confirmed settlement, not accepted request, as
the point at which a result may be released. A requester issuing concurrent requests should expect all but
one to fail settlement unless they sequence them.

No contract change addresses this — the constraint follows from the boundary between off-chain execution and
on-chain settlement, and from the nonce being the replay protection. It is recorded so integrators do not
have to discover it from a failed settlement.

### 27. No mechanism exists to reserve a requester's balance before settlement

**Severity**: Low
**Source**: internal review

The balance trackers debit a requester at settlement. **There is no call that reserves, locks or escrows a
requester's balance ahead of it** — a mech deciding whether to accept a request can read the balance, but
cannot hold any part of it.

Two consequences follow, and both fall on mechs rather than on requesters:

- **A balance sufficient for one request satisfies any number of pre-settlement checks.** Each check observes
  the same unreserved figure, so several mechs can each conclude a requester is good for the work. Whichever
  settles first consumes the balance; the rest revert at settlement, after the work is done.
- **A requester is in practice serialised to one in-flight request per funded amount**, since nothing holds
  their funds against the others.

The trackers' accounting is correct throughout: settlement debits what is available at settlement. What is
absent is a reservation primitive, and its absence is not visible from the tracker interface.

**Consequence for an integrator.** Reading a balance is not a guarantee that it will still be there at
settlement, so check-then-work is not a safe pattern. A mech should account for its own outstanding accepted
requests against a requester before accepting another, or accept that concurrent acceptances may settle
only once.

Adding a reservation primitive would be a design change rather than a fix, with its own questions — expiry,
release on failure, and interaction with in-flight requests. This entry records the current guarantee so it
is not assumed to be stronger than it is.

### 28. Requester balances are spend-only by design; no withdraw is provided

**Severity**: Informative
**Source**: internal review

A requester funds a balance tracker ahead of use, and that balance is debited as requests settle. **There is
no withdraw function, and none is planned.** A deposited balance can be spent on requests to mechs using
that payment type; it cannot be returned to the depositor.

This is a deliberate design decision, recorded here because the interface does not show it: a depositor
reading the tracker sees a balance credited to their address and may reasonably assume it can be reclaimed.
It cannot.

**What follows for an integrator.** Treat a deposit as a purchase of request capacity rather than as an
escrow. Fund incrementally against expected usage rather than in large amounts up front, since anything
deposited beyond what is eventually spent stays in the tracker indefinitely. A balance is keyed to the
depositing address, so whoever controls that address controls the spending — for a service multisig, that is
whoever the multisig's owners are at the time.

No change is recommended.
