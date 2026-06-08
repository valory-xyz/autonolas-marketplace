# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Common Changelog](https://common-changelog.org).

[0.4.2]: https://github.com/valory-xyz/autonolas-marketplace/compare/v0.4.1...v0.4.2
[0.4.1]: https://github.com/valory-xyz/autonolas-marketplace/compare/v0.3.1...v0.4.1
[0.3.1]: https://github.com/valory-xyz/autonolas-marketplace/compare/v0.2.1...v0.3.1
[0.2.1]: https://github.com/valory-xyz/autonolas-marketplace/compare/v0.1.0...v0.2.1
[0.1.0]: https://github.com/valory-xyz/autonolas-marketplace/releases/tag/v0.1.0


## [0.4.2] - 2026-05-25

- New USDC fixed-price contracts: `MechFactoryFixedPriceTokenUSDC` and `MechFixedPriceTokenUSDC` ([#140](https://github.com/valory-xyz/autonolas-marketplace/pull/140))
- New Celo-specific `BalanceTrackerFixedPriceNativeCelo` variant (CELO native is itself an ERC-20, so `_wrap()` is overridden to a no-op) ([#147](https://github.com/valory-xyz/autonolas-marketplace/pull/147))
- `BalanceTrackerNvmSubscriptionNative`: override `depositFor()` to revert with `NoDepositAllowed`, preventing direct native deposits that bypass the subscription model ([#129](https://github.com/valory-xyz/autonolas-marketplace/pull/129))
- Multi-chain deployment of `MechMarketplace`, `BalanceTracker`s, and factories across Polygon, Optimism, Arbitrum, Ethereum, Gnosis, and Celo ([#131](https://github.com/valory-xyz/autonolas-marketplace/pull/131), [#137](https://github.com/valory-xyz/autonolas-marketplace/pull/137), [#142](https://github.com/valory-xyz/autonolas-marketplace/pull/142), [#146](https://github.com/valory-xyz/autonolas-marketplace/pull/146), [#147](https://github.com/valory-xyz/autonolas-marketplace/pull/147))
- Ownership of `KarmaProxy` and `MechMarketplaceProxy` transferred to the DAO executor (timelock on mainnet, bridgeMediator on L2s) on all 7 chains
- Internal audit 7 and `docs/Vulnerabilities_marketplace.md` ([#151](https://github.com/valory-xyz/autonolas-marketplace/pull/151))
- `audit_contracts_setup.js` enhancements: `SubscriptionProvider` ownership coverage, Celo `BalanceTrackerFixedPriceNativeCelo` handling, public-RPC fallback ([#152](https://github.com/valory-xyz/autonolas-marketplace/pull/152))
- CI: aggregate "All checks passed" gate job
- Added `CONTRIBUTING.md`; license refresh

## [0.4.1] - 2024-03-14

- Development of extended configurable `MechMarketplace` with different `BalanceTracker` contracts: fixed and dynamic payments ([#109](https://github.com/valory-xyz/autonolas-marketplace/pull/109))

## [0.3.1] - 2024-08-28

- Development and deployment of initial `MechMarketplace` contract with obligatory staking requirements ([#41](https://github.com/valory-xyz/autonolas-marketplace/pull/41))

## [0.2.1] - 2024-03-24

- Updating `AgentFactory` accounting for updated `AgentMech` with requests counts ([#9](https://github.com/valory-xyz/autonolas-marketplace/pull/9))
- Deploying `AgentFactory` on Gnosis, Polygon, Arbitrum, Base, Celo, Optimism ([#30](https://github.com/valory-xyz/autonolas-marketplace/pull/30))

## [0.1.0] - 2023-05-12

- Development of `AgentFactory`, `AgentMech`, `AgentRegistry` contracts ([#6](https://github.com/valory-xyz/autonolas-marketplace/pull/6))