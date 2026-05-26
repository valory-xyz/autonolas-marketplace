// Sources flattened with hardhat v2.21.0 https://hardhat.org

// SPDX-License-Identifier: MIT
pragma solidity ^0.8.25;

// Agent Mech interface
interface IMech {
    /// @dev Registers a request.
    /// @param account Requester account address.
    /// @param data Self-descriptive opaque data-blob.
    /// @param requestId Request Id.
    function request(address account, bytes memory data, uint256 requestId) external payable;

    /// @dev Revokes the request from the mech that does not deliver it.
    /// @notice Only marketplace can call this function if the request is not delivered by the chosen priority mech.
    /// @param requestId Request Id.
    function revokeRequest(uint256 requestId) external;
}

// Karma interface
interface IKarma {
    /// @dev Changes agent mech karma.
    /// @param mech Agent mech address.
    /// @param karmaChange Karma change value.
    function changeMechKarma(address mech, int256 karmaChange) external;

    /// @dev Changes requester -> agent mech karma.
    /// @param requester Requester address.
    /// @param mech Agent mech address.
    /// @param karmaChange Karma change value.
    function changeRequesterMechKarma(address requester, address mech, int256 karmaChange) external;
}

/// @dev Only `owner` has a privilege, but the `sender` was provided.
/// @param sender Sender address.
/// @param owner Required sender address as an owner.
error OwnerOnly(address sender, address owner);

/// @dev Provided zero address.
error ZeroAddress();

/// @dev Provided zero value.
error ZeroValue();

/// @dev Agent does not exist.
/// @param agentId Agent Id.
error AgentNotFound(uint256 agentId);

/// @dev Not enough value paid.
/// @param provided Provided amount.
/// @param expected Expected amount.
error NotEnoughPaid(uint256 provided, uint256 expected);

/// @dev Request Id not found.
/// @param requestId Request Id.
error RequestIdNotFound(uint256 requestId);

/// @dev Value overflow.
/// @param provided Overflow value.
/// @param max Maximum possible value.
error Overflow(uint256 provided, uint256 max);

/// @dev Provided account is not a contract.
/// @param account Account address.
error NotContract(address account);

/// @dev Caught reentrancy violation.
error ReentrancyGuard();

/// @dev Account is unauthorized.
/// @param account Account address.
error UnauthorizedAccount(address account);

/// @dev Provided value is out of bounds.
/// @param provided value.
/// @param min Minimum possible value.
/// @param max Maximum possible value.
error OutOfBounds(uint256 provided, uint256 min, uint256 max);

/// @dev The request is already delivered.
/// @param requestId Request Id.
error AlreadyDelivered(uint256 requestId);

/// @dev Priority mech response timeout is not yet met.
/// @param expected Expected timestamp.
/// @param current Current timestamp.
error PriorityMechResponseTimeout(uint256 expected, uint256 current);

// Mech delivery info struct
struct MechDelivery {
    // Priority mech address
    address priorityMech;
    // Delivery mech address
    address deliveryMech;
    // Account address sending the request
    address account;
    // Response timeout window
    uint32 responseTimeout;
}

