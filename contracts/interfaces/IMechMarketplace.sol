// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {DeliverWithSignature} from "../OlasMech.sol";

/// @dev Mech Marketplace interface
interface IMechMarketplace {
    /// @dev Delivers requests.
    /// @notice This function can only be called by the mech delivering the request.
    /// @param requestIds Set of request ids.
    /// @param mechDeliveryRates Corresponding set of actual charged delivery rates for each request.
    /// @return deliveredRequests Corresponding set of successful / failed deliveries.
    function deliverMarketplace(bytes32[] calldata requestIds, uint256[] calldata mechDeliveryRates)
        external returns (bool[] memory deliveredRequests);

    /// @dev Delivers signed requests.
    /// @param requester Requester address.
    /// @param deliverWithSignatures Set of DeliverWithSignature structs.
    /// @param deliveryRates Corresponding set of actual charged delivery rates for each request.
    /// @param paymentData Additional payment-related request data, if applicable.
    function deliverMarketplaceWithSignatures(
        address requester, DeliverWithSignature[] calldata deliverWithSignatures, uint256[] calldata deliveryRates,
            bytes calldata paymentData) external;

    function deliverMarketplaceWithSignatures(
        address requester, DeliverWithSignature[] calldata deliverWithSignatures, uint256[] calldata deliveryRates,
            uint256[] calldata maxRates, bytes calldata paymentData) external;
}