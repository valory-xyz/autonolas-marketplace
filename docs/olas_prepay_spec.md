# Olas Prepay, Minimum-Viable API Access for the Mech Marketplace

## 1. Overview

This document specifies the minimum changes required to open the Mech Marketplace to HTTP-style paid-API access **without introducing a new payment family**. The existing pre-deposit `BalanceTrackerFixedPriceToken` is structurally identical to a payment channel: clients lock funds upfront, the mech serves many off-chain requests against the locked balance, and the mech settles the resulting deliveries in batches on-chain. Most of the plumbing already exists across three layers. We just need to close a few gaps.

This sits alongside `x402_spec.md` (Option A) and `mpp_session_spec.md` (Option B) as the third option. It is the smallest scope of the three and the fastest to ship.

### Design intent

| Goal | How this spec meets it |
|------|------------------------|
| Open the marketplace to HTTP-native clients | Add a useful HTTP 402 challenge body to the mech's existing handler |
| Avoid per-request on-chain settlement | Reuse the existing `deliverMarketplaceWithSignatures` batched path |
| Let clients recover unused funds | Add `withdrawRequester` to the balance tracker |
| Avoid building any new payment family | Reuse `BalanceTrackerFixedPriceToken`, `MechFixedPriceTokenUSDC`, and the existing factory |
| Avoid breaking changes to MechMarketplace, OlasMech, Karma | Zero changes to those contracts |

### What's deliberately out of scope

- x402 protocol compatibility (no EIP-3009 gasless deposit, no `X-Payment` header).
- MPP protocol compatibility (no EIP-712 vouchers, no `MppEscrow`).
- Off-the-shelf discoverability on x402scan or MPPscan (see Section 7 for the upgrade path).

The spec deliberately gives up wide ecosystem compatibility in exchange for shipping in roughly one to two weeks with one new on-chain function.

---

## 2. Current architecture

Across the three layers, here is what is in place today.

### 2.1 Contract side, the marketplace + balance tracker

```
   Client EOA / Safe
        │
        │  USDC.approve(BalanceTracker, X)
        │  BalanceTracker.deposit(X)           ──────────▶ mapRequesterBalances[client] += X
        ▼
   MechMarketplace.request(...)                ──────────▶ debits mapRequesterBalances via
                                                          checkAndRecordDeliveryRates
                                                          (per-request, on-chain)
   ── OR via signature flow ──
   OlasMech.deliverMarketplaceWithSignatures(...)
                                               ──────────▶ debits mapRequesterBalances via
                                                          adjustMechRequesterBalances
                                                          (one call per batch, on-chain)
```

What exists:
- `BalanceTrackerFixedPriceToken.deposit(amount)` (`contracts/mechs/token/BalanceTrackerFixedPriceToken.sol:93-101`) pulls USDC via `transferFrom` and credits `mapRequesterBalances[msg.sender]`.
- `depositFor(account, amount)` (lines 107-115) does the same on behalf of another address.
- `_adjustInitialBalance` in `BalanceTrackerBase` (lines 90-111) debits `mapRequesterBalances[requester]` by the summed delivery rate.
- The marketplace's `deliverMarketplaceWithSignatures` (`MechMarketplace.sol:833`) verifies each request's `_verifySignedHash`, records the delivery, increments karma, then calls `BalanceTrackerX.adjustMechRequesterBalances` with `paymentData = b""` for the existing flow.

What's missing:
- **No requester withdraw entry.** `BalanceTrackerFixedPriceToken` has `deposit()` and `depositFor()` but nothing for the requester to recover their unused balance. The only paths out of `mapRequesterBalances` today are deliveries.

### 2.2 Mech side, the off-chain HTTP handler

The mech (running under open-autonomy) already has an HTTP server that accepts off-chain signed requests.

