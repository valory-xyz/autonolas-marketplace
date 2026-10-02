// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import {IErrorsMarketplace} from "./interfaces/IErrorsMarketplace.sol";
import {IBalanceTracker} from "./interfaces/IBalanceTracker.sol";
import {IKarma} from "./interfaces/IKarma.sol";
import {IMech} from "./interfaces/IMech.sol";
import {IServiceRegistry} from "./interfaces/IServiceRegistry.sol";
import {DeliverWithSignature} from "./OlasMech.sol";

// Mech Factory interface
interface IMechFactory {
    /// @dev Registers service as a mech.
    /// @param serviceRegistry Service registry address.
    /// @param serviceId Service id.
    /// @param payload Mech creation payload.
    /// @return mech The created mech instance address.
    function createMech(address serviceRegistry, uint256 serviceId, bytes memory payload)
        external returns (address mech);
}

// Signature Validator interface
interface ISignatureValidator {
    /// @dev Should return whether the signature provided is valid for the provided hash.
    /// @notice MUST return the bytes4 magic value 0x1626ba7e when function passes.
    ///         MUST NOT modify state (using STATICCALL for solc < 0.5, view modifier for solc > 0.5).
    ///         MUST allow external calls.
    /// @param hash Hash of the data to be signed.
    /// @param signature Signature byte array associated with hash.
    /// @return magicValue bytes4 magic value.
    function isValidSignature(bytes32 hash, bytes memory signature) external view returns (bytes4 magicValue);
}

// Request info struct
struct RequestInfo {
    // Priority mech address
    address priorityMech;
    // Delivery mech address
    address deliveryMech;
    // Requester address
    address requester;
    // Response timeout window
    uint256 responseTimeout;
    // Delivery rate
    uint256 deliveryRate;
    // Payment type
    bytes32 paymentType;
}

/// @dev The actual delivery rate exceeds the cap the requester signed.
/// @param actual Actual charged delivery rate.
/// @param cap Signed maximum delivery rate.
error RateOverCap(uint256 actual, uint256 cap);

