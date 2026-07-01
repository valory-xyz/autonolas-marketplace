# Internal audit 8 — full re-audit of autonolas-marketplace

| | |
|---|---|
| **Scope** | All production contracts under `contracts/` (30 files, ~3.5k LOC): `MechMarketplace`, `BalanceTrackerBase` and the native / token / USDC / Celo / Nevermined-subscription trackers, `OlasMech` and the fixed-price / subscription mechs, `MechFactoryBase` and factory variants, `Karma`, `SubscriptionProvider`, the UUPS proxies (`MechMarketplaceProxy`, `KarmaProxy`) and interfaces. |
| **Commit** | `main` @ `c33a67c` |
| **Type** | Full re-audit (by-hand read of every contract), reconciled against `docs/Vulnerabilities_marketplace.md` and prior internal audits `internal`…`internal7` + Cantina 2025-02. |
| **Verdict** | **PASS — 0 Critical / 0 High / 0 Medium.** No new vulnerability was found that is not already recorded in `Vulnerabilities_marketplace.md`. Findings below are Low / Informational, and one is a deployment-status item. |

The `402`-branch material merged at `c33a67c` is **documentation only** (x402 specs, API/ETL specs); no x402 contracts are present on `main`, so no x402 on-chain code is in scope for this audit.

---

## Summary of findings

