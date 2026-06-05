# Governance proposals

Index of on-chain governance proposals prepared for the MechMarketplace stack.

Each proposal lives in its own `proposal_<N>/` subfolder containing:
- the calldata builder (Forge script),
- a `description.txt` (the exact on-chain proposal description),
- a `README.md` describing the proposal.

Every proposal description must contain the sentence:
> In accordance with Autonolas DAO Constitution at ipfs://bafybeibrhz6hnxsxcbv7dkzerq4chssotexb276pidzwclbytzj7m4t47u

L1 effects are validated by Forge fork tests under [`test/proposals/`](../../test/proposals). L2 (bridged)
effects are validated separately via Tenderly simulations on the destination chain.

Proposals are submitted on Ethereum L1 via `propose()` on the GovernorOLAS that currently holds the
Timelock `PROPOSER` role (post-proposal_11 in `autonolas-governance` this is the new GovernorOLAS at
`0x060D0CBdDFb0498d610E2EF55C01516B5B1251E6`). Every call is executed by the Timelock at
`0x3C1fF68f5aa342D296d4DEe4Bb1cACCA912D95fE`.

## Proposals

| # | Summary | Folder | Annotated HTML | Fork test (L1) |
|---|---------|--------|----------------|----------------|
| 01 | MechMarketplace fee activation — switch `fee` from 0 to 15% (`newFee = 1500`) across all EVM mainnets except Mode (Ethereum direct + Gnosis / Polygon / Arbitrum / Optimism / Base / Celo via their respective L1→L2 bridges) | [proposal_01/](proposal_01) | [proposal_01.html](proposal_01/proposal_01.html) | [Proposal01FeeActivation.t.sol](../../test/proposals/Proposal01FeeActivation.t.sol) |