```
   Mech process
   ├── Prometheus HTTP server (start_http_server, handlers.py:560-564)
   │
   ├── MechHttpHandler                                (handlers.py:518)
   │   ├── POST  /send_signed_requests                _handle_signed_requests
   │   │         body: {request_id, ipfs_hash,
   │   │                sender, delivery_rate,
   │   │                signature, ipfs_data}
   │   │         flow:
   │   │           1. validate request body           (handlers.py:577-609)
   │   │           2. check on-chain balance          _check_offchain_requester_balance
   │   │                 reads mech.paymentType()                  (handlers.py:880)
   │   │                 reads mapPaymentTypeBalanceTrackers       (handlers.py:886-892)
   │   │                 reads mapRequesterBalances[requester]    (handlers.py:902-906)
   │   │           3. if available < required:        respond HTTP 402  (handlers.py:631-639)
   │   │           4. else enqueue task               _enqueue_offchain_request
   │   │
   │   └── GET   /fetch_offchain_info                 _handle_offchain_request_info
   │             returns stored response by request_id
   │
   └── task_submission_abci.behaviours
       (behaviours.py:1580-1648)
       Every batch cycle:
         aggregate accepted offchain requests by sender
         build deliver_with_signatures = [{requestData, signature, deliveryData}, ...]
         build delivery_rates = [...]
         call deliverMarketplaceWithSignatures with paymentData = b""
```

What exists:
- HTTP route for signed requests + polling for results.
- Live on-chain balance check before accepting work.
- HTTP 402 returned on insufficient balance.
- Batched on-chain settlement via `deliverMarketplaceWithSignatures(paymentData="")`.
- Per-request signature verification on-chain via `MechMarketplace._verifySignedHash`.

What's missing:
- **The 402 response is a bare rejection.** `_send_rejection_response` returns `status_code=402, status_text="Payment required"` but the body is empty. A client receiving this has no way to know what to deposit, where, or how much.
- **No deposit-instruction route.** No endpoint tells a fresh client how to fund itself.

### 2.3 Client side, mech-interact

The autonomous services that consume mech responses (Trader, Market-Creator, MemeOoorr, Pearl, IEKit, etc.) all use the `mech_interact_abci` skill. Its current flow is purely on-chain.

```
   mech_interact_abci/behaviours/
   ├── request.py
   │   MechRequestBehaviour:
   │     _get_payment_type()                    on-chain read
   │     _ensure_available_balance()           checks safe / token balance (request.py:512-563)
   │                                            (NB: does NOT read BalanceTracker today)
   │     _build_token_approval()               builds USDC.approve to BalanceTracker
   │     _build_marketplace_v2_request_data    encodes MechMarketplace.request(
   │                                              request_data,
   │                                              priority_mech,
   │                                              payment_data = EMPTY_PAYMENT_DATA_HEX,
   │                                              payment_type,
   │                                              response_timeout,
   │                                              max_delivery_rate)
   │
   └── response.py
       MechResponseBehaviour:
         polls for Deliver event on the mech / marketplace contract
         filters by request_id
         decodes IPFS hash → fetches result from IPFS
```

What exists:
- Full on-chain request submission via `MechMarketplace.request()` / `requestBatch()`.
- Per-payment-type branching for native vs token vs NVM.
- USDC approval flow.
- Event-based response polling.

What's missing:
- **No off-chain signed-request flow.** mech-interact never POSTs to the mech's HTTP endpoint. Every request is one on-chain transaction.
- **No deposit-then-batched-delivery flow on the client side.** Even though the mech supports it server-side, the client always uses the per-request on-chain path.

---

## 3. Minimum v1 changes

Three small deltas, one per layer. Total scope is roughly one to two weeks of work plus a contract audit.

### 3.1 Contract side, one new function

Add a requester withdraw entry to `BalanceTrackerFixedPriceToken` so a client can recover unused balance. Two ways to ship it.

**Option X1, modify in place (~10 lines, ~1 line of fee logic).** Add directly to `BalanceTrackerFixedPriceToken.sol`:

```solidity
function withdrawRequester(uint256 amount) external {
    if (_locked == 2) revert ReentrancyGuard();
    _locked = 2;

    uint256 balance = mapRequesterBalances[msg.sender];
    if (balance < amount) revert InsufficientBalance(balance, amount);
    mapRequesterBalances[msg.sender] = balance - amount;

    IToken(token).transfer(msg.sender, amount);
    emit Withdraw(msg.sender, token, amount);

    _locked = 1;
}
```