| # | Title | Severity | Status |
|---|---|---|---|
| L-1 | Celo native tracker: fee-drain path depends on `wrappedNativeToken` being the native-as-ERC20 representation | Low | Config correctness |
| L-2 | `setPaymentTypeBalanceTrackers` re-map does not migrate outstanding balances in the old tracker | Low | Owner-triggered; hardening |
| D-1 | `BalanceTrackerNvmSubscriptionNative.depositFor` fix present in source but not yet deployed | Low | **Deployment** (already tracked as `Vulnerabilities_marketplace.md` #16) |
| I-1 | Mech-payout keying vs. service-multisig authorization asymmetry — analysed, **not exploitable** | Informational | Benign observation + optional hardening |
| I-2 | No requester-side withdrawal of residual `mapRequesterBalances` | Informational | Confirms documented #4 / #7; optional feature |
| I-3 | EIP-712 domain separator hashes `VERSION` via `abi.encode` rather than `bytes()` | Informational | Standards nit (sibling of documented #2) |
| I-4 | Marketplace fee applied at withdrawal time to the whole accrued mech balance | Informational | By design; documentation |
| I-5 | Minor: dead array allocation in `request`; `MIN_MECH_BALANCE` dust; `trackerBalance` not decremented (Nevermined-native) | Informational | Cosmetic (last item = documented #14) |

---

## Findings

### L-1 — Celo native tracker fee-drain depends on the wrapped-native configuration

**Contract:** `mechs/native/celo/BalanceTrackerFixedPriceNativeCelo.sol`

`BalanceTrackerFixedPriceNativeCelo` overrides `_wrap(uint256)` to a **no-op** (on Celo the native asset is itself an ERC-20, so no wrapping is required). The inherited `_drain` first calls `_wrap(amount)` and then transfers `amount` of `wrappedNativeToken` to the drainer:

```solidity
function _drain(uint256 amount) internal virtual override {
    _wrap(amount);                                   // no-op on Celo
    IToken(wrappedNativeToken).transfer(drainer, amount);
}
```

Requester deposits and mech payouts arrive/leave as **native** value (`receive()`, `depositFor`, `_withdraw` via `call{value:}`). The fee `drain()` path, however, moves the ERC-20 `wrappedNativeToken`. This is only correct if `wrappedNativeToken` is configured to the **Celo native-as-ERC-20 token** (so that the contract's native balance is transferable through the ERC-20 interface). If a distinct wrapped token is configured, `drain()` reverts on insufficient wrapped balance and collected fees cannot be withdrawn.

- **Impact:** collected marketplace fees could be undrainable (liveness only; requester/mech native paths are unaffected). No theft.
- **Verdict:** deployment-configuration correctness.
- **Recommendation:** confirm at deployment that `wrappedNativeToken` on Celo is the native-as-ERC-20 token, or add a Celo-specific `_drain` that transfers native directly.

### L-2 — Balance-tracker re-map does not migrate outstanding balances

**Contract:** `MechMarketplace.sol` (`setPaymentTypeBalanceTrackers`)

`setPaymentTypeBalanceTrackers` re-points `mapPaymentTypeBalanceTrackers[paymentType]` to a new balance-tracker address. It does not migrate the `mapRequesterBalances` / `mapMechBalances` / `collectedFees` already accrued in the previously-registered tracker. After a re-map, new requests/deliveries route to the new tracker while funds and accrued balances remain in the old one, unreachable through the new routing.

- **Impact:** owner/governance-triggered stranding of balances held in the superseded tracker. Requires an owner action; the marketplace owner is a governance contract (see grounding), so this is not an arbitrary-attacker vector.
- **Verdict:** hardening / operational procedure.
- **Recommendation:** treat tracker replacement as a migration event — drain/settle the old tracker (existing `drain` / `processPayment*` paths) before or as part of the re-map, and document the operator procedure.

### D-1 — Nevermined-native `depositFor` fix is in source but not yet deployed

**Contract:** `mechs/nevermined/BalanceTrackerNvmSubscriptionNative.sol`

Source correctly overrides `depositFor` to reject direct funding (aligning the native subscription tracker with the token variant):

```solidity
function depositFor(address) external payable virtual override {
    revert NoDepositAllowed(msg.value);
}
```

This is already tracked as **`Vulnerabilities_marketplace.md` item #16**, which notes the on-chain instances still run the pre-fix bytecode. This audit re-checked the deployed state read-only: the Base instance `0x3d79737f05966c5925a04d1b04110006F5a072bE` still accepts `depositFor` (a read-only `eth_call` of `depositFor` returns success rather than reverting), i.e. it runs the pre-fix bytecode. The Gnosis instance named in #16 is likewise pending per that entry.

- **Impact:** on the un-redeployed instances, anyone can inflate `mapRequesterBalances` on the native subscription tracker via `depositFor`, bypassing the subscription (NFT-credit) model. Bounded to the affected trackers; no impact to fixed-price trackers.
- **Verdict:** deployment (redeploy pending).
- **Recommendation:** redeploy the native subscription tracker(s) with the fixed bytecode and close #16 once on-chain.

### I-1 — Mech-payout keying vs. service-multisig authorization (analysed; not exploitable)

**Contracts:** `BalanceTrackerBase.sol` (`mapMechBalances`, `processPaymentByMultisig`), `OlasMech.sol` (`getOperator`, `isOperator`)

Mech revenue is accrued keyed by the **stable mech address** (`mapMechBalances[mech]`), while `processPaymentByMultisig` authorizes withdrawal through `IMech(mech).isOperator(msg.sender)` → `OlasMech.getOperator()` → `ServiceRegistry.mapServices(serviceId).multisig`, which is **mutable** (overwritten by `ServiceRegistry.deploy`). This is a real keying asymmetry: the multisig authorised to withdraw at withdrawal time is not intrinsically the multisig that earned the balance.

We analysed the cross-party "a redeployed service multisig claims a predecessor's accrued balance" chain end-to-end and conclude it is **not exploitable for theft**, because re-pointing `service.multisig` requires reaching `PreRegistration`, which requires `unbond`, and `unbond` is gated to the genuine bonding operator (`ServiceRegistry`/`ServiceManager`: `unbond` forwards the caller as the operator and reverts `OperatorHasNoInstances` for any non-operator; `unbondWithSignature` additionally requires the operator's own signed message). A party that is not the operator cannot unbond, cannot redeploy, and therefore never satisfies the `isOperator` check. The only residual is a **symmetric deadlock**: if a service owner terminates while the operator has un-withdrawn balance and the operator (rationally) never unbonds, the balance is inaccessible to both — a liveness/griefing property requiring the operator's own non-cooperation, with no attacker gain.

- **Verdict:** benign observation (no exploitable theft; the residual is a symmetric liveness property, not a security defect).
- **Recommendation (optional defence-in-depth):** if desired, bind accrued balance to the operator at accrual time (snapshot the recipient per credit) or settle/clear the mech balance on service exit from `Deployed`, so the earning operator can always reclaim what it earned. Not required for security.

### I-2 — No requester-side withdrawal of residual balances

**Contract:** `BalanceTrackerBase.sol`

There is no requester-facing withdrawal function anywhere in the tracker hierarchy. `mapRequesterBalances` — credited by `deposit`/`depositFor` pre-funding and by below-rate delivery refunds (`_adjustFinalBalance`) — is spend-only: it can be consumed by a subsequent request but never moved back out to the requester. A requester that over-deposits or stops transacting leaves residual value stranded.

This confirms and slightly generalises the already-documented `Vulnerabilities_marketplace.md` items **#4** (Nevermined refund denomination) and **#7** (no refund for expired undelivered requests). The stranded value is the requester's own voluntarily-committed funds and is avoidable by not pre-depositing beyond intended spend; there is no attacker and no third-party victim.

- **Verdict:** documented limitation (Informational).
- **Recommendation (optional):** add a reentrancy-guarded requester withdrawal for residual `mapRequesterBalances`, following the existing withdrawal pattern.

### I-3 — EIP-712 domain separator hashes `VERSION` via `abi.encode`

**Contract:** `MechMarketplace.sol` (`_computeDomainSeparator`)

```solidity
DOMAIN_SEPARATOR_TYPE_HASH,
keccak256("MechMarketplace"),
keccak256(abi.encode(VERSION)),   // standard is keccak256(bytes(VERSION))
block.chainid,
address(this)
```

The version field is hashed as `keccak256(abi.encode(VERSION))` instead of `keccak256(bytes(VERSION))`, which deviates from EIP-712 and is inconsistent with the name field on the same line. It is **not exploitable**: signing goes through `getRequestId`, so signer and verifier compute the same value; the only consequence is that an external party using a standard EIP-712 library would derive a different domain separator. This is a sibling of the already-documented deviation `Vulnerabilities_marketplace.md` **#2** (`getRequestId` typeHash).

- **Verdict:** standards nit (Informational).
- **Recommendation:** at the next redeploy, hash the version as `keccak256(bytes(VERSION))` for full EIP-712 conformance.

### I-4 — Fee applied at withdrawal time to the whole accrued balance

**Contract:** `BalanceTrackerBase.sol` (`_processPayment`)

The marketplace fee is computed with the **current** `mechMarketplace.fee()` applied to the entire accumulated `mapMechBalances[mech]` at withdrawal, not per-delivery at accrual. A governance fee change therefore applies to already-earned, not-yet-withdrawn revenue. This is a deliberate, governance-controlled behaviour.

- **Verdict:** by design.
- **Recommendation:** document that mechs should withdraw promptly; no code change required.

### I-5 — Minor / cosmetic

- `MechMarketplace.request` allocates `new bytes32[](1)` and immediately overwrites it with the `_requestBatch` return — a dead allocation.
- `MIN_MECH_BALANCE = 2` leaves a 1-wei mech balance permanently un-withdrawable (documented intent: guarantee the mech receives ≥1 after the ≥1 fee).
- Nevermined-native `trackerBalance` is not decremented on withdrawal (already `Vulnerabilities_marketplace.md` **#14**); the check is a secondary guard and the real contract balance is authoritative.

- **Verdict:** cosmetic / documented.

---

## Reviewed and found sound (no issue)

The following were examined specifically and are correct:

- **Proxy initialization** — both `MechMarketplaceProxy` and `KarmaProxy` `delegatecall` their initializer inside the constructor, so `owner` is set atomically in the deployment transaction; there is no uninitialized-proxy front-running window.
- **Mech creation** — all factories create mechs with `new X{salt}` (CREATE2) using a per-call unique salt (`keccak256(timestamp, payload, serviceId, nonce++)`); there is no address-reuse / "adopt an arbitrary existing contract" primitive.
- **Payment accounting** — requester/mech balances are self-tracked; the token subscription tracker gates payout on the real `IERC20(token).balanceOf(this)`. No external-balance figure is consumed gross where a net figure is required.
- **Access control** — `checkAndRecordDeliveryRates`, `finalizeDeliveryRates`, `adjustMechRequesterBalances` are marketplace-only; `updateNumRequests`/`requestFromMarketplace` are marketplace-only; `changeImplementation`/`setMechFactoryStatuses`/`setPaymentTypeBalanceTrackers`/`changeMarketplaceParams` are owner-only; Karma mutation is whitelisted-marketplace-only.
- **Reentrancy** — every state-changing external entry point in the balance trackers and marketplace carries the `_locked` guard; the one documented asymmetry (`deliverMarketplaceWithSignatures` on `OlasMech`) is non-re-enterable in practice (`Vulnerabilities_marketplace.md` #1).
- **Expired-request fallback delivery** — a non-priority mech delivering an expired request after `responseTimeout` is intended fallback behaviour and is the already-documented `Vulnerabilities_marketplace.md` **#7** class (funds follow the delivering mech; requester over-payment is refunded to balance).
- **Signature verification** — `_verifySignedHash` handles EIP-1271 for contract requesters and ECDSA (with s-malleability rejection) for EOAs; the `v ∈ {0,1,2,3}` acceptance is the documented, non-exploitable #8.
- **`SubscriptionProvider.fulfill`** — permissionless but downstream-gated by the Nevermined condition contracts (documented #15); holds no funds.

---

## On-chain grounding (read-only)

Base mainnet, `MechMarketplaceProxy` `0xf24eE42edA0fc9b33B7D41B06Ee8ccD2Ef7C5020`:

- `owner()` = `0xE49CB081e8d96920C38aA7AB90cb0294ab4Bc8EA` — a **contract** (governance-controlled), not an EOA. Owner-gated functions (implementation upgrade, factory whitelist, tracker map, params) are therefore under governance control; this calibrates L-2 / I-4 as governance-triggered rather than open.
- `getImplementation()` = `0x155547857680A6D51bebC5603397488988DEb1c8`; `fee()` = `1500` (15%); `VERSION` = `1.1.0`; `minResponseTimeout` = `60`.
- D-1 verified: native subscription tracker `0x3d79737f05966c5925a04d1b04110006F5a072bE` still runs the pre-fix `depositFor` bytecode.

---

## Conclusion

The marketplace codebase is carefully engineered and this re-audit surfaced **no new vulnerability** beyond what is already recorded in `Vulnerabilities_marketplace.md`. The results reconcile with the project's existing known-issue set: the notable payout-keying observation (I-1) is not exploitable given the Service Registry lifecycle's operator-gated `unbond`; the requester-withdrawal observation (I-2) restates documented #4/#7; the remaining items are Low/config/deployment or cosmetic. The single actionable operational item is **D-1** — redeploy the Nevermined-native tracker to close the already-documented #16 on-chain.
