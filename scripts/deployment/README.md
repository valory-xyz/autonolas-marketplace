# Deployment scripts

This folder contains the scripts to deploy the contracts.

## Observations
- Shell scripts read `scripts/deployment/globals_<network>.json` directly. Historical Hardhat scripts read a separate root-level `globals.json`; do not mix the two configurations.
- Please note: if you encounter the `Unknown Error 0x6b0c`, then it is likely because the ledger is not connected or logged in.

## Steps to engage
The project has submodules to get the dependencies. Make sure you run `git clone --recursive` or init the submodules yourself.
The dependency list is managed by the `package.json` file, and the setup parameters are stored in the `hardhat.config.js` file.
Simply run the following command to install the project:
```
yarn install
```
command and compiled with the
```
npx hardhat compile
```

Create a `globals.json` file in the root folder, or copy it from the file with pre-defined parameters (i.e., `scripts/deployment/globals_gnosis_mainnet.json` for the gnosis mainnet network).

Parameters of the `globals.json` file:
- `contractVerification`: a flag for verifying contracts in deployment scripts (`true`) or skipping it (`false`);
- `useLedger`: a flag whether to use the hardware wallet (`true`) or proceed with the seed-phrase accounts (`false`);
- `derivationPath`: a string with the derivation path;
- `providerName`: a network type (see `hardhat.config.js` for the network configurations);
- `networkURL`: string with the network RPC URL;
- `gasPriceInGwei`: gas price in Gwei;
- `agentType`: a mech factory type: `default` or `subscription`.

## Phase 2 upgrade of an existing Marketplace

Use a reviewed checkout with initialized submodules, compiled contracts, Foundry (`forge`, `cast`),
`jq` and Python 3. Compilation uses Solidity 0.8.30 and the checkout's `foundry.toml`.
`FOUNDRY_SOLC` may point to a local 0.8.30 compiler. Use the CI-pinned Foundry release.

This procedure retains the existing proxy, initialization state, trackers and balances. It does not
cover fresh-proxy or tracker deployment. Record the current implementation, factories, tracker
mappings, owner and legacy domain separator before starting; preserve a copy of the configuration.
Review the RPC chain ID, registry, Karma and asset addresses against the intended network.

The deployment signer deploys the
implementation and factories; governance executes the proxy upgrade and factory registration.

1. Deploy the new implementation with `deploy_03_mech_marketplace.sh <network>`. The script checks
   its receipt, runtime bytecode against the current build, version, registry, Karma and constructor
   chain ID before saving the address.
2. Deploy a new factory for each approved payment type using `deploy_05_mech_factory_fixed_price_native.sh`,
   `deploy_07a_mech_factory_fixed_price_token_olas.sh` and/or `deploy_07b_mech_factory_fixed_price_token_usdc.sh`,
   each with `<network>`. Factories embed mech bytecode, so upgrading Marketplace alone does not
   update the mechs they create. Existing deployed mechs are unchanged. Run the candidate audits below
   after deployment and before submitting governance; require successful explorer verification when configured.
3. Use the network's governance procedure to execute `changeImplementation(newImplementation)`
   on the existing proxy. Before execution, run the read-only implementation check below against
   the exact address in the proposal. After execution, confirm the implementation, version, retained governance
   owner and retained legacy domain separator. Run the explicit-nonce domain check below before continuing.
4. Use governance to execute `setMechFactoryStatuses(selectedFactories, statuses)` on the proxy,
   enabling only the approved new factory types. Before execution, verify current factory bytecode,
   proxy/asset bindings and existing tracker mappings. Missing mappings require a separately reviewed
   governance operation; do not replace trackers or move their balances as part of this upgrade.
5. Confirm factory statuses, unchanged tracker mappings, and that newly created mechs report version
   `1.1.0`. Validate signed delivery with the updated client before cutover. The explicit-nonce path
   uses a signed deadline and domain version `2`; the two older paths retain their legacy format.

For every governance operation, verify the chain, existing proxy target, zero value, arguments,
successful execution and the state readbacks above. Governance calldata preparation, proposal submission
and execution use the network's established process; no governance automation is provided here.
Include explicitly approved old-factory revocations in the governance payload when replacing factories;
the direct-owner registration helper only enables the selected factories.

From the reviewed checkout, run this check before submitting the proposal and again before execution:

```sh
MARKETPLACE_RPC_URL='<target network RPC URL>' python3 scripts/deployment/check_marketplace_implementation.py \
  --implementation '<implementation address in the proposal>' \
  --proxy '<existing Marketplace proxy address>' --chain-id '<target chain ID>'
```

