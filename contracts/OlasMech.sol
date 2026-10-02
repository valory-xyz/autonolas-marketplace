// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {IErrorsMech} from "./interfaces/IErrorsMech.sol";
import {IMechMarketplace} from "./interfaces/IMechMarketplace.sol";
import {IServiceRegistry} from "./interfaces/IServiceRegistry.sol";
import {Mech} from "../lib/gnosis-mech/contracts/base/Mech.sol";

// DeliverWithSignature struct
struct DeliverWithSignature {
    // Self-descriptive opaque request data-blobs
    bytes requestData;
    // Signature for requested data
    bytes signature;
    // Self-descriptive opaque delivery data-blobs
    bytes deliveryData;
}

/// @dev A Mech that is operated by the multisig of an Olas service
/// @author Aleksandr Kuperman - <aleksandr.kuperman@valory.xyz>
/// @author Andrey Lebedev - <andrey.lebedev@valory.xyz>
/// @author Mariapia Moscatiello - <mariapia.moscatiello@valory.xyz>
abstract contract OlasMech is Mech, IErrorsMech {
    event MaxDeliveryRateUpdated(uint256 maxDeliveryRate);
    event Deliver(address indexed mech, address indexed mechServiceMultisig, bytes32 requestId, uint256 deliveryRate,
        bytes data);
    event Request(address indexed mech, bytes32 requestId, bytes data);
    event RevokeRequest(bytes32 requestId);
    event NumRequestsIncrease(uint256 numRequests);

    // Olas mech version number
    string public constant VERSION = "1.0.0";
    // Mech marketplace address
    address public immutable mechMarketplace;
    // Service Registry address
    address public immutable serviceRegistry;
    // Service Id
    uint256 public immutable serviceId;
    // Mech payment type
    bytes32 public immutable paymentType;

    // Maximum required delivery rate
    uint256 public maxDeliveryRate;
    // Number of undelivered requests by this mech
    uint256 public numUndeliveredRequests;
    // Number of total requests by this mech
    uint256 public numTotalRequests;
    // Number of total deliveries by this mech
    uint256 public numTotalDeliveries;
    // Reentrancy lock
    uint256 internal _locked = 1;

    // Cyclical map of request Ids
    mapping(bytes32 => bytes32[2]) public mapRequestIds;

    /// @dev OlasMech constructor.
    /// @param _mechMarketplace Mech marketplace address.
    /// @param _serviceRegistry Address of the registry contract.
    /// @param _serviceId Service Id.
    /// @param _maxDeliveryRate Mech max delivery rate.
    /// @param _paymentType Mech payment type.
    constructor(
        address _mechMarketplace,
        address _serviceRegistry,
        uint256 _serviceId,
        uint256 _maxDeliveryRate,
        bytes32 _paymentType
    ) {
        // Check for zero address
        if (_mechMarketplace == address(0)) {
            revert ZeroAddress();
        }

        // Check for zero address
        if (_serviceRegistry == address(0)) {
            revert ZeroAddress();
        }

        // Check for zero value
        if (_serviceId == 0 || _maxDeliveryRate == 0 || _paymentType == 0) {
            revert ZeroValue();
        }

        (, address multisig, , , , , IServiceRegistry.ServiceState state) =
            IServiceRegistry(_serviceRegistry).mapServices(_serviceId);

        // Check for zero address
        if (multisig == address(0)) {
            revert ZeroAddress();
        }

        // Check for correct service state
        if (state != IServiceRegistry.ServiceState.Deployed) {
            revert WrongServiceState(uint256(state), _serviceId);
        }

        mechMarketplace = _mechMarketplace;
        serviceRegistry = _serviceRegistry;
        serviceId = _serviceId;
        maxDeliveryRate = _maxDeliveryRate;
        paymentType = _paymentType;
    }

    /// @dev Performs actions before the delivery of a request.
    /// @param requestId Request Id.
    /// @param data Self-descriptive opaque data-blob.
    /// @return requestData Data for the request processing.
    /// @return deliveryRate Corresponding finalized delivery rate.
    function _preDeliver(
        bytes32 requestId,
        bytes calldata data
    ) internal virtual returns (bytes memory requestData, uint256 deliveryRate);

    /// @dev Registers a request.
    /// @param requestIds Set of request Ids.
    /// @param datas Set of corresponding self-descriptive opaque data-blobs.
    function _request(
        bytes32[] calldata requestIds,
        bytes[] calldata datas
    ) internal virtual {
        uint256 numRequests = requestIds.length;

        for (uint256 i = 0; i < requestIds.length; ++i) {
            bytes32 requestId = requestIds[i];

            // Record the request Id in the map
            // Get previous and next request Ids of the first element
            bytes32[2] storage requestIdLinks = mapRequestIds[0];
            // Create the new element
            bytes32[2] storage newRequestIdLinks = mapRequestIds[requestId];

            // Previous element will be zero, next element will be the current next element
            bytes32 curNextRequestIdLink = requestIdLinks[1];
            // Note that newRequestIdLinks[0] is 0 by default as pointing to the sentinel node
            newRequestIdLinks[1] = curNextRequestIdLink;
            // Next element of the zero element will be the newly created element
            requestIdLinks[1] = requestId;
            // Previous element of the current next element will be the newly created element
            mapRequestIds[curNextRequestIdLink][0] = requestId;

            emit Request(address(this), requestId, datas[i]);
        }

        // Increase the number of undelivered requests
        numUndeliveredRequests += numRequests;
        // Increase the total number of requests
        numTotalRequests += numRequests;
    }

    /// @dev Prepares delivery of requests.
    /// @notice This function ultimately calls mech marketplace contract to finalize the delivery.
    /// @param requestIds Set of request Ids.
    /// @param datas Corresponding set of self-descriptive opaque delivery data-blobs.
    /// @return deliveryDatas Corresponding set of processed delivery datas.
    /// @return deliveryRates Set of corresponding finalized delivery rates.
    function _prepareDeliveries(
        bytes32[] calldata requestIds,
        bytes[] calldata datas
    ) internal virtual returns (bytes[] memory deliveryDatas, uint256[] memory deliveryRates) {
        uint256 numRequests = requestIds.length;
        deliveryDatas = new bytes[](numRequests);
        deliveryRates = new uint256[](numRequests);

        uint256 numSelfRequests;
        // Traverse requests
        for (uint256 i = 0; i < numRequests; ++i) {
            bytes32 requestId = requestIds[i];
            // Perform a pre-delivery of the data if it needs additional parsing and get finalized request delivery rate
            (deliveryDatas[i], deliveryRates[i]) = _preDeliver(requestId, datas[i]);

            // Clean request info
            // Get request Id from the request Ids map
            bytes32[2] memory requestIdLinks = mapRequestIds[requestId];

            // Check if the request Id is invalid (non existent for this mech or delivered): previous and next request Ids
            // are zero, and the zero's element previous request Id is not equal to the provided request Id
            if (requestIdLinks[0] == 0 && requestIdLinks[1] == 0 && mapRequestIds[0][0] != requestId) {
                continue;
            } else {
                numSelfRequests++;
            }

            // Re-link previous and next elements between themselves
            mapRequestIds[requestIdLinks[0]][1] = requestIdLinks[1];
            mapRequestIds[requestIdLinks[1]][0] = requestIdLinks[0];

            // Delete the delivered element from the map
            delete mapRequestIds[requestId];
        }

        // Decrease the number of undelivered requests
        numUndeliveredRequests -= numSelfRequests;
    }

    /// @dev Sets the new max delivery rate.
    /// @param newMaxDeliveryRate New max delivery rate.
    function changeMaxDeliveryRate(uint256 newMaxDeliveryRate) external virtual onlyOperator {
        // Check for zero value
        if (newMaxDeliveryRate == 0) {
            revert ZeroValue();
        }

        maxDeliveryRate = newMaxDeliveryRate;
        emit MaxDeliveryRateUpdated(newMaxDeliveryRate);
    }

    /// @dev Registers marketplace requests.
    /// @notice This function is called by the marketplace contract since this mech was specified as a priority one.
    /// @param requestIds Set of request Ids.
    /// @param datas Set of corresponding self-descriptive opaque data-blobs.
    function requestFromMarketplace(bytes32[] calldata requestIds, bytes[] calldata datas) external {
        // Check for marketplace access
        if (msg.sender != mechMarketplace) {
            revert MarketplaceOnly(msg.sender, mechMarketplace);
        }

        // Perform requests
        _request(requestIds, datas);
    }

    /// @dev Updates number of requests delivered directly via Marketplace.
    /// @param numRequests Number of requests.
    function updateNumRequests(uint256 numRequests) external {
        // Check for marketplace access
        if (msg.sender != mechMarketplace) {
            revert MarketplaceOnly(msg.sender, mechMarketplace);
        }

        numTotalRequests += numRequests;
        numTotalDeliveries += numRequests;

        emit NumRequestsIncrease(numRequests);
    }

    /// @dev Delivers a request by a marketplace.
    /// @notice This function ultimately calls mech marketplace contract to finalize the delivery.
    /// @param requestIds Set of request ids.
    /// @param datas Corresponding set of self-descriptive opaque delivery data-blobs.
    /// @return deliveredRequests Corresponding set of successful / failed deliveries.
    function deliverToMarketplace(
        bytes32[] calldata requestIds,
        bytes[] calldata datas
    ) external onlyOperator returns (bool[] memory deliveredRequests) {
        // Reentrancy guard
        if (_locked == 2) {
            revert ReentrancyGuard();
        }
        _locked = 2;

        // Check array sizes
        if (requestIds.length == 0 || requestIds.length != datas.length) {
            revert WrongArrayLength(requestIds.length, datas.length);
        }

        // Preliminary delivery processing and getting finalized delivery rates
        (bytes[] memory deliveryDatas, uint256[] memory deliveryRates) = _prepareDeliveries(requestIds, datas);

        // Mech marketplace delivery finalization
        // Some of deliveries might be front-run by other mechs, and thus only actually delivered ones are recorded
        deliveredRequests = IMechMarketplace(mechMarketplace).deliverMarketplace(requestIds, deliveryRates);

        uint256 numRequests = requestIds.length;
        uint256 numDeliveries;
        // Traverse all requests to select delivered ones
        for (uint256 i = 0; i < numRequests; ++i) {
            if (deliveredRequests[i]) {
                numDeliveries++;
                emit Deliver(address(this), msg.sender, requestIds[i], deliveryRates[i], deliveryDatas[i]);
            } else {
                emit RevokeRequest(requestIds[i]);
            }
        }

        // Increase the total number of deliveries actually delivered by this mech
        numTotalDeliveries += numDeliveries;

        _locked = 1;
    }

    /// @dev Delivers signed requests.
    /// @param requester Requester address.
    /// @param deliverWithSignatures Set of DeliverWithSignature structs.
    /// @param deliveryRates Corresponding set of actual charged delivery rates for each request.
    /// @param paymentData Additional payment-related request data, if applicable.
    function deliverMarketplaceWithSignatures(
        address requester,
        DeliverWithSignature[] calldata deliverWithSignatures,
        uint256[] calldata deliveryRates,
        bytes calldata paymentData
    ) external onlyOperator {
        IMechMarketplace(mechMarketplace).deliverMarketplaceWithSignatures(requester, deliverWithSignatures,
            deliveryRates, paymentData);
    }

    /// @dev Delivers signed requests with per-request price caps (overload).
    /// @param requester Requester address.
    /// @param deliverWithSignatures Set of DeliverWithSignature structs.
    /// @param deliveryRates Actual charged delivery rate for each request (must be <= the signed cap).
    /// @param maxRates Signed cap for each request.
    /// @param paymentData Additional payment-related request data, if applicable.
    function deliverMarketplaceWithSignatures(
        address requester,
        DeliverWithSignature[] calldata deliverWithSignatures,
        uint256[] calldata deliveryRates,
        uint256[] calldata maxRates,
        bytes calldata paymentData
    ) external onlyOperator {
        IMechMarketplace(mechMarketplace).deliverMarketplaceWithSignatures(requester, deliverWithSignatures,
            deliveryRates, maxRates, paymentData);
    }

    /// @dev Delivers signed requests with per-request price caps and requester-chosen per-request nonces (overload).
    /// @param requester Requester address.
    /// @param deliverWithSignatures Set of DeliverWithSignature structs.
    /// @param deliveryRates Actual charged delivery rate for each request (must be <= the signed cap).
    /// @param maxRates Signed cap for each request.
    /// @param nonces Requester-chosen per-request nonce (salt) for each request — the value signed over via
    ///        getRequestIdWithNonce. Must be unique per (mech, requestData, maxRate, paymentType) tuple. Domain
    ///        separation (EXPLICIT_NONCE_TAG) already isolates these request Ids from the sequential-nonce paths,
    ///        so no disjoint-nonce-range convention is needed.
    /// @param paymentData Additional payment-related request data, if applicable.
    function deliverMarketplaceWithSignatures(
        address requester,
        DeliverWithSignature[] calldata deliverWithSignatures,
        uint256[] calldata deliveryRates,
        uint256[] calldata maxRates,
        uint256[] calldata nonces,
        bytes calldata paymentData
    ) external onlyOperator {
        IMechMarketplace(mechMarketplace).deliverMarketplaceWithSignatures(requester, deliverWithSignatures,
            deliveryRates, maxRates, nonces, paymentData);
    }

    /// @dev Gets mech token (service registry) address.
    /// @return serviceRegistry Service registry address.
    function token() external view returns (address ) {
        return serviceRegistry;
    }

    /// @dev Gets mech token Id (service Id).
    /// @return serviceId Service Id.
    function tokenId() external view returns (uint256) {
        return serviceId;
    }

    /// @dev Gets mech operator (service multisig).
    /// @return Service multisig address.
    function getOperator() public view returns (address) {
        (, address multisig, , , , , IServiceRegistry.ServiceState state) =
            IServiceRegistry(serviceRegistry).mapServices(serviceId);

        // Check for correct service state
        if (state != IServiceRegistry.ServiceState.Deployed) {
            revert WrongServiceState(uint256(state), serviceId);
        }

        return multisig;
    }

    /// @dev Checks the mech operator (service multisig).
    /// @param multisig Service multisig being checked against.
    /// @return True, if mech service multisig matches the provided one.
    function isOperator(address multisig) public view override returns (bool) {
        return multisig == getOperator();
    }

    /// @dev Gets the set of undelivered request Ids with Nonce.
    /// @param size Maximum batch size of a returned requests Id set. If the size is zero, the whole set is returned.
    /// @param offset The number of skipped requests that are not going to be part of the returned requests Id set.
    /// @return requestIds Set of undelivered request Ids.
    function getUndeliveredRequestIds(uint256 size, uint256 offset) external view returns (bytes32[] memory requestIds) {
        // Get the number of undelivered requests
        uint256 numRequests = numUndeliveredRequests;

        // If size is zero, return all the requests
        if (size == 0) {
            size = numRequests;
        }

        // Check for the size + offset overflow
        if (size + offset > numRequests) {
            revert Overflow(size + offset, numRequests);
        }

        if (size > 0) {
            requestIds = new bytes32[](size);

            // The first request Id is the next request Id of the zero element in the request Ids map
            bytes32 curRequestId = mapRequestIds[0][1];
            // Traverse requests a specified offset
            for (uint256 i = 0; i < offset; ++i) {
                // Next request Id of the current element based on the current request Id
                curRequestId = mapRequestIds[curRequestId][1];
            }

            // Traverse the rest of requests
            for (uint256 i = 0; i < size; ++i) {
                requestIds[i] = curRequestId;
                // Next request Id of the current element based on the current request Id
                curRequestId = mapRequestIds[curRequestId][1];
            }
        }
    }

    /// @dev Mech compatibility setUp function.
    function setUp(bytes memory) public pure override {
        revert AlreadyInitialized();
    }
}