Reentrancy-guarded for safety. Uses the existing `Withdraw` event. Touches no other state.

**Option X2, deploy a thin subclass (~30 lines).** Define `BalanceTrackerFixedPriceTokenWithdraw` that inherits `BalanceTrackerFixedPriceToken` and adds the same function. Deploy a new instance, register against the same payment type via `setPaymentTypeBalanceTrackers`, migrate live balances. More work to deploy, zero changes to a live contract.

Pick one. X1 is cheaper to ship but mutates an existing contract; X2 keeps existing code untouched but requires a migration of `mapRequesterBalances`.

**No other contract changes.** MechMarketplace, OlasMech, Karma, fee logic, all factories, all other balance trackers stay exactly as they are.

### 3.2 Mech side, replace the 402 body

In `mech/packages/valory/skills/task_execution/handlers.py`, change `_send_rejection_response` (or add a new helper) so the 402 response includes deposit instructions.

```python
# Current (handlers.py:631-639)
if available_amount < request_delivery_rate:
    self._send_rejection_response(
        http_msg, http_dialogue, request_id,
        reason="insufficient balance",
        status_code=HttpCode.PAYMENT_REQUIRED_CODE.value,
        status_text="Payment required",
    )
    return

# Proposed: include a structured body with deposit instructions
if available_amount < request_delivery_rate:
    body = {
        "scheme": "olas-prepay",
        "network": ledger_settings[ResponseKey.CHAIN_ID.value],
        "payee": balance_tracker_address,
        "token": usdc_token_address,
        "currentBalance": str(available_amount),
        "required": str(request_delivery_rate),
        "recommendedDeposit": str(request_delivery_rate * 100),   # ~100 requests
        "deposit": {
            "function": "depositFor",
            "abi": "depositFor(address account, uint256 amount)",
            "args": {"account": sender, "amount": str(request_delivery_rate * 100)}
        },
        "withdraw": {
            "function": "withdrawRequester",
            "abi": "withdrawRequester(uint256 amount)"
        },
        "error": "Payment required, deposit USDC to continue"
    }
    self._send_402_with_body(http_msg, http_dialogue, request_id, body)
    return
```

That is the entire mech-side change. The existing balance check, task queue, signed-request validation, and batched settlement all stay as they are.

Optional add: a new `GET /well-known/olas-prepay` route that returns the same instructions without a 402, so clients can discover deposit info before sending a request.

### 3.3 Client side, mech-interact gets an HTTP branch

Add a new behaviour (or extend `MechRequestBehaviour`) that uses the mech's HTTP endpoint instead of the on-chain `request()` call. This is the bigger of the three changes but still bounded.

```
   mech_interact_abci/behaviours/
   └── http_request.py                      NEW
       MechHttpRequestBehaviour:
         1. resolve mech HTTP endpoint     (from params.mech_http_url or via discovery)
         2. check pre-deposit balance       on-chain read of mapRequesterBalances[safe]
         3. if balance < quote:
              build USDC.approve + BalanceTracker.depositFor multisend
              submit on-chain                                     ◀── one tx, only when needed
         4. sign requestData with safe key  (same shape as deliverMarketplaceWithSignatures
                                              expects: hash includes mech, requester,
                                              requestData, deliveryRate, paymentType, nonce)
         5. POST to mech /send_signed_requests
              body: {request_id, ipfs_hash, sender, delivery_rate, signature, ipfs_data}
         6. receive HTTP 200 with request_id
              OR HTTP 402 with deposit instructions ◀── re-trigger step 3 with the
                                                       recommendedDeposit from the body
         7. store request_id for response polling
```

