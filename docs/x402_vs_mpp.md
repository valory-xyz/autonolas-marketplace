# x402 vs MPP Session, When to Use Which

A practical decision guide for choosing between the two paid-API families being added to the Mech Marketplace.

## TL;DR

| | x402 | MPP Session |
|--|------|-------------|
| One sentence | Pay per request with a signed USDC authorization | Open a channel once, sign off-chain vouchers, settle in batches |
| Best for | One-off requests from anonymous agents | Long-running clients making many requests |
| First-request cost | 1 on-chain tx | 2 on-chain txs (open + first delivery) |
| Nth-request cost | 1 on-chain tx | 0 (just an off-chain HTTP roundtrip) |
| Crossover point | n/a | After ~3 requests per channel session |
| Ecosystem today | ~14,000 services on x402scan | ~226 on MPPscan |
| Specs | `docs/x402_spec.md` | `docs/mpp_session_spec.md` |

If you cannot decide, ship **x402 first**. It catches the existing agent ecosystem with one HTTP shape and one settlement model. Add MPP later only if a real high-volume client emerges.

---

## 1. The Fundamental Difference

x402 and MPP session are not different protocols solving the same problem. They are solving different access patterns.

```
x402 = "pay-per-call"                    MPP session = "subscribe-then-call"

  per request:                              once per session:
    sign EIP-3009 transfer                    open channel (pull deposit)
    POST + retry                              done with on-chain setup
    on-chain settle                         per request:
                                              sign voucher locally
                                              POST + retry
                                              accepted, no on-chain
                                          once per session:
                                              close channel (refund residual)
```

x402 has no concept of state between requests. Each request is independent and self-contained. MPP session relies on an on-chain channel that persists across many requests, and the cost of opening that channel amortizes over usage.

This is the only difference that matters. Everything else (HTTP shapes, SDKs, ecosystem stats) follows from this one design choice.

---

## 2. Decision Matrix

The right answer almost always falls out of two axes. Both matter.

**Axis 1, throughput**. How many requests will a typical client send per session?
- Low N (1-3): x402 wins. Channel setup overhead is wasted.
- High N (10+): MPP session wins. Per-request gas drops to zero after open.

**Axis 2, risk appetite**. Which kind of safety do we prefer?
- **x402**: client funds are never locked, but the mech eats the tool cost if the client moves their USDC out between HTTP 200 and on-chain settle (settlement race, see Section 5 and `docs/x402_spec.md` §3.6).
- **MPP session**: deposit is locked in escrow at `open()`, so settlement is guaranteed by construction (no race possible). The cost is a new escrow contract to audit and a deposit the client has to plan for.

Put bluntly: x402 is cheaper to ship and safer for clients. MPP is more efficient at volume and safer for mechs. The matrix below maps common client profiles onto these two axes.

| Client profile | Recommended |
|----------------|-------------|
| One request, then never returning | x402 |
| 2-3 requests within a session | x402 (channel overhead not worth it) |
| 10+ requests per session | MPP session |
| Continuously running agent making periodic queries | MPP session |
| Cannot or will not pre-lock funds | x402 |
| Wants automatic discovery via x402scan / Bazaar | x402 (today; MPP discovery exists but is much smaller) |
| Needs cheap steady-state cost on a high-gas chain | MPP session |
| Lives on Gnosis with bridged USDC (no EIP-3009) | MPP session (works on any ERC-20) |
| Wants the IETF-standardized protocol | MPP session |
| Wants to use an existing Coinbase-stack SDK | x402 |
| Needs results within the same HTTP roundtrip with no setup | x402 |
| Operating as part of a long-lived autonomous service (e.g. Optimus) | MPP session |

---

## 3. Crossover Math

Compare on-chain transaction counts for `N` requests from a single client to a single mech:

```
x402              :  N transactions  (one per request)
MPP session       :  2 transactions  (open + close, regardless of N)
                     plus batched deliveries at whatever cadence
                     the mech chooses (1 batch covers N requests
                     under one channel)
```