/// @title Mech Marketplace - Marketplace for posting and delivering requests served by agent mechs
contract MechMarketplace {
    event OwnerUpdated(address indexed owner);
    event FactoryUpdated(address indexed factory);
    event MinMaxResponseTimeoutUpdated(uint256 minResponseTimeout, uint256 maxResponseTimeout);
    event MechRegistrationStatusChanged(address indexed mech, bool status);
    event MarketplaceRequest(address indexed requester, address indexed requestedMech, uint256 requestId, bytes data);
    event MarketplaceDeliver(address indexed priorityMech, address indexed actualMech, address indexed requester,
        uint256 requestId, bytes data);

    enum RequestStatus {
        DoesNotExist,
        RequestedPriority,
        RequestedExpired,
        Delivered
    }

    // Contract version number
    string public constant VERSION = "1.0.0";
    // Domain separator type hash
    bytes32 public constant DOMAIN_SEPARATOR_TYPE_HASH =
        keccak256("EIP712Domain(string name,string version,uint256 chainId,address verifyingContract)");
    // Original domain separator value
    bytes32 public immutable domainSeparator;
    // Original chain Id
    uint256 public immutable chainId;
    // Mech karma contract address
    address public immutable karmaProxy;

    // Number of undelivered requests
    uint256 public numUndeliveredRequests;
    // Number of total requests
    uint256 public numTotalRequests;
    // Minimum response time
    uint256 public minResponseTimeout;
    // Maximum response time
    uint256 public maxResponseTimeout;
    // Reentrancy lock
    uint256 internal _locked = 1;
    // Contract owner
    address public owner;
    // Agent mech factory contract address
    address public factory;

    // Mapping of request Id => mech delivery information
    mapping(uint256 => MechDelivery) public mapRequestIdDeliveries;
    // Mapping of account nonces
    mapping(address => uint256) public mapNonces;
    // Mapping of registered mechs
    mapping(address => bool) public mapMechRegistrations;

    /// @dev MechMarketplace constructor.
    /// @param _factory Agent mech factory address.
    /// @param _karmaProxy Karma proxy contract address.
    /// @param _minResponseTimeout Min response time in sec.
    /// @param _maxResponseTimeout Max response time in sec.
    constructor(address _factory, address _karmaProxy, uint256 _minResponseTimeout, uint256 _maxResponseTimeout) {
        // Check for zero address
        if (_factory == address(0) || _karmaProxy == address(0)) {
            revert ZeroAddress();
        }

        // Check for zero values
        if (_minResponseTimeout == 0 || _maxResponseTimeout == 0) {
            revert ZeroValue();
        }

        // Check for sanity values
        if (_minResponseTimeout > _maxResponseTimeout) {
            revert Overflow(_minResponseTimeout, _maxResponseTimeout);
        }

        // responseTimeout limits
        if (_maxResponseTimeout > type(uint32).max) {
            revert Overflow(_maxResponseTimeout, type(uint32).max);
        }

        owner = msg.sender;
        factory = _factory;
        karmaProxy = _karmaProxy;
        minResponseTimeout = _minResponseTimeout;
        maxResponseTimeout = _maxResponseTimeout;

        // Record chain Id
        chainId = block.chainid;
        // Compute domain separator
        domainSeparator = _computeDomainSeparator();
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

    /// @dev Changes mech factory address.
    /// @param newFactory New mech factory address.
    function changeFactory(address newFactory) external {
        // Check for the contract ownership
        if (msg.sender != owner) {
            revert OwnerOnly(msg.sender, owner);
        }

        // Check for zero address
        if (newFactory == address(0)) {
            revert ZeroAddress();
        }

        factory = newFactory;
        emit FactoryUpdated(newFactory);
    }

    /// @dev Changes min and max response timeout values.
    /// @param newMinResponseTimeout New min response timeout.
    /// @param newMaxResponseTimeout New max response timeout.
    function changeMinMaxResponseTimeout(uint256 newMinResponseTimeout, uint256 newMaxResponseTimeout) external {
        // Check contract ownership
        if (msg.sender != owner) {
            revert OwnerOnly(msg.sender, owner);
        }

        // Check for zero values
        if (newMinResponseTimeout == 0 || newMaxResponseTimeout == 0) {
            revert ZeroValue();
        }

        // Check for sanity values
        if (newMinResponseTimeout > newMaxResponseTimeout) {
            revert Overflow(newMinResponseTimeout, newMaxResponseTimeout);
        }

        // responseTimeout limits
        if (newMaxResponseTimeout > type(uint32).max) {
            revert Overflow(newMaxResponseTimeout, type(uint32).max);
        }

        minResponseTimeout = newMinResponseTimeout;
        maxResponseTimeout = newMaxResponseTimeout;
        
        emit MinMaxResponseTimeoutUpdated(newMinResponseTimeout, newMaxResponseTimeout);
    }

    /// @dev Sets mech registration status.
    /// @param mech Mech address.
    /// @param status True, if registered, false otherwise.
    function setMechRegistrationStatus(address mech, bool status) external{
        // Check for the agent mech factory access or contract ownership
        if (msg.sender != factory && msg.sender != owner) {
            revert OwnerOnly(msg.sender, owner);
        }

        // Check that mech is a contract
        if (mech.code.length == 0) {
            revert NotContract(mech);
        }

        mapMechRegistrations[mech] = status;
        emit MechRegistrationStatusChanged(mech, status);
    }

    /// @dev Registers a request.
    /// @notice The request is going to be registered by a specified priority agent mech.
    /// @param data Self-descriptive opaque data-blob.
    /// @param priorityMech Address of a priority mech.
    /// @param responseTimeout Relative response time in sec.
    /// @return requestId Request Id.
    function request(
        bytes memory data,
        address priorityMech,
        uint256 responseTimeout
    ) external payable returns (uint256 requestId) {
        // Reentrancy guard
        if (_locked > 1) {
            revert ReentrancyGuard();
        }
        _locked = 2;

        // Check for zero address
        if (priorityMech == address(0)) {
            revert ZeroAddress();
        }
        // Agent mech itself cannot post a request
        if (mapMechRegistrations[msg.sender]) {
            revert UnauthorizedAccount(msg.sender);
        }
        // Check that priority mech is registered
        if (!mapMechRegistrations[priorityMech]) {
            revert UnauthorizedAccount(priorityMech);
        }
        // responseTimeout bounds
        if (responseTimeout < minResponseTimeout || responseTimeout > maxResponseTimeout) {
            revert OutOfBounds(responseTimeout, minResponseTimeout, maxResponseTimeout);
        }
        // responseTimeout limits
        if (responseTimeout + block.timestamp > type(uint32).max) {
            revert Overflow(responseTimeout + block.timestamp, type(uint32).max);
        }
        // Check for non-zero data
        if (data.length == 0) {
            revert ZeroValue();
        }

        // Get the request Id
        requestId = getRequestId(msg.sender, data, mapNonces[msg.sender]);

        // Update sender's nonce
        mapNonces[msg.sender]++;

        // Get mech delivery info struct
        MechDelivery storage mechDelivery = mapRequestIdDeliveries[requestId];

        // Record priorityMech and response timeout
        mechDelivery.priorityMech = priorityMech;
        // responseTimeout from relative time to absolute time
        mechDelivery.responseTimeout = uint32(responseTimeout + block.timestamp);
        // Record request account
        mechDelivery.account = msg.sender;

        // Increase mech requester karma
        IKarma(karmaProxy).changeRequesterMechKarma(msg.sender, priorityMech, 1);

        // Increase the number of undelivered requests
        numUndeliveredRequests++;
        // Increase the total number of requests
        numTotalRequests++;

        // Process request by a specified priority mech
        IMech(priorityMech).request{value: msg.value}(msg.sender, data, requestId);

        emit MarketplaceRequest(msg.sender, priorityMech, requestId, data);

        _locked = 1;
    }

    /// @dev Delivers a request.
    /// @notice This function can only be called by the agent mech delivering the request.
    /// @param requestId Request id.
    /// @param requestData Self-descriptive opaque data-blob.
    function deliver(uint256 requestId, bytes memory requestData) external {
        // Reentrancy guard
        if (_locked > 1) {
            revert ReentrancyGuard();
        }
        _locked = 2;

        if (!mapMechRegistrations[msg.sender]) {
            revert UnauthorizedAccount(msg.sender);
        }

        // Get mech delivery info struct
        MechDelivery storage mechDelivery = mapRequestIdDeliveries[requestId];
        address priorityMech = mechDelivery.priorityMech;

        // Check for request existence
        if (priorityMech == address(0)) {
            revert ZeroAddress();
        }

        address account = mechDelivery.account;
        // Check that the request is not already delivered
        if (mechDelivery.deliveryMech != address(0)) {
            revert AlreadyDelivered(requestId);
        }

        // If delivery mech is different from the priority one
        if (priorityMech != msg.sender) {
            // Within the defined response time only a chosen priority mech is able to deliver
            if (block.timestamp > mechDelivery.responseTimeout) {
                // Decrease priority mech karma as the mech did not deliver
                IKarma(karmaProxy).changeMechKarma(msg.sender, -1);
                // Revoke request from the priority mech
                IMech(priorityMech).revokeRequest(requestId);
            } else {
                // Priority mech responseTimeout is still >= block.timestamp
                revert PriorityMechResponseTimeout(mechDelivery.responseTimeout, block.timestamp);
            }
        }

        // Record the actual delivery mech
        mechDelivery.deliveryMech = msg.sender;

        // Decrease the number of undelivered requests
        numUndeliveredRequests--;

        // Increase mech karma that delivers the request
        IKarma(karmaProxy).changeMechKarma(msg.sender, 1);

        emit MarketplaceDeliver(priorityMech, msg.sender, account, requestId, requestData);

        _locked = 1;
    }

    /// @dev Gets the already computed domain separator of recomputes one if the chain Id is different.
    /// @return Original or recomputed domain separator.
    function getDomainSeparator() public view returns (bytes32) {
        return block.chainid == chainId ? domainSeparator : _computeDomainSeparator();
    }

    /// @dev Gets the request Id.
    /// @param account Account address.
    /// @param data Self-descriptive opaque data-blob.
    /// @param nonce Nonce.
    /// @return requestId Corresponding request Id.
    function getRequestId(
        address account,
        bytes memory data,
        uint256 nonce
    ) public view returns (uint256 requestId)
    {
        requestId = uint256(keccak256(
            abi.encodePacked(
                "\x19\x01",
                getDomainSeparator(),
                keccak256(
                    abi.encode(
                        account,
                        data,
                        nonce
                    )
                )
            )
        ));
    }

    /// @dev Gets the request Id status.
    /// @param requestId Request Id.
    /// @return status Request status.
    function getRequestStatus(uint256 requestId) external view returns (RequestStatus status) {
        // Request exists if it has a record in the mapRequestIdDeliveries
        MechDelivery memory mechDelivery = mapRequestIdDeliveries[requestId];
        if (mechDelivery.priorityMech != address(0)) {
            // Check if the request Id was already delivered: delivery mech address is not zero
            if (mechDelivery.deliveryMech == address(0)) {
                if (block.timestamp > mechDelivery.responseTimeout) {
                    status = RequestStatus.RequestedExpired;
                } else {
                    status = RequestStatus.RequestedPriority;
                }
            } else {
                status = RequestStatus.Delivered;
            }
        }
    }

    /// @dev Gets mech delivery info.
    /// @param requestId Request Id.
    /// @return Mech delivery info.
    function getMechDeliveryInfo(uint256 requestId) external view returns (MechDelivery memory) {
        return mapRequestIdDeliveries[requestId];
    }
}
