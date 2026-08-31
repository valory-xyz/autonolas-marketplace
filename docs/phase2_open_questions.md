# Phase 2 workstream plan

Four workstreams for phase 2, ordered by priority. Each one has what's broken today, why it matters, and what we need to handle.

## 1. Security strengthening

### 1a. Users can get free predictions

The marketplace keeps a counter (called a "nonce") for each safe on chain. Every request the safe sends has to be signed with the current value of that counter. When a request settles, the counter goes up by one. This is what stops old requests from being replayed.

The problem: the client reads the counter and signs the request BEFORE the request has settled. So if a user prepares two requests at once (say, one to mech A and one to mech B), both requests get signed with the same counter value, because neither has settled yet. Both mechs do the work and send the answer back over HTTP. When each mech goes to settle on chain, only the first one succeeds. The counter bumps by one, and the second mech's signature — made against the old value — no longer matches. Its settlement fails.

Here's the catch: the second mech already gave the answer to the user over HTTP, BEFORE it tried to settle. So the user walks away with both answers but only pays for one. This isn't unique to the nonce race — any settlement failure (nonce, gas issue, whatever) has the same effect, because the mech releases the answer before it even tries to settle.

We need the mech to hold the answer until settlement is confirmed, and we need to fix the nonce scheme so two requests from the same safe don't collide.

### 1b. Funds aren't locked across requests

To use a mech, users deposit money into a balance tracker contract for that specific mech. The mech only actually checks the balance when it goes to settle on chain, not when it accepts the request.

So if a user has exactly enough for one request and fires two at once (to two different mechs), both mechs check the balance off chain, both see it's fine, both do the work. The first mech settles and drains the balance. The second mech tries to settle, sees the balance is now zero, and its settlement fails.

We need mechs to lock the funds when they accept the request, not at settlement. Then the second parallel request either gets rejected upfront or locks its own share.

### 1c. Mech URLs are open to floods

Each mech runs an HTTP server that anyone on the internet can hit. There's no rate limiting anywhere — no CDN in front, and no per-IP counter inside the mech.

The mech checks the signature to reject fake requests, but only AFTER it has parsed the request body. So the CPU cost of parsing is already paid before the mech rejects. Enough concurrent junk requests will pin the mech, and legitimate ones can't get through.

On top of that, each mech only has one URL on chain — there's no backup process to fall back to. So one flood knocks the mech offline entirely.

We need Cloudflare (or similar) in front of every mech URL to filter obvious junk, and a simple per-IP counter inside the mech that returns "too many" before doing any work.

### 1d. Anyone can read responses

When a request settles on chain, the marketplace emits an event that includes its request_id. So request_ids are public — anyone indexing the marketplace subgraph gets the full list. If you have a request_id, you can hit the mech's HTTP endpoint (`/fetch_offchain_info`) and get the answer back with no auth check. We need to add an auth layer, so only the sender of the request can read it.

The mech holds responses in memory (a python dict in the running process), so they stay readable for as long as the mech process is up. A restart or redeploy wipes them, so realistically it's anywhere from hours to weeks depending on the deployment.

The same request_id also works on predict-api's `/predict/{request_id}` and mech-analytics's `/v1/data/scored-rows`. Mech-analytics is deliberately public per the scope doc we wrote — the design was public + Cloudflare in front.

We need to decide for mech-analytics, whether we keep it public as originally designed or tighten it now that we see it exposes the same content the off-chain rail was supposed to keep private.

## 2. x402 unification

We charge some external services like CoinGecko per API call using x402 (a standard where the server returns HTTP 402 with a payment challenge and the client pays inline before getting the response). Optimus and traders pay for x402 requests, directly from their own wallets. None of that spending goes through the marketplace.

The marketplace works differently: you deposit up front and get billed in batches when requests settle. x402 is pay-per-request. They're not naturally the same shape.

We need to decide if we want everything an agent spends to go through the marketplace (so we have one place that tracks all agent spending), which means wrapping every x402 call inside a mech tool. Or we accept two separate payment paths.

## 3. Withdrawing pre-deposited balance from marketplace

To use a mech, users deposit money into a balance tracker contract tied to that specific mech. The money can only leave when they spend it on requests to the mech.

There is no withdraw function on the contract. No way to pull money back out.

We need a withdraw function, and to figure out the rules — can they withdraw immediately, is there a delay, what happens when a request is in flight.

## 4. Dynamic pricing

Right now, price is set per mech, not per tool. A mech has one flat "delivery rate" that applies to every tool it hosts.

So superforcaster (which makes several GPT-4 calls) charges the user the same as a simple pass-through tool.

We need per-request pricing: the mech figures out the actual cost of the specific tool call and sends the quote back to the user, and the user signs against that quote before the request runs. We already have docs on how to shape this, so pick those up rather than re-scoping from scratch.