Worked numbers, assuming `gas_per_tx = 200000` and per-request quote = 0.0102 USDC:

| N requests | x402 txs | MPP session txs | When MPP wins |
|------------|----------|-----------------|---------------|
| 1 | 1 | 3 (open + delivery + close) | Never (x402 is 2 txs cheaper) |
| 2 | 2 | 3 | Never (1 tx more for MPP) |
| 3 | 3 | 3 | Tie |
| 5 | 5 | 3 | MPP saves 2 txs |
| 10 | 10 | 3 | MPP saves 7 txs |
| 100 | 100 | 3 | MPP saves 97 txs |
| 1,000 | 1,000 | 3 | MPP saves 997 txs |

**Crossover happens at N = 3.** Below that, x402 is strictly cheaper. Above that, MPP wins by a margin that grows linearly with usage.

In dollar terms on Base (~$0.05 per tx at typical gas):

| Daily volume per client | x402 daily gas | MPP daily gas | Difference |
|-------------------------|----------------|----------------|------------|
| 5 requests | $0.25 | $0.15 | $0.10 saved with MPP |
| 50 requests | $2.50 | $0.15 (one channel) | $2.35 saved with MPP |
| 500 requests | $25.00 | $0.15 | $24.85 saved with MPP |

On Gnosis where gas is essentially free (~$0.0005 per tx), the absolute savings are negligible. Crossover math holds, but the dollar impact is too small to matter for client choice.

So: **on cheap chains, the choice is about UX and ecosystem fit. On expensive chains, the choice is mostly about volume.**

---

## 4. Five Concrete Personas

### Persona A: One-shot LLM agent

> "I'm a one-time scraper running a single inference. I have no relationship with this mech."

**Use x402.** Zero setup cost. Pay once, walk away. Locking $0.50 into a channel only to use $0.01 of it would be silly.

### Persona B: Polymarket-style consumer agent

> "I'm checking 50 markets a day, hitting predict mechs for confidence scores."

**Use MPP session.** 50 requests amortize across one channel. Off-chain vouchers keep gas near zero. Pearl-mini already uses MPP for exactly this pattern.

### Persona C: Optimus running 24/7

> "I'm an autonomous trading service, making periodic prediction requests forever."

**Use MPP session.** Channel auto-cycles when the deposit drains. Steady-state cost is dominated by HTTP traffic, not gas.

### Persona D: An agent crawling the x402scan directory

> "I'm discovering services from x402scan and want to call whatever I find."

**Use x402.** This persona only exists because the x402 ecosystem exists. Discovery is the value-add, and MPP doesn't have a comparable directory.

### Persona E: A high-volume backend service

> "I'm running batched prediction jobs from a backend. Latency matters less than cost."

**Use MPP session.** Set channel deposit generously, let it run for hours, settle in big batches. This is roughly how the wildcard server runs predictions for pearl-mini.

---

## 5. Tradeoffs People Don't Talk About

### The deposit-lock cost

MPP requires the client to lock funds in the escrow up to `maxDeposit`. For a $0.50 default, this is trivial. For larger deposits (say $50 for a heavy-use channel), the opportunity cost matters slightly. Closing the channel returns the residual, but mid-channel the funds are illiquid.

x402 has no equivalent. Funds stay in the client wallet until the moment of settlement.

### The hot key risk on the mech side

MPP requires the mech to hold a key that can call `MppEscrow.settle()` and `close()`. This key is exposed to settlement traffic and may live on a hot wallet for throughput reasons. Compromise risk is bounded (the key can only direct funds into the `BalanceTrackerMppSession` payee address, not exfiltrate), but it is non-zero.

x402 has no equivalent. The mech submits standard `deliverMarketplaceWithSignatures` calls, no separate key.

### The chain selection lock-in

x402 depends on USDC supporting EIP-3009. This currently means native Circle USDC (Base, Optimism, Polygon, Ethereum, Avalanche). Gnosis bridged USDC is **untested** and may not work.

MPP depends only on `transferFrom`. Works on every ERC-20 on every EVM chain. **MPP supports a strictly broader chain set than x402.**