This command builds the current source, compares implementation runtime bytecode outside compiler-listed
immutable slots, and checks version `1.2.0`, registry and Karma against the proxy, and constructor chain ID
against the target network. It requires no wallet and sends no transactions. A mismatch stops the check.
The deployment and direct-owner upgrade scripts use the same checker.

### Read-only candidate and activation audits

The chain audit also accepts new implementation/native/USDC factory addresses directly from globals,
independently of the active addresses in `docs/configuration.json`. Use artifacts from the reviewed build
used to deploy those addresses (Forge or Hardhat format). Keep the previous factory addresses recorded above.
From the repository root, for example:

```sh
export MARKETPLACE_RPC_URL='<target network RPC URL>'
node scripts/audit_chains/audit_contracts_setup.js --candidate MechMarketplace \
  --globals scripts/deployment/globals_eth_mainnet.json --artifact out/MechMarketplace.sol/MechMarketplace.json
node scripts/audit_chains/audit_contracts_setup.js --candidate MechFactoryFixedPriceNative \
  --globals scripts/deployment/globals_eth_mainnet.json --artifact out/MechFactoryFixedPriceNative.sol/MechFactoryFixedPriceNative.json \
  --previous-factory '<previous native factory address>'
node scripts/audit_chains/audit_contracts_setup.js --candidate MechFactoryFixedPriceTokenUSDC \
  --globals scripts/deployment/globals_eth_mainnet.json --artifact out/MechFactoryFixedPriceTokenUSDC.sol/MechFactoryFixedPriceTokenUSDC.json \
  --previous-factory '<previous USDC factory address>'
```

Substitute the network's globals file and run only the selected factory types. These commands send no
transactions. They compare full runtime bytecode, constructor bindings and implementation version/chain ID
at one recorded block per invocation. Invalid inputs or the wrong RPC chain stop early; other failed or
unreadable checks are reported on separate lines, followed by a nonzero exit after all checks run.

| Check | What we will see before governance | Expected (after governance) |
|---|---|---|
| Proxy implementation / version | Old address / `1.1.0`: reported as mismatches against the new address / `1.2.0` | New address / `1.2.0` |
| Replacement factory permissions | New `false`, previous `true` | New `true`, previous `false` |

Before governance, only those proxy implementation/version differences are expected in the candidate
audit; all candidate code/binding checks must pass. After governance, repeat the implementation command
and add `--activated` to each factory command to check the reversed permissions. The flag performs no
activation. Missing or identical previous-factory addresses are rejected.

Continue running the existing chain state audit (`node scripts/audit_chains/audit_contracts_setup.js`)
for owners, settings, Karma authorization and tracker/drainer bindings. Its factory checks expect the new
factories in globals to be enabled, so they report differences before governance. Retain the applicable
OLAS-disabled policy. Candidate audits supplement these existing state checks.

After the governance upgrade, check the new explicit-nonce domain on the existing proxy:

```sh
MARKETPLACE_RPC_URL='<target network RPC URL>' node scripts/deployment/check_marketplace_domain.js \
  '<existing Marketplace proxy address>' '<target chain ID>'
```

This read-only command compares `getDomainSeparatorWithNonce()` with ethers' standard EIP-712 domain
hash for name `MechMarketplace`, signing version `2`, the target chain ID and the existing proxy address.
It checks the RPC chain ID and requires no signing wallet. Stop the rollout if the command fails.
This is a separate check from preserving the legacy domain separator.

`script_06_change_implementaion_mech_marketplace_proxy.sh` and
`script_02a_marketplace_set_factories_fixed.sh <network> native olas` (example selection) are direct-owner
tools. They send transactions only when the selected signer is the Marketplace owner; they do not
generate governance calldata or provide a read-only preflight mode. Do not use them as deployment-signer
commands. They remain available for directly owned
environments and the local rehearsal.

Scripts return an error on failure. A timeout may occur after a transaction mined: stop and inspect
the transaction hash, wallet transactions and actual chain state before retrying. There is no automatic
retry or recovery. A confirmed deployment is saved atomically before explorer verification; if only
verification fails, verify the saved address separately rather than deploying again. Apply the network's
finality policy before cutover. Scripts do not roll back mined transactions.

Do not run every numbered deployment script in sequence for an upgrade. Other scripts in this directory,
including fresh-proxy, tracker, subscription and legacy registration tools, are outside this procedure.

## Local validation

```sh
python3 -B -m unittest discover -s test/deployment -p 'test_*.py' -v
node scripts/deployment/test/Phase2Upgrade.js
```

The first command uses isolated fake tools to check failure handling without RPC access. The second
uses actual scripts, Foundry and a temporary Anvil chain to rehearse the upgrade and settlement with
existing trackers. Neither uses live funds. Ledger signing, production governance, explorer verification
and live network configuration still require deployment-time checks.