The matching response behaviour either keeps using on-chain Deliver event polling (the mech's batched `deliverMarketplaceWithSignatures` emits the same Deliver event) or switches to the HTTP `GET /fetch_offchain_info` polling that the mech already supports.

A new param is needed in `skill.yaml`:

```yaml
mech_http_url: ""               # if set, use the HTTP request branch
prefer_http_path: false         # explicit opt-in
```

Estimated effort: ~300-500 lines of new behaviour code in `mech_interact_abci`, plus tests. The existing `_ensure_available_balance` and the multisend approval helper get reused.

---

## 4. End-to-end flow

```
Client Safe        Trader (mech-interact)        Mech HTTP        Mech behaviours     On-chain
──────────         ───────────────────────       ──────────       ────────────────    ────────

                                                                                      One-time setup:
                                                                                      USDC.approve(BalTracker, X)
                                                                                      BalTracker.depositFor(safe, X)
                                                                                                  │
                                                                                                  ▼
                                                                                      mapRequesterBalances[safe] += X
                                                                                                  ╱
                                                                                                 ╱ now ready
                                                                                                ╱

   ◀──── mech_interact_abci issues a request ────▶

                  resolve quote (max delivery rate)
                  sign requestData → signature
                  POST /send_signed_requests ──────────▶ parse body
                                                         _check_offchain_requester_balance
                                                            on-chain read: mapRequesterBalances[safe]
                                                         IF balance >= quote:
                                                            enqueue task                      ──▶ run tool
                                                            HTTP 200 { request_id }
                                                         ELSE:
                                                            HTTP 402 with deposit instructions

                  IF HTTP 402:
                    multisend: approve + depositFor                                                     ──▶ deposit tx
                    retry POST

                  poll for response:
                    GET /fetch_offchain_info?request_id     OR    listen for Deliver event on-chain

   ◀──── periodically, mech batches and settles ────▶

                                                         task_submission_abci builds:
                                                            deliver_with_signatures = [N items]
                                                            delivery_rates = [...]
                                                            paymentData = b""
                                                         Submit deliverMarketplaceWithSignatures ──▶ marketplace records N
                                                                                                    deliveries, debits
                                                                                                    mapRequesterBalances[safe]
                                                                                                    by sum(rates), credits
                                                                                                    mapMechBalances[mech].
                                                                                                    Karma + fees fire.

   ◀──── eventually, client withdraws unused balance ────▶

                  call BalTracker.withdrawRequester(amount) ──────────────────────────▶ mapRequesterBalances[safe] -= amount
                                                                                       USDC.transfer(safe, amount)
```

Two on-chain transactions in steady state per long-lived client:
- one deposit upfront (or top-up when 402 hints at it)
- one batched settlement per N requests

Plus one optional withdraw when the client is done.

Compare to today (mech-interact on-chain path): every request is at minimum one `request()` tx, often two if approval is needed. So this collapses N+1 transactions per N requests down to roughly 2.

---

## 5. Downsides and what we give up

This path is deliberately scoped down. Things to be explicit about.

**No gasless client deposit.** The client EOA / Safe must have native gas (xDAI on Gnosis, ETH on Base) to call `approve` + `depositFor`. x402's EIP-3009 trick (client signs, mech submits) is the value-add we are NOT building. If our clients always have native gas (which Trader-style services do), this is fine. If we want to support pure-USDC HTTP agents, we'd need the x402 path.

**No protocol-level compatibility with x402 or MPP clients.** The 402 response body has shape `{"scheme": "olas-prepay", ...}`, not the x402 `{"x402Version": 1, "accepts": [...]}` or MPP `WWW-Authenticate: Payment ...`. A generic x402 or `mppx` client cannot pay an olas-prepay mech without our custom adapter.

**No automatic discovery via x402scan or MPPscan.** Both indexers expect specific discovery formats (`/.well-known/x402` for x402, `GET /openapi.json` with `x-payment-info` for MPPscan). We could add an OpenAPI document later, but a "scheme: olas-prepay" entry will not be indexable by either today.

**Trader-only flow.** Only services that adopt the new `MechHttpRequestBehaviour` benefit. Existing on-chain `request()` callers keep working unchanged, but they keep paying per-request gas.

**Per-request signature, not voucher.** We use the existing per-request `_verifySignedHash` model. MPP's cumulative voucher is a UX improvement (one signature for many requests). Per-request signing is functionally equivalent for security but slightly noisier off-chain.

**Settlement race still exists.** A client could call `withdrawRequester` to drain `mapRequesterBalances` between a successful HTTP 200 and the mech's next batched settlement. The settlement would revert (`InsufficientBalance`), the mech eats the cost of the served request. This is the same shape of risk as x402's settlement race, bounded by the same `maxDeliveryRate`. Mitigations:
- Mech checks balance at HTTP accept time (already done).
- Mech can optionally reserve the balance off-chain in `synchronized_data` until settlement, refusing to accept further work that would exceed the reserved amount.
- The withdraw entry can include a per-block delay or a "pending settlement" check.

**No requester refund on partial overpayment in the deposit step.** Once funds are in the BalanceTracker, the only way out is `withdrawRequester` (new) or successful delivery. There is no automatic refund.

**The risk asymmetry with MPP:** in MPP, funds are locked in the escrow until settled; the mech is always paid. In this spec, funds are in the BalanceTracker but the client can withdraw before settlement. So the mech bears more risk here than under MPP session. The trade is one fewer contract to audit and a much smaller scope.

---

## 6. Comparison vs the other two options

| Property | This spec (olas-prepay) | x402 | MPP session |
|----------|--------------------------|------|-------------|
| New contracts | 0 (X1) or 1 (X2) | 3 | 4 |
| Client gas required | Yes, to deposit | No (EIP-3009) | Yes, to open channel |
| Per-request on-chain cost | None after deposit | One settle per request | None after open |
| Settlement race exposure | Yes (bounded by maxRate) | Yes (bounded by maxRate) | No (escrow holds funds) |
| Out-of-the-box agent compatibility | None, requires Valory adapter | High, any x402 client works | None, requires Valory adapter |
| Discoverable on x402scan | No without an adapter | Yes via register-origin | No |
| Discoverable on MPPscan | No without OpenAPI doc | No | Yes via OpenAPI self-registration |
| Standardization | Valory-only | Coinbase informal spec | IETF-track framework, but EVM session is a Valory extension |
| Estimated effort | ~1-2 weeks + audit of 1 function | ~3-4 weeks + audit of 3 contracts | ~6-8 weeks + audit of 4 contracts |

---

## 7. Path to MPP-protocol compatibility (if we want it later)

If at some future point the team decides being indexable on MPPscan and payable by generic MPP clients matters, the upgrade path is orthogonal and additive. Nothing in this spec needs to be torn down.

Three steps to add MPP-protocol compatibility on top of olas-prepay:

### 7.1 Serve an OpenAPI discovery document

MPPscan indexes services by reading `GET /openapi.json` with `x-payment-info` annotations on paid endpoints. Add a new mech HTTP route that returns such a document:

```json
{
  "openapi": "3.1.0",
  "info": {
    "title": "Olas Mech",
    "version": "1.0.0",
    "x-guidance": "AI tool execution via Olas marketplace. Pre-deposit USDC to a balance tracker, then sign per-request hashes."
  },
  "paths": {
    "/send_signed_requests": {
      "post": {
        "summary": "Submit a signed paid request",
        "x-payment-info": {
          "price": { "mode": "fixed", "currency": "USD", "amount": "0.0102" },
          "protocols": [
            { "olas-prepay": { "scheme": "balance-tracker" } }
          ]
        },
        "responses": { "402": { "description": "Payment Required" } }
      }
    }
  }
}
```

Self-register at `https://www.mppscan.com/register`. This alone gives MPPscan listing. Source: [mppscan.com/discovery/spec](https://www.mppscan.com/discovery/spec).

This step is documentation-only on the mech side; no contract or client changes.

### 7.2 Accept MPP-shaped HTTP headers as an alternative entrypoint

For an `mppx`-shaped client to talk to the mech, accept the standard MPP headers:

- `WWW-Authenticate: Payment <challenge>` on 402 (in addition to the structured body olas-prepay already returns).
- `Payment-Credential: <base64 credential>` on the retry (in addition to the body-based signature).
- `Payment-Receipt: <base64 receipt>` on 200.

The credential can either be a voucher (EIP-712 over `{channelId, cumulativeAmount}`) or a per-request signature. For full MPP-session compatibility we'd need the voucher form. For just being callable, the per-request signature form is enough if we document it.

### 7.3 If we want true MPP session semantics, layer on MPP-session contracts later

If voucher-based cumulative authorization matters at that point (because clients want a single signature for many requests, or because audit demands cumulative monotonicity enforced on-chain), this is the moment to add `MppEscrow`, `BalanceTrackerMppSession`, and the matching mech + factory from `mpp_session_spec.md`. The marketplace's registry pattern lets that family coexist with the existing pre-deposit family at no extra cost beyond the new contracts themselves.

### 7.4 If we want x402-protocol compatibility (a parallel path)

For x402 specifically (much larger ecosystem at ~14k services), the upgrade is the `BalanceTrackerX402` family from `x402_spec.md`. It can ship in parallel with olas-prepay; the registry routes EIP-3009 paymentData to BalanceTrackerX402 and empty paymentData to whichever default tracker we point at.

---

## 8. What we need to build, summary

| Layer | File | Change | Effort |
|-------|------|--------|--------|
| Contract | `contracts/mechs/token/BalanceTrackerFixedPriceToken.sol` | Add `withdrawRequester(uint256)` (X1) | ~10 lines + audit |
| Contract (alt) | `contracts/mechs/token/BalanceTrackerFixedPriceTokenWithdraw.sol` | New subclass with the same function (X2) | ~30 lines + audit + migration |
| Mech | `mech/packages/valory/skills/task_execution/handlers.py` | Replace 402 body with structured deposit instructions | ~30 lines |
| Mech (optional) | same | New `GET /well-known/olas-prepay` discovery route | ~30 lines |
| Client | `mech-interact/packages/valory/skills/mech_interact_abci/behaviours/http_request.py` | New behaviour for HTTP signed-request path | ~300-500 lines + tests |
| Client | `mech-interact/.../skill.yaml` | Add `mech_http_url`, `prefer_http_path` params | ~5 lines |
| Docs | `docs/olas_prepay_spec.md` | This document | done |

Out-of-scope but trivial later additions:
- OpenAPI doc for MPPscan listing (~50 lines, no code change)
- MPP-shaped 402 headers (~30 lines in `handlers.py`)
- x402 contract family (existing spec, separate workstream)
- MPP session contract family (existing spec, separate workstream)

---

## 9. Open questions

1. **X1 vs X2 for the withdraw function.** Modify the live BalanceTrackerFixedPriceToken (X1, simpler, requires care during deploy) or deploy a new subclass + migrate (X2, no in-place mutation, more deploy work). Pin one.
2. **Quote pricing policy.** Same open item as the other two specs: client pays listed `maxDeliveryRate` (mech absorbs marketplace fee) or grossed-up (client pays the fee on top). Recommend listed price for v1 to keep client SDKs simple.
3. **Settlement race mitigation strength.** Do we accept the race fully (bounded by maxRate, document and move on), or add a "pending settlement" off-chain reservation in the mech behaviour that gates `withdrawRequester` by blocking new requests once the reservation matches the balance?
4. **Response delivery channel.** Keep using on-chain Deliver event polling (works today, but requires the client to listen on-chain) or switch to HTTP `GET /fetch_offchain_info` polling that the mech already supports? Recommend HTTP for new HTTP-path clients; on-chain stays as a fallback.

---

## 10. References

- `docs/x402_spec.md`, the x402 Coinbase-compatible alternative
- `docs/mpp_session_spec.md`, the MPP session alternative
- `docs/x402_vs_mpp.md`, decision guide comparing the two main alternatives
- `contracts/BalanceTrackerBase.sol`, the base class we extend
- `contracts/mechs/token/BalanceTrackerFixedPriceToken.sol`, where withdraw lands
- `mech/packages/valory/skills/task_execution/handlers.py`, the off-chain HTTP handler
- `mech/packages/valory/skills/task_submission_abci/behaviours.py`, the batched settlement
- `mech-interact/packages/valory/skills/mech_interact_abci/behaviours/request.py`, the client side that needs the HTTP branch
- [MPPscan discovery spec](https://www.mppscan.com/discovery/spec), for future MPPscan listing
- [x402scan register-origin](https://www.x402scan.com/register), for future x402scan listing
