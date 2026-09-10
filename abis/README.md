# AI registry mech ABIs
0.8.19 ABIs were obtained with 750 optimization passes.
0.8.21 ABIs were obtained with 1000000 optimization passes.

## Artifacts must match the deployment, not a convention

`scripts/audit_chains/audit_contracts_setup.js` compares deployed bytecode against the artifact
`docs/configuration.json` names, so an artifact has to be built the way its contract was actually
deployed. Where a house convention and a deployment disagree, the deployment wins.

`abis/0.8.30-no-optimizer/SubscriptionProvider.json` exists for that reason. The Gnosis
(`0x4a2f40E1`) and Base (`0x5050c577`) subscription providers were deployed on 2025-06-18, and
`foundry.toml` did not carry `optimizer`/`optimizer_runs`/`evm_version` until the commit that
recorded that deployment added them. Both are therefore **unoptimized** builds at 4897 B. The
Optimism provider (`0x8Bb87107`, 2026-01-14) came after and matches the optimized
`abis/0.8.30/SubscriptionProvider.json` at 3406 B, from identical source.

## `deployed/`

The per-solc directories are keyed on compiler settings, which is enough while one build serves every
chain. It stops being enough once the same contract at the same solc version is deployed from two
different pipelines: hardhat and `forge create` embed different metadata IPFS hashes, because the
metadata document records source paths and remappings, so the trailing CBOR bytes differ even when
the source and the settings are identical.

`deployed/Robinhood*.json` are the forge artifacts for chain 4663. They are stored per-deployment
rather than per-solc because they are the build that produced that chain's bytecode, trailer
included — the `abis/0.8.30/` files match these contracts only on length. Nothing under
`abis/<solc>/` changed, and no other chain's audit is affected.
