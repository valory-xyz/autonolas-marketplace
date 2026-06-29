# x402scan Integration — How Mechs Can Appear in the x402 Ecosystem

## What is x402scan?

x402scan ([x402scan.com](https://x402scan.com)) is an **ecosystem explorer** for x402 — think of it like Etherscan but for paid APIs. It shows:

- All discoverable x402-compatible services (APIs you can pay for with crypto)
- Known sellers (who is selling API access)
- Top facilitators (who is processing payments)
- Agents (who is buying)
- Transaction volume and analytics per chain

As of today it indexes ~14,000 services from the Coinbase facilitator and ~6,000 from PayAI.

## How does a service end up on x402scan?

There are **two paths**:

### Path 1 — Direct registration

x402scan has a self-registration page: [x402scan.com/resources/register](https://www.x402scan.com/resources/register)

1. Submit the mech's x402 HTTP endpoint URL (e.g. `https://<mech-host>/x402/request`) — this is the public endpoint the mech will host for receiving x402 payment requests
2. x402scan hits it
3. If it returns a valid HTTP 402 response with proper x402 schema, it's listed automatically
4. No manual approval, no external facilitator required

### Path 2 — Bazaar (automatic, via external facilitator)

```
Mech endpoint
    ↓ uses
External facilitator for /verify
    ↓ facilitator indexes the mech
/discovery/resources endpoint
    ↓ read by
x402scan
    ↓ displays
Mech on x402scan.com
```

External facilitators (Coinbase, PayAI) are public hosted services. The mech makes HTTP calls to their `/verify` endpoint — no API keys needed, nothing to host. When your service verifies through a facilitator, that facilitator indexes it and exposes it via the Bazaar `/discovery/resources` API. This makes the mech discoverable not just on x402scan's website but also programmatically by AI agents querying the Bazaar.

---

## Our Chains and What's Available

Mechs run on Base, Polygon, and Gnosis (same codebase, same contracts). Here's what each chain has:

| Chain | Chain ID | Public Facilitator Available? | Path to x402scan |
|-------|----------|-------------------------------|-------------------|
| **Base** | `eip155:8453` | Coinbase + PayAI | Bazaar (automatic) or direct registration |
| **Polygon** | `eip155:137` | PayAI only | Bazaar (automatic) or direct registration |
| **Gnosis** | `eip155:100` | **None** | Direct registration only |

The x402 ecosystem is heavily concentrated on Base (~14k services). Polygon has facilitator support but few services listed. Gnosis has zero public facilitator support.

---

## Option A — Self-Facilitate on All Chains + Direct Registration

The mech is its own facilitator everywhere (as the spec currently describes), and self-registers on x402scan at startup. This is the simplest approach and works on all chains including Gnosis.

### How it works

```
Same on every chain:
  Mech serves /.well-known/x402 (static route listing)
  Mech verifies EIP-3009 signatures in-process (inside the behaviour)
  Mech settles via deliverMarketplaceWithSignatures
  Mech auto-registers with x402scan on startup
```

No external facilitator dependency. No per-chain config. No cost.

### Self-registration at startup

On launch, the mech's startup behaviour:

1. Serves `/.well-known/x402` as a static endpoint (lists payable routes)
2. Calls the x402scan registration API once:

```
POST https://x402scan.com/api/x402/registry/register-origin
Body: { "origin": "https://<mech-host>" }
```

x402scan crawls the `/.well-known/x402` endpoint, discovers the payable routes, and indexes them. No manual steps needed — every mech that starts up is automatically discoverable.

### Getting on x402scan — Auto-Discovery

x402scan supports auto-discovery via two methods ([discovery spec](https://www.x402scan.com/discovery)). The mech must serve one of these alongside its x402 request endpoint:

**Method 1 — `/.well-known/x402` (simple, recommended):**

The mech serves a static JSON at `/.well-known/x402` listing its payable routes:

```json
GET https://<mech-host>/.well-known/x402

{
  "version": 1,
  "resources": ["POST /x402/request"]
}
```

**Method 2 — OpenAPI spec (richer metadata):**

The mech serves `/openapi.json` with `x-payment-info` on each payable route:

```json
{
  "openapi": "3.0.0",
  "info": {
    "title": "Olas Mech",
    "version": "1.0.0",
    "guidance": "AI tool execution service. Send a POST with tool name and prompt to execute."
  },
  "paths": {
    "/x402/request": {
      "post": {
        "summary": "AI tool execution via Olas mech",
        "x-payment-info": {
          "protocols": ["x402"],
          "pricingMode": "fixed",
          "price": "0.01"
        },
        "responses": {
          "402": { "description": "Payment Required" }
        },
        "requestBody": {
          "content": {
            "application/json": {
              "schema": {
                "type": "object",
                "properties": {
                  "tool": { "type": "string", "description": "Tool name to execute" },
                  "prompt": { "type": "string", "description": "Input prompt" }
                },
                "required": ["tool", "prompt"]
              }
            }
          }
        }
      }
    }
  }
}
```

OpenAPI gives x402scan (and AI agents) richer context — input schema, pricing mode, descriptions — which improves discoverability. The `/.well-known/x402` method is simpler but only lists routes without metadata.

**Registering with x402scan:**

Once the mech serves a discovery endpoint, register the origin:

```
POST https://x402scan.com/api/x402/registry/register-origin
Body: { "origin": "https://<mech-host>" }
```

Or validate locally first using the x402scan CLI:

```bash
npx -y @agentcash/discovery@latest discover "https://<mech-host>"
```

This crawls the mech's discovery endpoint and shows all detected routes with pricing — same as what x402scan will see.

This works for **any chain** including Gnosis, because x402scan validates the discovery response schema, not the chain.

### Coexisting with off-chain (non-x402) requests

The mech's `/predict` endpoint serves **both** x402 clients and existing off-chain clients. The behaviour routes based on the `X-Payment` header:

| Request has... | Flow |
|---------------|------|
| `X-Payment` header | x402 — verify signature in-process → execute → HTTP 200 |
| No headers, no `delivery_rate` | x402 quote — return HTTP 402 |
| `delivery_rate` in body | Existing off-chain flow (unchanged) |
| On-chain event | Existing on-chain flow (unchanged) |

Off-chain requests (with `delivery_rate` in body, no EIP-3009 signature) bypass x402 entirely — the behaviour handles them via the existing code path. No changes needed to the off-chain flow.

---

## Option B — External Facilitator for Bazaar Visibility (Base/Polygon)

Layer an external facilitator on top of Option A for chains where one exists. This adds Bazaar programmatic discoverability — AI agents querying `/discovery/resources` can find the mech automatically.

### How to integrate an external facilitator

The behaviour makes **direct HTTP calls** to the facilitator's `/verify` endpoint.

```
Behaviour receives request with X-Payment header
    ↓
Decode PaymentPayload from X-Payment header
    ↓
POST to facilitator /verify endpoint
    (e.g. https://api.cdp.coinbase.com/platform/v2/x402/verify)
    Body: { paymentPayload, paymentRequirements }
    ↓
Facilitator returns { valid: true/false }
    ↓
If valid: execute tool, queue paymentData for batch settlement
If invalid: return HTTP 402
    ↓
DO NOT call facilitator /settle — we settle ourselves
    via deliverMarketplaceWithSignatures
```

The key insight: we call `/verify` but **never** call `/settle`. The facilitator's `/settle` would call `USDC.transferWithAuthorization` directly on-chain. USDC would arrive at our `BalanceTrackerX402USDC`, but `mapRequesterBalances` would NOT be updated — tokens arrived but no accounting record of who sent them or for which request. Settlement must go through `deliverMarketplaceWithSignatures` → `_adjustInitialBalance`, which updates all accounting atomically.

Since we only call `/verify` (not `/settle`), there's no settlement conflict. The facilitator still indexes the mech based on verification traffic, so Bazaar visibility is unaffected.

The behaviour just needs one outbound HTTP call to the facilitator. The routing:

```python
# Inside the behaviour's request handling (pseudocode)

if has_x_payment_header(request):
    payload = decode_payment_payload(request.headers["X-Payment"])

    if facilitator_url:  # Option B — external facilitator
        # POST to facilitator /verify
        verify_response = yield from self.get_http_response(
            method="POST",
            url=f"{facilitator_url}/verify",
            content=json.dumps({
                "paymentPayload": payload,
                "paymentRequirements": self.payment_requirements,
            }),
        )
        is_valid = verify_response["valid"]
    else:  # Option A — self-facilitate
        # Verify signature locally using eth_account
        is_valid = self._verify_eip3009_signature(payload)

    if is_valid:
        # Execute tool, queue for batch settlement
        ...
```

### Per-chain config

```python
# In the behaviour's params or skill.yaml
FACILITATOR_CONFIG = {
    "eip155:8453": "https://api.cdp.coinbase.com/platform/v2/x402",  # Base
    "eip155:137": "https://facilitator.payai.network",                # Polygon
    "eip155:100": None,  # Gnosis — self-facilitate
}
```

When `facilitator_url` is `None`, the behaviour falls back to local signature verification (Option A).

### Cost and limits of external facilitators

**Coinbase facilitator:**
- **Free tier:** 1,000 transactions/month
- **After that:** $0.001 per transaction
- Supports: Base, Polygon, Solana — via EIP-3009 (USDC, EURC) or Permit2 (any ERC-20)
- No API key needed

**PayAI facilitator:**
- Pricing/limits not publicly documented
- Supports: Base, Polygon, Avalanche, Sei, IoTeX, SKALE, Solana
- No API key needed


---

## Comparison

| | Option A (Self-Facilitate) | Option B (External Facilitator) |
|-|--------------------------|-------------------------------|
| **Base** | Manual x402scan registration | Auto-indexed in Bazaar |
| **Polygon** | Manual x402scan registration | Auto-indexed in Bazaar |
| **Gnosis** | Manual x402scan registration | Same (no facilitator exists) |
| **Bazaar discovery** | No | Yes (Base, Polygon) |
| **AI agent discoverability** | Low — x402scan website only | High — agents query Bazaar programmatically |
| **Cost** | Free | Free for 1k/mo, then $0.001/tx |
| **External dependency** | None | Facilitator uptime (for verification only) |
| **Implementation effort** | Local EIP-3009 signature check in behaviour | Same + outbound HTTP POST to facilitator `/verify` |
| **Off-chain coexistence** | Route on `X-Payment` header | Same |
| **open-autonomy compatible?** | Yes — all logic inside behaviour | Yes — just an outbound HTTP call |

**Recommendation:** Start with Option A (works everywhere, no dependencies). Layer Option B on Base later if Bazaar discoverability becomes important. Polygon's x402 ecosystem is nearly empty so the PayAI facilitator doesn't add much value today.

---

## Implementation Checklist

- [ ] Ensure `/predict` returns valid HTTP 402 response when no `X-Payment` header present
- [ ] Route requests in behaviour: `X-Payment` header → x402 flow, `delivery_rate` in body → off-chain flow, neither → 402 quote
- [ ] Use CAIP-2 network identifiers (`eip155:8453`, not `"base"`) in 402 response bodies
- [ ] Register mech endpoints on [x402scan.com/resources/register](https://www.x402scan.com/resources/register)
- [ ] (Optional, Base only) Add outbound `/verify` call to Coinbase facilitator in behaviour

### 402 response body (must be valid on all chains)

```json
{
  "x402Version": 2,
  "accepts": [{
    "scheme": "exact",
    "network": "eip155:8453",
    "maxAmountRequired": "10200",
    "payTo": "0xBalanceTrackerX402USDC",
    "asset": "0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913",
    "maxTimeoutSeconds": 900,
    "description": "AI tool execution via Olas mech",
    "mimeType": "application/json",
    "extra": { "name": "USD Coin", "version": "2" }
  }],
  "error": "Payment required"
}
```

The `network`, `asset` (USDC address), and `payTo` (BalanceTrackerX402USDC address) change per chain. Everything else is the same.

### Bazaar metadata (Option B only — for Base and Polygon)

When using an external facilitator, add Bazaar metadata to the 402 response for richer listings:

```json
{
  "x402Version": 2,
  "accepts": [{
    "scheme": "exact",
    "network": "eip155:8453",
    "maxAmountRequired": "10200",
    "payTo": "0xBalanceTrackerX402USDC",
    "asset": "0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913",
    "maxTimeoutSeconds": 900,
    "description": "AI tool execution via Olas mech",
    "mimeType": "application/json",
    "extra": { "name": "USD Coin", "version": "2" },
    "outputSchema": {
      "input": {
        "discoverable": true,
        "method": "POST",
        "type": "http",
        "bodyFields": {
          "tool": { "type": "string", "description": "Tool name to execute" },
          "prompt": { "type": "string", "description": "Input prompt" }
        },
        "bodyType": "json"
      },
      "output": {
        "type": "json",
        "example": { "result": "...", "requestId": "0x..." }
      }
    }
  }],
  "error": "Payment required"
}
```

---

## Appendix: MPP (Machine Payments Protocol) — How It Compares

### What is MPP?

MPP is an open protocol for machine-to-machine payments built by [Tempo](https://tempo.xyz) (Stripe-backed). Like x402, it uses HTTP 402 to signal "pay me first." Unlike x402, it supports multiple payment rails (crypto, cards, Lightning) and has a **session** mode that avoids per-request on-chain settlement.

MPP's challenge / credential / receipt framework is on the [IETF standards track](https://datatracker.ietf.org/doc/draft-ryan-httpauth-payment/) ("Payment HTTP Authentication Scheme"). Its ecosystem explorer is [MPPscan](https://www.mppscan.com/) (~419 servers as of writing, multi-chain via OpenAPI self-registration). MPPscan is operated by Merit Systems, the same outfit that runs x402scan. Note that the MPP EVM payment method standardizes the charge intent only; session intent is standardized for Tempo and Stellar.

### How MPP works

MPP uses three primitives in a single request-response cycle:

1. **Challenge** — server returns HTTP 402 with `WWW-Authenticate: Payment` header specifying what to pay
2. **Credential** — client fulfils payment, retries with `Payment-Credential` header containing proof
3. **Receipt** — server returns the resource with `Payment-Receipt` header confirming settlement

Two billing modes:

**Charge** (same as x402): one on-chain transaction per request. Client signs payment, server settles on-chain, returns result.

**Session** (unique to MPP): client opens a payment channel by depositing escrow on-chain (1 tx). Each subsequent request is just an off-chain signed voucher — no blockchain involved. The server periodically settles accumulated vouchers on-chain. When done, the client closes the channel and reclaims unspent funds.

```
Session example — 100 API calls at $0.01 each:

  Open channel:  Client deposits $2 on-chain        → 1 tx
  Requests 1-50: Client signs off-chain vouchers     → 0 tx
  Settle:        Server submits voucher for $0.50     → 1 tx
  Requests 51-100: More off-chain vouchers            → 0 tx
  Close channel: Client gets $1.00 change back        → 1 tx

  Total: 3 on-chain txns instead of 100
```

### MPP vs x402 vs Olas Marketplace

| | **Olas Marketplace** | **x402** | **MPP** |
|---|---|---|---|
| **What it is** | On-chain marketplace for AI mech services — manages request lifecycle, payment, delivery, and reputation | Open protocol for paying APIs via HTTP 402 | Open protocol for machine-to-machine payments via HTTP 402 |
| **Built by** | Valory / Olas | Coinbase | Tempo (Stripe-backed) |
| **Payment flow** | Request → assign mech → deliver → settle (on-chain lifecycle) | 402 → client signs `X-Payment` → facilitator verifies/settles | 402 with `WWW-Authenticate` → client sends `Payment-Credential` → server returns `Payment-Receipt` |
| **Payment methods** | Native ETH, ERC-20, Nevermined subscriptions, x402 (planned) | EIP-3009 USDC, Permit2 (any ERC-20) — crypto only | Stablecoins (Tempo), Lightning (Bitcoin), Stripe (cards), Visa tokens — extensible |
| **Chains** | Base, Polygon, Gnosis, Ethereum, Arbitrum, Celo, Optimism (7+ EVM) | Base, Polygon, Solana, Avalanche, Sei (via facilitators) | Tempo chain (42431) primarily. Lightning for Bitcoin. Cards for fiat. |
| **Settlement** | On-chain via `deliverMarketplaceWithSignatures`. Batching supported. | Facilitator settles on-chain. 1 tx per request. No batching. | Charge: 1 tx per request. Session: off-chain vouchers, periodic settlement. |
| **Batching / sessions** | Batching supported (1 tx for N deliveries) | No batching | Sessions: off-chain vouchers, near-zero per-request cost |
| **Gas cost for 100 requests** | ~1-5 txns (batched) | ~100 txns | Charge: ~100 txns. Session: ~3 txns |
| **Reputation** | On-chain Karma contract — per-mech, per-requester scores | None | None |
| **Delivery verification** | On-chain — mech must provide `deliveryData` to get paid | None — trust-based | Receipt header confirms payment, not delivery quality |
| **Streaming / metered billing** | Not supported | Not supported | Yes — session intent with payment channels |
| **Non-crypto payments** | No | No | Yes — Stripe, Visa, Lightning |
| **MCP integration** | No | Yes (via middleware) | Yes — native JSON-RPC binding for agent tool calls |
| **Discovery** | On-chain mech registry (Olas service IDs) | Bazaar + x402scan (~14k services) | MPPscan (~419 servers, multi-chain via OpenAPI self-registration) |
| **Standardization** | Proprietary smart contracts | Informal Coinbase spec | IETF-track framework; session intent standardized only on Tempo and Stellar (EVM session is a Valory extension if we deploy it) |
| **Ecosystem size** | ~100 mechs across chains | ~14k services (Base-heavy) | ~419 servers |
| **Fiat support** | No | No | Yes |

### What's relevant for Olas mechs

**MPP sessions are the interesting part** — for high-frequency mech interactions (monitoring tasks, streaming, repeated queries), off-chain vouchers with periodic settlement would drastically reduce gas costs compared to x402's per-request settlement.

**But sessions only work on Tempo chain.** They require Tempo's payment channel infrastructure. They cannot be used on Gnosis, Polygon, or Base without building custom state channel contracts — which is significant engineering (new escrow contracts, dispute resolution, timeout handling, integration with MechMarketplace).

**MPP charge mode offers no advantage over x402** — it's the same pay-per-request model, just with different HTTP headers and a smaller ecosystem.

**Olas's unique advantage remains the full lifecycle** — karma reputation, on-chain delivery proof (mech must provide `deliveryData` to get paid), marketplace-managed assignment, and batch settlement. Neither x402 nor MPP provide any of these. They're pure payment protocols; Olas is a marketplace with payment as one component.

**Practical recommendation:** x402 on Base is where the volume is today (14k+ services). MPP is worth watching — the IETF backing, multi-rail payments, and session mode are genuinely differentiated — but the ecosystem is too small and Tempo-chain-centric to adopt now. If MPP adds EVM payment methods (Gnosis, Polygon, Base), that changes the calculus.

### Sources

- [MPP Protocol Specification](https://mpp.dev/) — full technical spec (challenge/credential/receipt, payment methods, session intent)
- [MPPscan](https://www.mppscan.com/) — ecosystem explorer for MPP servers and transactions
- [Tempo](https://tempo.xyz/) — the Stripe-backed blockchain MPP runs on
- [Tempo Documentation](https://tempoxyz-tempo.mintlify.app/) — chain details, TIP-20 token standard, SDK references
- [IETF Draft: Payment HTTP Authentication Scheme](https://datatracker.ietf.org/doc/draft-ryan-httpauth-payment/) — MPP's IETF standards track submission
- [x402 Documentation](https://docs.x402.org/) — x402 protocol spec, facilitator docs, Bazaar discovery
- [x402scan](https://www.x402scan.com/) — ecosystem explorer for x402 services
- [x402scan Discovery Spec](https://www.x402scan.com/discovery) — auto-discovery requirements (OpenAPI, `/.well-known/x402`)

---

## Summary

| Question | Answer |
|----------|--------|
| How does the mech verify x402 payments? | Option A: local EIP-3009 signature check using `eth_account` + genai x402 types. Option B: outbound HTTP POST to facilitator `/verify`. |
| Do we need to host any facilitator? | No. Option A verifies in-process. Option B calls public facilitators. |
| Is the external facilitator free? | 1,000 verifications/month free, then $0.001/tx |
| Can we self-facilitate and still appear on x402scan? | Yes — via [direct registration](https://www.x402scan.com/resources/register), works on any chain 
| What about existing off-chain requests? | Same endpoint — route on `X-Payment` header in behaviour. No header = existing flow unchanged. |
| Which option for Gnosis? | Option A only (no public facilitator exists) |
| Which option for Base? | Option A for now, Option B later if Bazaar discoverability matters |
| Which option for Polygon? | Option A — PayAI supports it but the ecosystem is tiny |
| Smart contract changes? | No |
| Client SDK changes? | No |
