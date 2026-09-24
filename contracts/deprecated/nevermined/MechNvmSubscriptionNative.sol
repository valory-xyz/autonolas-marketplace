// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {OlasMech} from "../../OlasMech.sol";

/// @dev Provided zero subscription address.
error ZeroAddress();

/// @dev Provided zero value.
error ZeroValue();

/// @title MechNvmSubscriptionNative - Smart contract for extending OlasMech with Nevermided subscription based on native token
/// @dev A Mech that is operated by the holder of an ERC721 non-fungible token via a Nevermided subscription.
contract MechNvmSubscriptionNative is OlasMech {
    event RequestRateFinalized(bytes32 indexed requestId, uint256 deliveryRate);

    // keccak256(NvmSubscriptionNative) = 803dd08fe79d91027fc9024e254a0942372b92f3ccabc1bd19f4a5c2b251c316
    bytes32 public constant PAYMENT_TYPE = 0x803dd08fe79d91027fc9024e254a0942372b92f3ccabc1bd19f4a5c2b251c316;

    /// @dev MechNvmSubscription constructor.
    /// @param _mechMarketplace Mech marketplace address.
    /// @param _serviceRegistry Address of the token contract.
    /// @param _serviceId Service Id.
    /// @param _maxDeliveryRate The maximum delivery rate.
    constructor(address _mechMarketplace, address _serviceRegistry, uint256 _serviceId,uint256 _maxDeliveryRate)
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
