# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project Overview

Autonolas Marketplace — Solidity smart contracts for a decentralized mech (AI agent) marketplace. Mechs register, requesters post jobs with payment, and services deliver responses. Supports multiple payment models (native currency, ERC20 tokens, Nevermined subscriptions) across 7+ EVM chains.

## Build & Development Commands

```bash
# Install (requires git clone --recursive for submodules)
yarn install

# Compile
npx hardhat compile

# Run all tests
npx hardhat test

# Run a single test file
npx hardhat test test/MechFixedPriceNative.js

# Run tests matching a pattern
npx hardhat test --grep "should deliver"

# Coverage
npx hardhat coverage

# Lint JS
./node_modules/.bin/eslint . --ext .js,.jsx,.ts,.tsx

# Lint Solidity (only core contracts and interfaces are linted in CI)
./node_modules/.bin/solhint contracts/interfaces/*.sol contracts/*.sol
```

## Architecture

### Contract Hierarchy

**MechMarketplace** is the central orchestrator (proxy-upgradeable). It manages:
- Request lifecycle (post → assign priority mech → deliver)
- Mech factory whitelisting and mech creation
- Payment type routing to BalanceTrackers
- Fee collection (basis points)
- Karma updates via the Karma contract
- EIP-712 signature validation for batch deliveries

**OlasMech** (abstract) extends Gnosis Mech base. Each mech is tied to an Olas service registry entry and verified via multisig operators. Tracks request/delivery counts and enforces max delivery rates.

**Three payment model branches**, each with their own Mech + Factory + BalanceTracker:

| Model | Mech | Factory | BalanceTracker |
|-------|------|---------|----------------|
| Fixed Price Native | `MechFixedPriceNative` | `MechFactoryFixedPriceNative` | `BalanceTrackerFixedPriceNative` |
| Fixed Price Token | `MechFixedPriceToken` | `MechFactoryFixedPriceToken` | `BalanceTrackerFixedPriceToken` |
| Nevermined Subscription | `MechNvmSubscription{Native,Token}` | `MechFactoryNvmSubscription{Native,Token}` | `BalanceTrackerNvmSubscription{Native,Token}` |

Chain-specific variants exist under `mechs/native/celo/`, `mechs/token/usdc/`, and `nevermined/token/usdc/`.

**x402 Payment (planned)** — a fourth payment model adding x402 protocol compatibility via EIP-3009 `transferWithAuthorization` for USDC. New contracts (`BalanceTrackerX402`, `MechFixedPriceTokenX402`, `MechFactoryFixedPriceTokenX402`) under `mechs/token/x402/`. Spec: `docs/x402_spec.md`. Implementation plan: `docs/x402_implementation_plan.md`. Key design: overrides `_adjustInitialBalance` in `BalanceTrackerBase` to decode EIP-3009 paymentData instead of using `transferFrom`. Zero changes to MechMarketplace or OlasMech.

**Karma** (proxy-upgradeable) — reputation system tracking per-mech and per-requester-mech karma scores. Only whitelisted marketplaces can update karma.

**KarmaProxy** — upgradeable proxy with initialization for the Karma contract.

### Key Patterns
- **Factory pattern**: MechFactoryBase uses salt-based deterministic deployment (CREATE2). Factories are marketplace-only access controlled.
- **Reentrancy protection**: `locked` state variable pattern in OlasMech and BalanceTrackerBase.
- **Payment flow**: Requesters deposit into BalanceTracker → requests go through Marketplace → delivery triggers balance adjustment → mechs withdraw from BalanceTracker. Fees drain to BuyBackBurner.

### External Dependencies (git submodules in `lib/`)
- `autonolas-registries` — Olas service registry contracts
- `gnosis-mech` — Gnosis Safe-based mech base contract that OlasMech extends

## Deployment

Step-by-step scripts in `scripts/deployment/` (deploy_01 through deploy_07+). Each step has a `.js` deployer and `.sh` wrapper. Chain-specific globals files configure addresses per network.

Deployed addresses: `docs/configuration.json`

## Conventions

- Solidity `^0.8.28` for most contracts, `0.8.30` for MechMarketplace (EVM target: Prague, optimizer: 1M runs)
- Custom errors (no string reverts) — defined in `IErrorsMarketplace.sol` and `IErrorsMech.sol`
- Conventional Commits: `feat:`, `fix:`, `chore:`, `docs:`, `refactor:`, `test:`, `perf:`
- Branch naming: `feat/<topic>`, `fix/<topic>`, `docs/<topic>`
- JS style: 4-space indent, double quotes, semicolons required, camelCase
- Tests are JS/Mocha in `test/`, mock contracts in `contracts/test/`
