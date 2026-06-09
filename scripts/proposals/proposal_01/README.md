# Proposal 01 — MechMarketplace fee activation (15%)

Activates the universal MechMarketplace fee across all EVM mainnets where MechMarketplace is
deployed by calling `changeMarketplaceParams(1500, 60, 300)` on every `MechMarketplaceProxy`:

| # | Chain | MechMarketplaceProxy | Path |
|---|---|---|---|
| 0 | Ethereum (1) | `0x3d6494CE09a9f40c0B5a92BdBD7c7A9b0e3912b1` | direct (Timelock is `owner()`) |
| 1 | Gnosis (100) | `0x735FAAb1c4Ec41128c367AFb5c3baC73509f70bB` | AMB → HomeMediator (`0x15bd…1776`) |
| 2 | Polygon (137) | `0x343F2B005cF6D70bA610CD9F1F1927049414B582` | FxRoot → FxGovernorTunnel (`0x9338…755fD`) |
| 3 | Arbitrum (42161) | `0xf76953444C35F1FcE2F6CA1b167173357d3F5C17` | Inbox.createRetryableTicket → aliased Timelock (`0x4d30…A70F`) |
| 4 | Optimism (10) | `0x46C0D07F55d4F9B5Eed2Fc9680B5953e5fd7b461` | L1CDM → OptimismMessenger (`0x87c5…C60c`) |
| 5 | Base (8453) | `0xf24eE42edA0fc9b33B7D41B06Ee8ccD2Ef7C5020` | L1CDM → OptimismMessenger (`0xE49C…c8EA`) |
| 6 | Celo (42220) | `0x17d96ba4532fe91809326092fE4D5606A7B7a0d8` | L1CDM → OptimismMessenger (`0xC14E…ce04d`) |

Mode is intentionally excluded — no MechMarketplace is deployed on Mode.

`newFee = 1500` corresponds to **15%** given `MAX_FEE_FACTOR = 10_000` in
[`MechMarketplace.sol:88`](../../../contracts/MechMarketplace.sol). `minResponseTimeout = 60` and
`maxResponseTimeout = 300` echo the current live values unchanged (the setter overwrites all
three — re-asserting current values is mandatory).

Submitted via `propose()` on the GovernorOLAS currently holding the Timelock `PROPOSER` role
(post-proposal_11 this is the new GovernorOLAS at `0x060D0CBdDFb0498d610E2EF55C01516B5B1251E6`;
pre-proposal_11 it is `0x8E84B5055492901988B831817e4Ace5275A3b401`). Every call is executed by
the Timelock at `0x3C1fF68f5aa342D296d4DEe4Bb1cACCA912D95fE`.

**Pre-computed proposalId:**
`8871217640108518937207611538047255614811664982782591155744986646749332103486`
(verified equal to on-chain `GovernorOLAS.hashProposal(...)` against the active GovernorOLAS at
`0x8E84B5055492901988B831817e4Ace5275A3b401`).

## Files