/// @title Mech Marketplace - Marketplace for posting and delivering requests served by mechs
/// @author Aleksandr Kuperman - <aleksandr.kuperman@valory.xyz>
/// @author Andrey Lebedev - <andrey.lebedev@valory.xyz>
/// @author Mariapia Moscatiello - <mariapia.moscatiello@valory.xyz>
/// @author Silvere Gangloff - <silvere.gangloff@valory.xyz>
contract MechMarketplace is IErrorsMarketplace {
    event CreateMech(address indexed mech, uint256 indexed serviceId, address indexed mechFactory);
    event OwnerUpdated(address indexed owner);
    event ImplementationUpdated(address indexed implementation);
    event MarketplaceParamsUpdated(uint256 fee, uint256 minResponseTimeout, uint256 maxResponseTimeout);
    event SetMechFactoryStatuses(address[] mechFactories, bool[] statuses);
    event SetPaymentTypeBalanceTrackers(bytes32[] paymentTypes, address[] balanceTrackers);
    event MarketplaceRequest(address indexed priorityMech, address indexed requester, uint256 numRequests,
        bytes32[] requestIds, bytes[] requestDatas);
    event MarketplaceDelivery(address indexed deliveryMech, address[] requesters, uint256 numDeliveries,
        bytes32[] requestIds, bool[] deliveredRequests);
    event Deliver(address indexed mech, address indexed mechServiceMultisig, bytes32 requestId, uint256 deliveryRate,
        bytes requestData, bytes deliveryData);
    event MarketplaceDeliveryWithSignatures(address indexed deliveryMech, address indexed requester,
        uint256 numDeliveries, bytes32[] requestIds);

    enum RequestStatus {
        DoesNotExist,
        RequestedPriority,
        RequestedExpired,
        Delivered
    }

    // Contract version number
    string public constant VERSION = "1.1.0";
    // Value for the contract signature validation: bytes4(keccak256("isValidSignature(bytes32,bytes)")
    bytes4 constant internal MAGIC_VALUE = 0x1626ba7e;
    // Code position in storage is keccak256("MECH_MARKETPLACE_PROXY") = "0xe6194b93a7bff0a54130ed8cd277223408a77f3e48bb5104a9db96d334f962ca"
    bytes32 public constant MECH_MARKETPLACE_PROXY = 0xe6194b93a7bff0a54130ed8cd277223408a77f3e48bb5104a9db96d334f962ca;
    // Domain separator type hash
    bytes32 public constant DOMAIN_SEPARATOR_TYPE_HASH =
        keccak256("EIP712Domain(string name,string version,uint256 chainId,address verifyingContract)");
    // Max marketplace fee factor (100%)
    uint256 public constant MAX_FEE_FACTOR = 10_000;

    // Original chain Id
    uint256 public immutable chainId;
    // Mech karma contract address
    address public immutable karma;
    // Service registry contract address
    address public immutable serviceRegistry;

    // Domain separator value
    bytes32 public domainSeparator;
    // Universal mech marketplace fee (max of 10_000 == 100%)
    uint256 public fee;
    // Minimum response time
    uint256 public minResponseTimeout;
    // Maximum response time
    uint256 public maxResponseTimeout;
    // Number of undelivered requests
    uint256 public numUndeliveredRequests;
    // Number of total requests
    uint256 public numTotalRequests;
    // Number of mechs
    uint256 public numMechs;
    // Reentrancy lock
    uint256 internal _locked;

    // Contract owner
    address public owner;

    // Map of request counts for corresponding requester
    mapping(address => uint256) public mapRequestCounts;
    // Map of delivery counts for corresponding requester
    mapping(address => uint256) public mapDeliveryCounts;
    // Map of delivery counts for mechs
    mapping(address => uint256) public mapMechDeliveryCounts;
    // Map of delivery counts for corresponding mech service multisig
    mapping(address => uint256) public mapMechServiceDeliveryCounts;
    // Mapping of request Id => request information
    mapping(bytes32 => RequestInfo) public mapRequestIdInfos;
    // Mapping of whitelisted mech factories
    mapping(address => bool) public mapMechFactories;
    // Map of mech => its creating factory
    mapping(address => address) public mapAgentMechFactories;
    // Map of payment type => balanceTracker address
    mapping(bytes32 => address) public mapPaymentTypeBalanceTrackers;
    // Mapping of account nonces
    mapping(address => uint256) public mapNonces;


    /// @dev MechMarketplace constructor.
    /// @param _serviceRegistry Service registry contract address.
    /// @param _karma Karma proxy contract address.
    constructor(address _serviceRegistry, address _karma) {
        // Check for zero address
        if (_serviceRegistry == address(0) || _karma == address(0)) {
            revert ZeroAddress();
        }

        serviceRegistry = _serviceRegistry;
        karma = _karma;

        // Record chain Id
        chainId = block.chainid;
    }

    /// @dev Computes domain separator hash.
    /// @return Hash of the domain separator based on its name, version, chain Id and contract address.
    function _computeDomainSeparator() internal view returns (bytes32) {
        return keccak256(
            abi.encode(
                DOMAIN_SEPARATOR_TYPE_HASH,
                keccak256("MechMarketplace"),
                keccak256(abi.encode(VERSION)),
                block.chainid,
                address(this)
            )
        );
    }

    /// @dev Changes marketplace params.
    /// @param newFee New marketplace fee.
    /// @param newMinResponseTimeout New min response time in sec.
    /// @param newMaxResponseTimeout New max response time in sec.
    function _changeMarketplaceParams(
        uint256 newFee,
        uint256 newMinResponseTimeout,
        uint256 newMaxResponseTimeout
    ) internal {
        // Check for zero values
        if (newMinResponseTimeout == 0 || newMaxResponseTimeout == 0) {
            revert ZeroValue();
        }

        // Check for fee value
        if (newFee > MAX_FEE_FACTOR) {
            revert Overflow(newFee, MAX_FEE_FACTOR);
        }

        // Check for sanity values
        if (newMinResponseTimeout > newMaxResponseTimeout) {
            revert Overflow(newMinResponseTimeout, newMaxResponseTimeout);
        }

        // responseTimeout limits
        if (newMaxResponseTimeout > type(uint32).max) {
            revert Overflow(newMaxResponseTimeout, type(uint32).max);
        }

        fee = newFee;
        minResponseTimeout = newMinResponseTimeout;
        maxResponseTimeout = newMaxResponseTimeout;
    }

    /// @dev Delivers signed requests.
    /// @param requester Requester address.
    /// @param paymentType Delivering mech payment type.
    /// @param deliverWithSignatures Set of DeliverWithSignature structs.
    /// @param deliveryRates Corresponding set of actual charged delivery rates for each request.
    function _deliverMarketplaceWithSignatures(
        address requester,
        bytes32 paymentType,
        DeliverWithSignature[] memory deliverWithSignatures,
        uint256[] calldata deliveryRates
    ) internal {
        // Check mech
        address mechServiceMultisig = checkMech(msg.sender);

        // Get number of requests
        uint256 numRequests = deliverWithSignatures.length;

        // Allocate set for request Ids
        bytes32[] memory requestIds = new bytes32[](numRequests);

        // Get current nonce
        uint256 nonce = mapNonces[requester];

        // Traverse all request Ids
        for (uint256 i = 0; i < numRequests; ++i) {
            // Check for non-zero data
            if (deliverWithSignatures[i].requestData.length == 0) {
                revert ZeroValue();
            }

            // Calculate request Id
            requestIds[i] = getRequestId(msg.sender, requester, deliverWithSignatures[i].requestData, deliveryRates[i],
                paymentType, nonce);

            // Verify the signed hash against the operator address
            _verifySignedHash(requester, requestIds[i], deliverWithSignatures[i].signature);

            // Get request info struct
            RequestInfo storage requestInfo = mapRequestIdInfos[requestIds[i]];

            // Check for request Id record
            if (requestInfo.priorityMech != address(0)) {
                revert AlreadyRequested(requestIds[i]);
            }

            // Record all the request info
            requestInfo.priorityMech = msg.sender;
            requestInfo.deliveryMech = msg.sender;
            requestInfo.requester = requester;
            requestInfo.deliveryRate = deliveryRates[i];
            requestInfo.paymentType = paymentType;
            // requestInfo.responseTimeout is not set which clearly separates these requests with signature from others

            // Increase nonce
            nonce++;

            // Symmetrical delivery mech event that in general happens when delivery is called directly through the mech
            emit Deliver(msg.sender, mechServiceMultisig, requestIds[i], deliveryRates[i],
                deliverWithSignatures[i].requestData, deliverWithSignatures[i].deliveryData);
        }

        // Adjust requester nonce values
        mapNonces[requester] = nonce;

        // Record the request count
        mapRequestCounts[requester] += numRequests;
        // Increase the amount of requester delivered requests
        mapDeliveryCounts[requester] += numRequests;
        // Increase the amount of mech delivery counts
        mapMechDeliveryCounts[msg.sender] += numRequests;
        // Increase the amount of mech service multisig delivered requests
        mapMechServiceDeliveryCounts[mechServiceMultisig] += numRequests;
        // Increase the total number of requests
        numTotalRequests += numRequests;

        // Increase mech requester karma
        IKarma(karma).changeRequesterMechKarma(requester, msg.sender, int256(numRequests));
        // Increase mech karma that delivers the request
        IKarma(karma).changeMechKarma(msg.sender, int256(numRequests));

        // Update mech stats
        IMech(msg.sender).updateNumRequests(numRequests);

        emit MarketplaceDeliveryWithSignatures(msg.sender, requester, requestIds.length, requestIds);
    }

    /// @dev Delivers signed requests under per-request price caps (cap-and-actual pricing).
    /// @param requester Requester address.
    /// @param paymentType Delivering mech payment type.
    /// @param deliverWithSignatures Set of DeliverWithSignature structs.
    /// @param deliveryRates Actual charged delivery rate for each request (must be <= the signed cap).
    /// @param maxRates Signed cap for each request — the value the requester signed over.
    function _deliverMarketplaceWithSignatures(
        address requester,
        bytes32 paymentType,
        DeliverWithSignature[] memory deliverWithSignatures,
        uint256[] calldata deliveryRates,
        uint256[] calldata maxRates
    ) internal {
        // Check mech
        address mechServiceMultisig = checkMech(msg.sender);

        // Get number of requests
        uint256 numRequests = deliverWithSignatures.length;

        // Allocate set for request Ids
        bytes32[] memory requestIds = new bytes32[](numRequests);

        // Get current nonce
        uint256 nonce = mapNonces[requester];

        // Traverse all request Ids; the per-request body lives in a helper to keep this frame under the stack ceiling
        for (uint256 i = 0; i < numRequests; ++i) {
            requestIds[i] = _processSignedDelivery(requester, paymentType, mechServiceMultisig,
                deliverWithSignatures[i], deliveryRates[i], maxRates[i], nonce);

            // Increase nonce
            nonce++;
        }

        // Adjust requester nonce values
        mapNonces[requester] = nonce;

        // Record the request count
        mapRequestCounts[requester] += numRequests;
        // Increase the amount of requester delivered requests
        mapDeliveryCounts[requester] += numRequests;
        // Increase the amount of mech delivery counts
        mapMechDeliveryCounts[msg.sender] += numRequests;
        // Increase the amount of mech service multisig delivered requests
        mapMechServiceDeliveryCounts[mechServiceMultisig] += numRequests;
        // Increase the total number of requests
        numTotalRequests += numRequests;

        // Increase mech requester karma
        IKarma(karma).changeRequesterMechKarma(requester, msg.sender, int256(numRequests));
        // Increase mech karma that delivers the request
        IKarma(karma).changeMechKarma(msg.sender, int256(numRequests));

        // Update mech stats
        IMech(msg.sender).updateNumRequests(numRequests);

        emit MarketplaceDeliveryWithSignatures(msg.sender, requester, requestIds.length, requestIds);
    }

    /// @dev Validates and records a single signed delivery under a per-request cap, and emits the delivery event.
    /// @notice Split out of _deliverMarketplaceWithSignatures to keep its loop frame under the stack ceiling.
    /// @param requester Requester address.
    /// @param paymentType Delivering mech payment type.
    /// @param mechServiceMultisig Mech service multisig address.
    /// @param deliverWithSignature DeliverWithSignature struct for this request.
    /// @param deliveryRate Actual charged delivery rate (must be <= the signed cap).
    /// @param maxRate Signed cap for this request — the value the requester signed over.
    /// @param nonce Requester nonce for this request.
    /// @return requestId Resulting request Id.
    function _processSignedDelivery(
        address requester,
        bytes32 paymentType,
        address mechServiceMultisig,
        DeliverWithSignature memory deliverWithSignature,
        uint256 deliveryRate,
        uint256 maxRate,
        uint256 nonce
    ) internal returns (bytes32 requestId) {
        // Check for non-zero data
        if (deliverWithSignature.requestData.length == 0) {
            revert ZeroValue();
        }

        // Calculate request Id over the signed cap, not the charged rate
        requestId = getRequestId(msg.sender, requester, deliverWithSignature.requestData, maxRate, paymentType, nonce);

        // Verify the signed hash against the requester address
        _verifySignedHash(requester, requestId, deliverWithSignature.signature);

        // The mech cannot charge more than the requester signed for
        if (deliveryRate > maxRate) {
            revert RateOverCap(deliveryRate, maxRate);
        }

        // Get request info struct
        RequestInfo storage requestInfo = mapRequestIdInfos[requestId];

        // Check for request Id record
        if (requestInfo.priorityMech != address(0)) {
            revert AlreadyRequested(requestId);
        }

        // Record all the request info, charging the actual delivery rate
        requestInfo.priorityMech = msg.sender;
        requestInfo.deliveryMech = msg.sender;
        requestInfo.requester = requester;
        requestInfo.deliveryRate = deliveryRate;
        requestInfo.paymentType = paymentType;
        // requestInfo.responseTimeout is not set which clearly separates these requests with signature from others

        // Symmetrical delivery mech event that in general happens when delivery is called directly through the mech
        emit Deliver(msg.sender, mechServiceMultisig, requestId, deliveryRate, deliverWithSignature.requestData,
            deliverWithSignature.deliveryData);
    }

    /// @dev Registers batch of requests.
    /// @notice The request is going to be registered for a specified priority mech.
    /// @param requestDatas Set of self-descriptive opaque request data-blobs.
    /// @param maxDeliveryRate Max delivery rate requester agrees to supply.
    /// @param paymentType Payment type.
    /// @param priorityMech Priority mech address.
    /// @param responseTimeout Relative response time in sec.
    /// @param paymentData Additional payment-related request data (optional).
    /// @return requestIds Set of request Ids.
    function _requestBatch(
        bytes[] memory requestDatas,
        uint256 maxDeliveryRate,
        bytes32 paymentType,
        address priorityMech,
        uint256 responseTimeout,
        bytes memory paymentData
    ) internal returns (bytes32[] memory requestIds) {
        // Response timeout limits
        if (responseTimeout + block.timestamp > type(uint32).max) {
            revert Overflow(responseTimeout + block.timestamp, type(uint32).max);
        }

        // Response timeout bounds
        if (responseTimeout < minResponseTimeout || responseTimeout > maxResponseTimeout) {
            revert OutOfBounds(responseTimeout, minResponseTimeout, maxResponseTimeout);
        }

        // Check for zero values
        if (maxDeliveryRate == 0 || paymentType == 0) {
            revert ZeroValue();
        }

        uint256 numRequests = requestDatas.length;
        // Check for zero value
        if (numRequests == 0) {
            revert ZeroValue();
        }

        // Check priority mech
        checkMech(priorityMech);

        // Allocate set of requestIds
        requestIds = new bytes32[](numRequests);

        // Get deliveryRate as priority mech max delivery rate
        uint256 deliveryRate = IMech(priorityMech).maxDeliveryRate();
        // Check priority mech delivery rate vs requester specified max delivery rate
        if (deliveryRate > maxDeliveryRate) {
            revert Overflow(deliveryRate, maxDeliveryRate);
        }

        // Check requester specified payment type vs the priority mech payment type
        if (paymentType != IMech(priorityMech).paymentType()) {
            revert WrongPaymentType(paymentType);
        }

        // Get nonce
        uint256 nonce = mapNonces[msg.sender];

        // Traverse all requests
        for (uint256 i = 0; i < requestDatas.length; ++i) {
            // Check for non-zero data
            if (requestDatas[i].length == 0) {
                revert ZeroValue();
            }

            // Calculate request Id
            requestIds[i] = getRequestId(priorityMech, msg.sender, requestDatas[i], deliveryRate, paymentType, nonce);

            // Get request info struct
            RequestInfo storage requestInfo = mapRequestIdInfos[requestIds[i]];

            // Check for request Id record
            if (requestInfo.priorityMech != address(0)) {
                revert AlreadyRequested(requestIds[i]);
            }

            // Record priorityMech and response timeout
            requestInfo.priorityMech = priorityMech;
            // responseTimeout from relative time to absolute time
            requestInfo.responseTimeout = responseTimeout + block.timestamp;
            // Record request account
            requestInfo.requester = msg.sender;
            // Record deliveryRate for request as priority mech max delivery rate
            requestInfo.deliveryRate = deliveryRate;
            // Record priority mech payment type
            requestInfo.paymentType = paymentType;

            nonce++;
        }

        // Update requester nonce
        mapNonces[msg.sender] = nonce;

        // Get balance tracker address
        address balanceTracker = mapPaymentTypeBalanceTrackers[paymentType];
        // Check for zero address
        if (balanceTracker == address(0)) {
            revert ZeroAddress();
        }

        // Check and record mech delivery rate
        IBalanceTracker(balanceTracker).checkAndRecordDeliveryRates{value: msg.value}(msg.sender, numRequests,
            deliveryRate, paymentData);

        // Increase mech requester karma
        IKarma(karma).changeRequesterMechKarma(msg.sender, priorityMech, int256(numRequests));

        // Record the request count
        mapRequestCounts[msg.sender] += numRequests;
        // Increase the number of undelivered requests
        numUndeliveredRequests += numRequests;
        // Increase the total number of requests
        numTotalRequests += numRequests;

        // Process request by a specified priority mech
        IMech(priorityMech).requestFromMarketplace(requestIds, requestDatas);

        emit MarketplaceRequest(priorityMech, msg.sender, numRequests, requestIds, requestDatas);
    }

    /// @dev Verifies provided request hash against its signature.
    /// @param requester Requester address.
    /// @param requestHash Request hash.
    /// @param signature Signature bytes associated with the signed request hash.
    function _verifySignedHash(address requester, bytes32 requestHash, bytes memory signature) internal view {
        // Check for zero address
        if (requester == address(0)) {
            revert ZeroAddress();
        }

        // Check EIP-1271 signature validity if requester is a contract
        if (requester.code.length > 0) {
            if (ISignatureValidator(requester).isValidSignature(requestHash, signature) == MAGIC_VALUE) {
                return;
            } else {
                revert SignatureNotValidated(requester, requestHash, signature);
            }
        }

        // Check for the signature length
        if (signature.length != 65) {
            revert IncorrectSignatureLength(signature, signature.length, 65);
        }

        // Decode the signature
        uint8 v = uint8(signature[64]);

        // For the correct ecrecover() function execution, the v value must be set to {0,1} + 27
        // Although v in a very rare case can be equal to {2,3} (with a probability of 3.73e-37%)
        // If v is set to just 0 or 1 when signing by the EOA, it is most likely signed by the ledger and must be adjusted
        if (v < 4) {
            // In case of a non-contract, adjust v to follow the standard ecrecover case
            v += 27;
        }

        bytes32 r;
        bytes32 s;
        // solhint-disable-next-line no-inline-assembly
        assembly {
            r := mload(add(signature, 32))
            s := mload(add(signature, 64))
        }

        // EIP-2 still allows signature malleability for ecrecover(). Remove this possibility and make the signature
        // unique. Appendix F in the Ethereum Yellow paper (https://ethereum.github.io/yellowpaper/paper.pdf), defines
        // the valid range for s in (301): 0 < s < secp256k1n ÷ 2 + 1, and for v in (302): v ∈ {27, 28}. Most
        // signatures from current libraries generate a unique signature with an s-value in the lower half order.
        //
        // If your library generates malleable signatures, such as s-values in the upper range, calculate a new s-value
        // with 0xFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFEBAAEDCE6AF48A03BBFD25E8CD0364141 - s1 and flip v from 27 to 28 or
        // vice versa. If your library also generates signatures with 0/1 for v instead 27/28, add 27 to v to accept
        // these malleable signatures as well.
        if (uint256(s) > 0x7FFFFFFFFFFFFFFFFFFFFFFFFFFFFFFF5D576E7357A4501DDFE92F46681B20A0) {
            revert SignatureNotValidated(requester, requestHash, signature);
        }

        // Case of ecrecover with the request hash for EOA signatures
        address recRequester = ecrecover(requestHash, v, r, s);

        // Final check is for the requester address itself
        if (recRequester != requester) {
            revert SignatureNotValidated(requester, requestHash, signature);
        }
    }

    /// @dev MechMarketplace initializer.
    /// @param _fee Marketplace fee.
    /// @param _minResponseTimeout Min response time in sec.
    /// @param _maxResponseTimeout Max response time in sec.
    function initialize(uint256 _fee, uint256 _minResponseTimeout, uint256 _maxResponseTimeout) external {
        if (owner != address(0)) {
            revert AlreadyInitialized();
        }

        // Set initial params
        _changeMarketplaceParams(_fee, _minResponseTimeout, _maxResponseTimeout);

        // Compute domain separator
        domainSeparator = _computeDomainSeparator();

        owner = msg.sender;
        _locked = 1;
    }

    /// @dev Changes contract owner address.
    /// @param newOwner Address of a new owner.
    function changeOwner(address newOwner) external virtual {
        // Check for the ownership
        if (msg.sender != owner) {
            revert OwnerOnly(msg.sender, owner);
        }

        // Check for the zero address
        if (newOwner == address(0)) {
            revert ZeroAddress();
        }

        owner = newOwner;
        emit OwnerUpdated(newOwner);
    }

    /// @dev Changes the mechMarketplace implementation contract address.
    /// @param newImplementation New implementation contract address.
    function changeImplementation(address newImplementation) external {
        // Check for the ownership
        if (msg.sender != owner) {
            revert OwnerOnly(msg.sender, owner);
        }

        // Check for zero address
        if (newImplementation == address(0)) {
            revert ZeroAddress();
        }

        // Store the mechMarketplace implementation address
        // solhint-disable-next-line no-inline-assembly
        assembly {
            sstore(MECH_MARKETPLACE_PROXY, newImplementation)
        }

        emit ImplementationUpdated(newImplementation);
    }

    /// @dev Changes marketplace params.
    /// @param newFee New marketplace fee.
    /// @param newMinResponseTimeout New min response time in sec.
    /// @param newMaxResponseTimeout New max response time in sec.
    function changeMarketplaceParams(
        uint256 newFee,
        uint256 newMinResponseTimeout,
        uint256 newMaxResponseTimeout
    ) external {
        // Check for the ownership
        if (msg.sender != owner) {
            revert OwnerOnly(msg.sender, owner);
        }

        _changeMarketplaceParams(newFee, newMinResponseTimeout, newMaxResponseTimeout);

        emit MarketplaceParamsUpdated(newFee, newMinResponseTimeout, newMaxResponseTimeout);
    }

    /// @dev Registers service as a mech.
    /// @notice Mech is created by corresponding service owner or service multisig.
    /// @param serviceId Service id.
    /// @param mechFactory Mech factory address.
    /// @return mech The created mech instance address.
    function create(uint256 serviceId, address mechFactory, bytes memory payload) external returns (address mech) {
        // Get service owner address
        address serviceOwner = IServiceRegistry(serviceRegistry).ownerOf(serviceId);
        // Check for msg.sender to be a service owner
        if (msg.sender != serviceOwner) {
            // Check for msg.sender to be a serviceId multisig
            (, address multisig, , , , , ) = IServiceRegistry(serviceRegistry).mapServices(serviceId);
            if (msg.sender != multisig) {
                revert UnauthorizedAccount(msg.sender);
            }
        }

        // Check for factory status
        if (!mapMechFactories[mechFactory]) {
            revert UnauthorizedAccount(mechFactory);
        }

        // Create mech
        mech = IMechFactory(mechFactory).createMech(serviceRegistry, serviceId, payload);

        // This should never be the case
        if (mech == address(0)) {
            revert ZeroAddress();
        }

        // Record factory that created a mech
        mapAgentMechFactories[mech] = mechFactory;
        numMechs++;

        emit CreateMech(mech, serviceId, mechFactory);
    }

    /// @dev Sets mech factory statues.
    /// @param mechFactories Mech marketplace contract addresses.
    /// @param statuses Corresponding whitelisting statues.
    function setMechFactoryStatuses(address[] calldata mechFactories, bool[] calldata statuses) external {
        // Check for the ownership
        if (msg.sender != owner) {
            revert OwnerOnly(msg.sender, owner);
        }

        if (mechFactories.length != statuses.length) {
            revert WrongArrayLength(mechFactories.length, statuses.length);
        }

        // Traverse all the mech marketplaces and statuses
        for (uint256 i = 0; i < mechFactories.length; ++i) {
            if (mechFactories[i] == address(0)) {
                revert ZeroAddress();
            }

            mapMechFactories[mechFactories[i]] = statuses[i];
        }

        emit SetMechFactoryStatuses(mechFactories, statuses);
    }

    /// @dev Sets mech payment type balanceTrackers.
    /// @param paymentTypes Mech types.
    /// @param balanceTrackers Corresponding balanceTracker addresses.
    function setPaymentTypeBalanceTrackers(bytes32[] calldata paymentTypes, address[] calldata balanceTrackers) external {
        // Check for the ownership
        if (msg.sender != owner) {
            revert OwnerOnly(msg.sender, owner);
        }

        if (paymentTypes.length != balanceTrackers.length) {
            revert WrongArrayLength(paymentTypes.length, balanceTrackers.length);
        }

        // Traverse all the mech types and balanceTrackers
        for (uint256 i = 0; i < paymentTypes.length; ++i) {
            // Check for zero value
            if (paymentTypes[i] == 0) {
                revert ZeroValue();
            }

            // Check for zero address
            if (balanceTrackers[i] == address(0)) {
                revert ZeroAddress();
            }

            mapPaymentTypeBalanceTrackers[paymentTypes[i]] = balanceTrackers[i];
        }

        emit SetPaymentTypeBalanceTrackers(paymentTypes, balanceTrackers);
    }

    /// @dev Registers a request.
    /// @notice The request is going to be registered for a specified priority mech.
    /// @param requestData Self-descriptive opaque request data-blob.
    /// @param maxDeliveryRate Max delivery rate requester agrees to supply.
    /// @param paymentType Payment type.
    /// @param priorityMech Priority mech address.
    /// @param responseTimeout Relative response time in sec.
    /// @param paymentData Additional payment-related request data (optional).
    /// @return requestId Request Id.
    function request(
        bytes memory requestData,
        uint256 maxDeliveryRate,
        bytes32 paymentType,
        address priorityMech,
        uint256 responseTimeout,
        bytes calldata paymentData
    ) external payable returns (bytes32 requestId) {
        // Reentrancy guard
        if (_locked == 2) {
            revert ReentrancyGuard();
        }
        _locked = 2;

        // Allocate arrays
        bytes[] memory requestDatas = new bytes[](1);
        bytes32[] memory requestIds = new bytes32[](1);

        requestDatas[0] = requestData;
        requestIds = _requestBatch(requestDatas, maxDeliveryRate, paymentType, priorityMech, responseTimeout,
            paymentData);

        requestId = requestIds[0];

        _locked = 1;
    }

    /// @dev Registers batch of requests.
    /// @notice The request is going to be registered for a specified priority mech.
    /// @param requestDatas Set of self-descriptive opaque request data-blobs.
    /// @param maxDeliveryRate Max delivery rate requester agrees to supply for each request.
    /// @param paymentType Payment type.
    /// @param priorityMech Priority mech address.
    /// @param responseTimeout Relative response time in sec.
    /// @param paymentData Additional payment-related request data (optional).
    /// @return requestIds Set of request Ids.
    function requestBatch(
        bytes[] memory requestDatas,
        uint256 maxDeliveryRate,
        bytes32 paymentType,
        address priorityMech,
        uint256 responseTimeout,
        bytes calldata paymentData
    ) external payable returns (bytes32[] memory requestIds) {
        // Reentrancy guard
        if (_locked == 2) {
            revert ReentrancyGuard();
        }
        _locked = 2;

        requestIds = _requestBatch(requestDatas, maxDeliveryRate, paymentType, priorityMech, responseTimeout, paymentData);

        _locked = 1;
    }

    /// @dev Delivers requests.
    /// @notice This function can only be called by the mech delivering the request.
    /// @param requestIds Set of request ids.
    /// @param deliveryRates Corresponding set of actual charged delivery rates for each request.
    /// @return deliveredRequests Corresponding set of successful / failed deliveries.
    function deliverMarketplace(
        bytes32[] calldata requestIds,
        uint256[] calldata deliveryRates
    ) external returns (bool[] memory deliveredRequests) {
        // Reentrancy guard
        if (_locked == 2) {
            revert ReentrancyGuard();
        }
        _locked = 2;

        // Check array lengths
        if (requestIds.length == 0 || requestIds.length != deliveryRates.length) {
            revert WrongArrayLength(requestIds.length, deliveryRates.length);
        }

        // Check delivery mech and get its service multisig
        address mechServiceMultisig = checkMech(msg.sender);

        uint256 numDeliveries;
        uint256 numRequests = requestIds.length;
        // Allocate delivered requests array
        deliveredRequests = new bool[](numRequests);
        // Allocate requester related arrays
        address[] memory requesters = new address[](numRequests);
        uint256[] memory requesterDeliveryRates = new uint256[](numRequests);

        // Get delivery mech payment type
        bytes32 paymentType = IMech(msg.sender).paymentType();

        // Traverse all requests being delivered
        for (uint256 i = 0; i < numRequests; ++i) {
            // Get request info struct
            RequestInfo storage requestInfo = mapRequestIdInfos[requestIds[i]];
            address priorityMech = requestInfo.priorityMech;

            // Check for request existence
            if (priorityMech == address(0)) {
                revert ZeroAddress();
            }

            // Check payment type
            if (requestInfo.paymentType != paymentType) {
                revert WrongPaymentType(paymentType);
            }

            // Check if request has been delivered
            if (requestInfo.deliveryMech != address(0)) {
                continue;
            }

            // Check for actual mech delivery rate
            // If the rate of the mech is higher than set by the requester, the request is ignored and considered
            // undelivered, such that it's cleared from mech's records and delivered by other mechs matching the rate
            requesterDeliveryRates[i] = requestInfo.deliveryRate;
            if (deliveryRates[i] > requesterDeliveryRates[i]) {
                continue;
            }

            // If delivery mech is different from the priority one
            if (priorityMech != msg.sender) {
                // Within the defined response time only a chosen priority mech is able to deliver
                if (block.timestamp > requestInfo.responseTimeout) {
                    // Decrease priority mech karma as the mech did not deliver
                    // Needs to stay atomic as each different priorityMech can be any address
                    IKarma(karma).changeMechKarma(priorityMech, -1);
                } else {
                    // No need to revert if the priority time is not respected, as the request is being delivered
                    // by a delivery mech. Each delivery mech request is not stored in its mapping, thus it is possible
                    // to just continue and mark requests as undelivered, letting others to pass.
                    continue;
                }
            }

            // Record the actual delivery mech
            requestInfo.deliveryMech = msg.sender;

            // Record requester
            requesters[i] = requestInfo.requester;

            // Increase the amount of requester delivered requests
            mapDeliveryCounts[requesters[i]]++;

            // Mark request as delivered
            deliveredRequests[i] = true;
            numDeliveries++;
        }

        if (numDeliveries > 0) {
            // Decrease the number of undelivered requests
            numUndeliveredRequests -= numDeliveries;
            // Increase the amount of mech delivery counts
            mapMechDeliveryCounts[msg.sender] += numDeliveries;
            // Increase the amount of mech service multisig delivered requests
            mapMechServiceDeliveryCounts[mechServiceMultisig] += numDeliveries;

            // Increase mech karma that delivers the request
            IKarma(karma).changeMechKarma(msg.sender, int256(numDeliveries));

            // Get balance tracker address
            address balanceTracker = mapPaymentTypeBalanceTrackers[paymentType];
            // Check for zero address
            if (balanceTracker == address(0)) {
                revert ZeroAddress();
            }

            // Process payment
            IBalanceTracker(balanceTracker).finalizeDeliveryRates(msg.sender, requesters, deliveredRequests,
                deliveryRates, requesterDeliveryRates);
        }

        emit MarketplaceDelivery(msg.sender, requesters, numDeliveries, requestIds, deliveredRequests);

        _locked = 1;
    }

    /// @dev Delivers signed requests.
    /// @notice This function must be called by mech delivering requests.
    /// @param requester Requester address.
    /// @param deliverWithSignatures Set of DeliverWithSignature structs.
    /// @param deliveryRates Corresponding set of actual charged delivery rates for each request.
    /// @param paymentData Additional payment-related request data, if applicable.
    function deliverMarketplaceWithSignatures(
        address requester,
        DeliverWithSignature[] calldata deliverWithSignatures,
        uint256[] calldata deliveryRates,
        bytes calldata paymentData
    ) external {
        // Reentrancy guard
        if (_locked == 2) {
            revert ReentrancyGuard();
        }
        _locked = 2;

        // Array length checks
        if (deliverWithSignatures.length == 0 || deliverWithSignatures.length != deliveryRates.length) {
            revert WrongArrayLength(deliverWithSignatures.length, deliveryRates.length);
        }

        // Payment type
        bytes32 paymentType = IMech(msg.sender).paymentType();

        // Process deliveries
        _deliverMarketplaceWithSignatures(requester, paymentType, deliverWithSignatures, deliveryRates);

        // Get balance tracker address
        address balanceTracker = mapPaymentTypeBalanceTrackers[paymentType];
        // Check for zero address
        if (balanceTracker == address(0)) {
            revert ZeroAddress();
        }

        // Process mech payment
        IBalanceTracker(balanceTracker).adjustMechRequesterBalances(msg.sender, requester, deliveryRates, paymentData);

        _locked = 1;
    }

    /// @dev Delivers signed requests with per-request price caps (cap-and-actual pricing).
    /// @notice Overload of deliverMarketplaceWithSignatures: the requester signs a maximum rate and the mech
    ///         charges the actual delivery rate, which must not exceed the signed cap.
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
    ) external {
        // Reentrancy guard
        if (_locked == 2) {
            revert ReentrancyGuard();
        }
        _locked = 2;

        // Array length checks
        uint256 numRequests = deliverWithSignatures.length;
        if (numRequests == 0 || numRequests != deliveryRates.length) {
            revert WrongArrayLength(numRequests, deliveryRates.length);
        }
        // Check maxRates separately so a mismatch reports the offending array's length
        if (numRequests != maxRates.length) {
            revert WrongArrayLength(numRequests, maxRates.length);
        }

        // Payment type
        bytes32 paymentType = IMech(msg.sender).paymentType();

        // Process deliveries under the signed caps
        _deliverMarketplaceWithSignatures(requester, paymentType, deliverWithSignatures, deliveryRates, maxRates);

        // Get balance tracker address
        address balanceTracker = mapPaymentTypeBalanceTrackers[paymentType];
        // Check for zero address
        if (balanceTracker == address(0)) {
            revert ZeroAddress();
        }

        // Process mech payment at the actual delivery rates
        IBalanceTracker(balanceTracker).adjustMechRequesterBalances(msg.sender, requester, deliveryRates, paymentData);

        _locked = 1;
    }

    /// @dev Gets the already computed domain separator of recomputes one if the chain Id is different.
    /// @return Original or recomputed domain separator.
    function getDomainSeparator() public view returns (bytes32) {
        return block.chainid == chainId ? domainSeparator : _computeDomainSeparator();
    }

    /// @dev Gets the request Id.
    /// @param mech Mech address.
    /// @param requester Requester address.
    /// @param data Self-descriptive opaque data-blob.
    /// @param deliveryRate Request delivery rate.
    /// @param paymentType Payment type.
    /// @param nonce Nonce.
    /// @return requestId Corresponding request Id.
    function getRequestId(
        address mech,
        address requester,
        bytes memory data,
        uint256 deliveryRate,
        bytes32 paymentType,
        uint256 nonce
    ) public view returns (bytes32 requestId) {
        requestId = keccak256(
            abi.encodePacked(
                "\x19\x01",
                getDomainSeparator(),
                keccak256(
                    abi.encode(
                        address(this),
                        mech,
                        requester,
                        keccak256(data),
                        deliveryRate,
                        paymentType,
                        nonce
                    )
                )
            )
        );
    }

    /// @dev Checks for mech validity.
    /// @param mech Mech contract address.
    /// @return multisig Mech service multisig address.
    function checkMech(address mech) public view returns (address multisig) {
        // Check for zero address
        if (mech == address(0)) {
            revert ZeroAddress();
        }

        // Check mech validity as it must be created and recorded via this marketplace
        if (mapAgentMechFactories[mech] == address(0)) {
            revert UnauthorizedAccount(mech);
        }

        // Check mech service Id and get its multisig
        multisig = IMech(mech).getOperator();
    }

    /// @dev Gets the request Id status.
    /// @param requestId Request Id.
    /// @return status Request status.
    function getRequestStatus(bytes32 requestId) external view returns (RequestStatus status) {
        // Get request info
        RequestInfo memory requestInfo = mapRequestIdInfos[requestId];

        // Request exists if it has a record in the mapRequestIdInfos
        if (requestInfo.priorityMech == address(0)) return RequestStatus.DoesNotExist;

        // Check if the request Id was already delivered: delivery mech address is not zero
        if (requestInfo.deliveryMech != address(0)) return RequestStatus.Delivered;

        // Check response timeout which cannot be zero if priority mech is set and delivery mech is not
        if (block.timestamp > requestInfo.responseTimeout) {
            return RequestStatus.RequestedExpired;
        }

        return RequestStatus.RequestedPriority;
    }
}

