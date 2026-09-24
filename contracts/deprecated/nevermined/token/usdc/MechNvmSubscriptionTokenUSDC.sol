// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {OlasMech} from "../../../../OlasMech.sol";

/// @dev Provided zero subscription address.
error ZeroAddress();

/// @dev Provided zero value.
error ZeroValue();

/// @title MechNvmSubscriptionTokenUSDC - Smart contract for extending OlasMech with Nevermided USDC subscription based on native token
/// @dev A Mech that is operated by the holder of an ERC721 non-fungible token via a Nevermided USDC subscription.
contract MechNvmSubscriptionTokenUSDC is OlasMech {
    event RequestRateFinalized(bytes32 indexed requestId, uint256 deliveryRate);

    // keccak256(NvmSubscriptionTokenUSDC) = 0d6fd99afa9c4c580fab5e341922c2a5c4b61d880da60506193d7bf88944dd14
    bytes32 public constant PAYMENT_TYPE = 0x0d6fd99afa9c4c580fab5e341922c2a5c4b61d880da60506193d7bf88944dd14;

    /// @dev MechNvmSubscription constructor.
    /// @param _mechMarketplace Mech marketplace address.
    /// @param _serviceRegistry Address of the token contract.
    /// @param _serviceId Service Id.
    /// @param _maxDeliveryRate The maximum delivery rate.
    constructor(address _mechMarketplace, address _serviceRegistry, uint256 _serviceId, uint256 _maxDeliveryRate)
        OlasMech(_mechMarketplace, _serviceRegistry, _serviceId, _maxDeliveryRate, PAYMENT_TYPE)
    {}

    /// @dev Performs actions before the delivery of a request.
    /// @param requestId Request Id.
    /// @param data Self-descriptive opaque data-blob.
    /// @return requestData Data for the request processing.
    /// @return deliveryRate Corresponding finalized delivery rate.
    function _preDeliver(
        bytes32 requestId,
        bytes calldata data
    ) internal override returns (bytes memory requestData, uint256 deliveryRate) {
        // Extract the request deliver rate as credits to burn
        (deliveryRate, requestData) = abi.decode(data, (uint256, bytes));

        emit RequestRateFinalized(requestId, deliveryRate);
    }
}