For mechs that need to run on Gnosis, MPP may be the only viable choice.

### The protocol bet

x402 is an informal Coinbase spec. Coinbase is pushing it, has a facilitator, has SDKs, has the agent ecosystem. But it is not standardized.

MPP is on the IETF standards track (`draft-ryan-httpauth-payment`). It has Stripe-backed Tempo behind it. The standards-track route is slower but more durable.

If "this protocol still works in 5 years" matters, MPP has the better trajectory. If "this protocol has users today" matters, x402 wins.

### The settlement race window

x402 has the "client moves USDC out between t1 and t3" race (H-1 finding in `docs/x402_key_findings_pre_audit.md`). Bounded by `maxDeliveryRate` per request.

MPP cannot have this race because the deposit is already locked in escrow. The mech is guaranteed it can claim up to the latest signed cumulative. **MPP is strictly safer than x402 on the settlement side.**

The flip side: MPP has the "client never closes channel" risk. The mech can claim up to the latest signed cumulative but cannot grab unsigned funds. The escrow contract holds residuals until either the mech closes or the client `forceClose`s after `CLOSE_TIMEOUT`. Not a financial loss, but capital stays locked longer than desired.

### The discovery surface

x402scan and the Coinbase Bazaar index every x402 service automatically (via direct registration or facilitator-based crawling). For an AI agent searching for "any service that does prediction," x402scan is the first stop. ~14k services indexed.

MPPscan has ~226 services. Lower visibility. Agents looking for paid APIs today are not finding their results on MPPscan.

This may flip in the long run, but for v1 the agent ecosystem is on x402.

### Failure mode side-by-side

Synthesis of the trade-offs above. Each cell is grounded in the source specs; references in parentheses point to the relevant section.

| Failure mode | x402 | MPP session |
|---|---|---|
| Client moves USDC out before on-chain settle | YES, mech eats tool cost per request, bounded by `maxDeliveryRate` (`x402_spec.md` §3.6) | NO, deposit locked in escrow at `open()` (`mpp_session_spec.md` §3.9 failure mode 1) |
| Client signs malformed auth or voucher | Reverts atomically at settle (`x402_spec.md` §3.3) | Reverts atomically at settle (`mpp_session_spec.md` §3.2) |
| Mech griefs the client (consumes auth without delivering) | Bounded by `maxDeliveryRate` per request | Bounded by `maxDeposit` per channel |
| Client disappears mid-session | No funds locked, no recovery needed | Funds locked until client calls `forceClose` after `CLOSE_TIMEOUT` (24h) (`mpp_session_spec.md` §3.1, §8) |
| Cross-mech replay of auth or voucher | Blocked: `requestId` includes the calling mech (`x402_spec.md` §3.7) | Blocked: same `requestId` binding plus `salt = keccak256(mechAddress)` convention (`mpp_session_spec.md` §8) |
| Per-request gas cost to the mech | Linear in N: each request needs its own `transferWithAuthorization` (~50k gas, `x402_spec.md` §3.3) | Constant after open: off-chain vouchers, batched settle (`mpp_session_spec.md` §3.7) |

The asymmetry is real: x402 protects the client from lock-in, MPP protects the mech from settlement loss. Neither is strictly safer; they trade different risks.

---

## 6. Coexistence Is Cheap

Worth saying explicitly: **the marketplace can support both at no extra cost** beyond the contracts themselves.

Both families:
- Leave `MechMarketplace` and `OlasMech` untouched
- Extend `BalanceTrackerBase` via the `_adjustInitialBalance` hook
- Register against `mapPaymentTypeBalanceTrackers` with distinct payment-type keys
- Reuse the existing `deliverMarketplaceWithSignatures` flow on-chain
- Reuse karma and fee logic unchanged
- Coexist behind different `paymentType()` values on the mech

A single mech can only have one `paymentType`, so a marketplace that wants to offer both serves two separate mech instances (one x402, one MPP). The same off-chain code can handle both HTTP shapes on the same `/predict` endpoint, routing on the `WWW-Authenticate` vs `X-Payment` header.