| File | Purpose |
|---|---|
| `Proposal01FeeActivation.s.sol` | Forge builder — single source of truth for the 7 `(target, value, calldata)` entries and the `DESCRIPTION`. `forge script … :Proposal01FeeActivation` prints the arrays. |
| `description.txt` | Canonical proposal description (matches the builder's `DESCRIPTION` byte-for-byte; the proposalId is computed from it). |
| `calldata.json` | The builder's emitted `[{index,target,value,calldata}]`, used to generate the HTML. |
| `annotate.js` | Decodes `calldata.json` + `description.txt` → the annotated `proposal_01.html` (and computes the proposalId). |
| `proposal_01.html` | Self-contained annotated breakdown: copy-paste `propose()` arrays, decoded selectors/args/addresses, collapsible nested calls, raw calldata per entry, proposalId. |

## Regenerate (only if addresses/description/params change)

```bash
forge script scripts/proposals/proposal_01/Proposal01FeeActivation.s.sol:Proposal01FeeActivation > /tmp/run.txt
# re-extract calldata.json from the run output, then:
node scripts/proposals/proposal_01/annotate.js
```

## ⚠ Pre-execution requirement — Arbitrum retryable value

Entry **[3] Arbitrum** calls `Inbox.createRetryableTicket(...)`, which is `payable`. The required
value is `ARB_TICKET_VALUE = ARB_MAX_SUBMISSION_COST + ARB_GAS_LIMIT * ARB_MAX_FEE_PER_GAS`:

- `ARB_MAX_SUBMISSION_COST = 0.001 ETH`
- `ARB_GAS_LIMIT = 1_000_000`
- `ARB_MAX_FEE_PER_GAS = 0.1 gwei`
- **Total = 0.0011 ETH** (top to **0.005 ETH** for margin)

**Who supplies this ETH:** the **executor of `Governor.execute(...)`**, NOT the Timelock. OZ's
plumbing forwards `msg.value` executor → Governor → Timelock → target, so the Timelock holds the
ETH only for the duration of the batch and ends at its pre-execute balance. The Timelock does
**not** need to be pre-funded. Anyone calling `execute()` must attach at least `ARB_TICKET_VALUE`
as `msg.value` (the fork test `test_FullGovernanceLifecycle` asserts the Timelock balance is
unchanged across `execute()`).

Recompute `ARB_MAX_SUBMISSION_COST` closer to submission from
`Inbox.calculateRetryableSubmissionFee(data.length, basefee)` and adjust `ARB_MAX_FEE_PER_GAS`
to current Arbitrum baseFee × 2 if either has drifted.

This is the FIRST Olas Timelock-driven L1→L2 governance call on Arbitrum. The aliased Timelock
(`0x4d30…A70F` = `0x3C1f…95fE + 0x1111…1111`) is verified as `MechMarketplaceProxy.owner()` on
Arbitrum, so the retryable's `msg.sender` is recognised by the marketplace's `OwnerOnly` check.

## Generate calldata

```bash
forge script scripts/proposals/proposal_01/Proposal01FeeActivation.s.sol:Proposal01FeeActivation
```

## Testing

**L1 (Forge fork test):** [`test/proposals/Proposal01FeeActivation.t.sol`](../../../test/proposals/Proposal01FeeActivation.t.sol)
impersonates the Timelock against a mainnet fork and executes every call; it asserts the Ethereum
fee/timeouts on the live MechMarketplaceProxy and that all bridge entrypoints accept the call
without reverting (Gnosis/Polygon/Optimism/Base/Celo — `sendMessage` is non-payable; Arbitrum
`createRetryableTicket` is funded with `ARB_TICKET_VALUE` via `vm.deal`).

```bash
forge test --fork-url $MAINNET_RPC --match-contract Proposal01FeeActivation -vvv
```

**L2 (bridged) effects:** the `changeMarketplaceParams` write on Gnosis / Polygon / Arbitrum /
Optimism / Base / Celo lands on each destination chain and is **not** observable on a mainnet
fork. Validate per-chain via a Tenderly simulation on the destination L2 of the respective L2
messenger entrypoint with `msg.sender` set to the bridge gateway recognised by that messenger:

- **Gnosis:** `HomeMediator.processMessageFromForeign(<packed>)` with `msg.sender = AMB(L2)` and
  `messageSender() == Timelock`.
- **Polygon:** `FxGovernorTunnel.processMessageFromRoot(<id>, Timelock, <packed>)` with
  `msg.sender = FxChild(L2)`.
- **Arbitrum:** `MechMarketplaceProxy.changeMarketplaceParams(500, 60, 300)` with
  `msg.sender = aliased Timelock`.
- **Optimism / Base / Celo:** `OptimismMessenger.processMessageFromSource(<packed>)` with
  `msg.sender = L2CrossDomainMessenger` and `xDomainMessageSender() == Timelock`.

The exact packed `<packed>` payload is the decoded inner bytes shown by the builder script.
