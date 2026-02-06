// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import {BalanceTrackerFixedPriceNative} from "../BalanceTrackerFixedPriceNative.sol";

/// @title BalanceTrackerFixedPriceNativeCelo - celo specific smart contract for tracking marketplace native token balances
contract BalanceTrackerFixedPriceNativeCelo is BalanceTrackerFixedPriceNative {

    /// @dev BalanceTrackerFixedPriceNativeCelo constructor.
    /// @param _mechMarketplace Mech marketplace address.
    /// @param _drainer Drainer address.
    /// @param _wrappedNativeToken Wrapped native token address.
    constructor(address _mechMarketplace, address _drainer, address _wrappedNativeToken)
        BalanceTrackerFixedPriceNative(_mechMarketplace, _drainer, _wrappedNativeToken)
    {}

    /// @dev Wraps native token.
    function _wrap(uint256) internal override {}
}