The cost of supporting both:
- 7 new contracts total (3 x402 + 4 MPP)
- Two HTTP protocol shapes in the mech behaviour
- Two SDKs in the client docs
- Two audit scopes

The benefit of supporting both:
- Every persona above can use the mech without compromise

---

## 7. Recommendation

For the Mech Marketplace v1, the practical sequence is:

**Phase 1, ship x402 first.**
- The PR #148 spec is already written and reviewed.
- Catches the existing agent ecosystem (14k services, Coinbase momentum).
- Smaller contract set, smaller audit surface.
- Mech operators can launch and immediately get discoverable on x402scan.
- If no high-volume client ever materializes, you do not need MPP at all.

**Phase 2, add MPP session when (and only when) you have a concrete high-volume client.**
- Examples: Optimus, an internal Valory product, a partner who specifically requests it.
- The contracts are orthogonal to x402, so adding MPP later does not invalidate any x402 deployment.
- Mech operators can opt in by deploying an MPP mech alongside their x402 mech.
- This avoids paying for an audit and operational complexity that may not earn its keep.

**Skip both** if the use case is purely internal Olas traffic. The existing pre-deposit `BalanceTrackerFixedPriceToken` flow is fine for known requesters with predictable usage; it batches natively, has no deposit-lock for clients (they already deposit), and has zero new contracts.

---

## 8. Anti-Recommendations

A few things that look reasonable but are not:

- **"Just ship MPP, it does everything x402 does plus batching."** Technically true (MPP charge mode is x402-equivalent). But you give up the x402 ecosystem (x402scan, Bazaar, existing SDK clients). Today the right answer is the opposite: ship x402 first, MPP later.
- **"Mech operators should choose per request."** No. Each mech has one `paymentType`. A mech operator picks once when they deploy.
- **"Let the client pick by sending a different header."** Already true via the routing table in `docs/x402_spec.md` Section 4 and `docs/mpp_session_spec.md` Section 4. But the mech contract still has one payment type, so this only works if you deploy two mech instances.
- **"x402 is going away because MPP is on the IETF track."** Not yet. IETF tracks take years. x402 has volume today. Bet on both if you must, but do not preemptively kill x402.
- **"MPP requires Tempo chain."** No. Pearl-mini uses Tempo because that is where Coinbase deployed `TempoStreamChannel`. The mech version of MPP deploys its own `MppEscrow` on whatever chain it runs on (Gnosis, Base, etc.). The IETF protocol is chain-agnostic.

---

## 9. Open Questions That Affect The Decision

These do not have answers yet, and answering them might shift the recommendation:

1. **Does Gnosis bridged USDC support EIP-3009?** If no, x402 is impossible on Gnosis, and MPP becomes the default for that chain. See `docs/x402_implementation_plan.md` Open Item 2.
2. **Is there a known v1 client that needs MPP?** If yes, ship both. If no, stick with x402-first.
3. **What is the actual marketplace fee structure for high-frequency clients?** If the marketplace wants to charge a per-channel-open fee in addition to per-request fees, MPP needs a fee hook in `MppEscrow.open`. Not in this spec.
4. **Does the mech request signature (Signature 2) ride in `Payment-Credential` or a separate header?** Same open item as x402. Decision affects both client SDKs.

---

## 10. References

- `docs/x402_spec.md`, full x402 design
- `docs/x402_implementation_plan.md`, phased x402 build plan + remaining open items
- `docs/x402scan_integration.md`, x402 ecosystem discovery
- `docs/mpp_session_spec.md`, full MPP session design
- `docs/x402_key_findings_pre_audit.md` (on `origin/402`), security findings pre-audit
- `wildcard/server/src/session/`, reference MPP server implementation in production
- `pearl-mini/src/core/prediction/`, reference MPP client implementation in production
- [x402 docs](https://docs.x402.org/)
- [MPP protocol spec](https://mpp.dev/)
- [IETF draft-ryan-httpauth-payment](https://datatracker.ietf.org/doc/draft-ryan-httpauth-payment/)
