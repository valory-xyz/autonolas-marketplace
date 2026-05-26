// Sources flattened with hardhat v2.22.17 https://hardhat.org

// SPDX-License-Identifier: MIT

pragma solidity ^0.8.0;

/// @dev Escrow interface
interface IBalanceTracker {
    // Check and record delivery rate
    function checkAndRecordDeliveryRate(address mech, address requester, uint256 requestId) external payable;

    /// @dev Finalizes mech delivery rate based on requested and actual ones.
    /// @param mech Delivery mech address.
    /// @param requester Requester address.
    /// @param requestId Request Id.
    /// @param deliveryRate Requested delivery rate.
    function finalizeDeliveryRate(address mech, address requester, uint256 requestId, uint256 deliveryRate) external;
}


// File contracts/interfaces/IErrorsMarketplace.sol
interface IErrorsMarketplace {
    /// @dev Only `owner` has a privilege, but the `sender` was provided.
    /// @param sender Sender address.
    /// @param owner Required sender address as an owner.
    error OwnerOnly(address sender, address owner);

    /// @dev Provided zero address.
    error ZeroAddress();

    /// @dev Provided zero value.
    error ZeroValue();

    /// @dev The contract is already initialized.
    error AlreadyInitialized();

    /// @dev Wrong length of two arrays.
    /// @param numValues1 Number of values in a first array.
    /// @param numValues2 Number of values in a second array.
    error WrongArrayLength(uint256 numValues1, uint256 numValues2);

    /// @dev Not enough balance to cover costs.
    /// @param current Current balance.
    /// @param required Required balance.
    error InsufficientBalance(uint256 current, uint256 required);

    /// @dev No incoming msg.value is allowed.
    /// @param amount Value amount.
    error NoDepositAllowed(uint256 amount);

    /// @dev Request Id not found.
    /// @param requestId Request Id.
    error RequestIdNotFound(uint256 requestId);

    /// @dev Value overflow.
    /// @param provided Overflow value.
    /// @param max Maximum possible value.
    error Overflow(uint256 provided, uint256 max);

    /// @dev Caught reentrancy violation.
    error ReentrancyGuard();

    /// @dev Account is unauthorized.
    /// @param account Account address.
    error UnauthorizedAccount(address account);

    /// @dev Specified service Id is not staked.
    /// @param stakingInstance Staking contract instance.
    /// @param serviceId Service Id.
    error ServiceNotStaked(address stakingInstance, uint256 serviceId);

    /// @dev Wrong state of a service.
    /// @param state Service state.
    /// @param serviceId Service Id.
    error WrongServiceState(uint256 state, uint256 serviceId);

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

    /// @dev Failure of a transfer.
    /// @param token Address of a token.
    /// @param from Address `from`.
    /// @param to Address `to`.
    /// @param amount Amount value.
    error TransferFailed(address token, address from, address to, uint256 amount);
}


// File contracts/interfaces/IKarma.sol
/// @dev Karma interface
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


// File contracts/interfaces/IMech.sol
/// @dev Mech interface
interface IMech {
    /// @dev Checks if the signer is the mech operator.
    function isOperator(address signer) external view returns (bool);

    /// @dev Registers a request by a marketplace.
    /// @param account Requester account address.
    /// @param data Self-descriptive opaque data-blob.
    /// @param requestId Request Id.
    function requestFromMarketplace(address account, bytes memory data, uint256 requestId) external;

    /// @dev Revokes the request from the mech that does not deliver it.
    /// @notice Only marketplace can call this function if the request is not delivered by the chosen priority mech.
    /// @param requestId Request Id.
    function revokeRequest(uint256 requestId) external;

    function maxDeliveryRate() external returns (uint256);

    function getPaymentType() external returns (uint8);

    /// @dev Gets finalized delivery rate for a request Id.
    /// @param requestId Request Id.
    /// @return Finalized delivery rate.
    function getFinalizedDeliveryRate(uint256 requestId) external returns (uint256);
}


// File contracts/interfaces/IServiceRegistry.sol


/// @dev Service Registry interface
interface IServiceRegistry {
    enum ServiceState {
        NonExistent,
        PreRegistration,
        ActiveRegistration,
        FinishedRegistration,
        Deployed,
        TerminatedBonded
    }

    /// @dev Gets the service instance from the map of services.
    /// @param serviceId Service Id.
    /// @return securityDeposit Registration activation deposit.
    /// @return multisig Service multisig address.
    /// @return configHash IPFS hashes pointing to the config metadata.
    /// @return threshold Agent instance signers threshold.
    /// @return maxNumAgentInstances Total number of agent instances.
    /// @return numAgentInstances Actual number of agent instances.
    /// @return state Service state.
    function mapServices(uint256 serviceId) external view returns (uint96 securityDeposit, address multisig,
        bytes32 configHash, uint32 threshold, uint32 maxNumAgentInstances, uint32 numAgentInstances, ServiceState state);
}


// File contracts/interfaces/IStaking.sol

/// @dev Staking interface
interface IStaking {
    enum StakingState {
        Unstaked,
        Staked,
        Evicted
    }

    // Service Info struct
    struct ServiceInfo {
        // Service multisig address
        address multisig;
        // Service owner
        address owner;
        // Service multisig nonces
        uint256[] nonces;
        // Staking start time
        uint256 tsStart;
        // Accumulated service staking reward
        uint256 reward;
        // Accumulated inactivity that might lead to the service eviction
        uint256 inactivity;
    }

    /// @dev Gets the service staking state.
    /// @param serviceId Service Id.
    /// @return stakingState Staking state of the service.
    function getStakingState(uint256 serviceId) external view returns (StakingState stakingState);

    /// @dev Gets staked service info.
    /// @param serviceId Service Id.
    /// @return sInfo Struct object with the corresponding service info.
    function getServiceInfo(uint256 serviceId) external view returns (ServiceInfo memory);
}

/// @dev Staking factory interface
interface IStakingFactory {
    /// @dev Verifies a service staking contract instance.
    /// @param instance Service staking proxy instance.
    /// @return True, if verification is successful.
    function verifyInstance(address instance) external view returns (bool);
}


// File contracts/MechMarketplace.sol

interface IMechFactory {
    /// @dev Registers service as a mech.
    /// @param mechManager Mech manager address.
    /// @param serviceRegistry Service registry address.
    /// @param serviceId Service id.
    /// @param payload Mech creation payload.
    /// @return mech The created mech instance address.
    function createMech(address mechManager, address serviceRegistry, uint256 serviceId, bytes memory payload)
        external returns (address mech);
}

// Mech delivery info struct
struct MechDelivery {
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
}

/// @title Mech Marketplace - Marketplace for posting and delivering requests served by agent mechs
/// @author Aleksandr Kuperman - <aleksandr.kuperman@valory.xyz>
/// @author Andrey Lebedev - <andrey.lebedev@valory.xyz>
/// @author Silvere Gangloff - <silvere.gangloff@valory.xyz>
contract MechMarketplace is IErrorsMarketplace {
    event CreateMech(address indexed mech, uint256 indexed serviceId);
    event OwnerUpdated(address indexed owner);
    event ImplementationUpdated(address indexed implementation);
    event MarketplaceParamsUpdated(uint256 fee, uint256 minResponseTimeout, uint256 maxResponseTimeout);
    event SetMechFactoryStatuses(address[] mechFactories, bool[] statuses);
    event SetPaymentTypeBalanceTrackers(uint8[] paymentTypes, address[] balanceTrackers);
    event MarketplaceRequest(address indexed requester, address indexed requestedMech, uint256 requestId, bytes data);
    event MarketplaceDeliver(address indexed priorityMech, address indexed actualMech, address indexed requester,
        uint256 requestId, bytes data);
    event DeliveryPaymentProcessed(uint256 indexed requestId, address indexed deliveryMech, uint256 deliveryRate, uint256 fee);

    enum RequestStatus {
        DoesNotExist,
        RequestedPriority,
        RequestedExpired,
        Delivered
    }

    // Contract version number
    string public constant VERSION = "1.1.0";
    // Code position in storage is keccak256("MECH_MARKETPLACE_PROXY") = "0xe6194b93a7bff0a54130ed8cd277223408a77f3e48bb5104a9db96d334f962ca"
    bytes32 public constant MECH_MARKETPLACE_PROXY = 0xe6194b93a7bff0a54130ed8cd277223408a77f3e48bb5104a9db96d334f962ca;
    // Domain separator type hash
    bytes32 public constant DOMAIN_SEPARATOR_TYPE_HASH =
        keccak256("EIP712Domain(string name,string version,uint256 chainId,address verifyingContract)");
    // Original domain separator value
    bytes32 public immutable domainSeparator;
    // Original chain Id
    uint256 public immutable chainId;
    // Mech karma contract address
    address public immutable karma;
    // Staking factory contract address
    address public immutable stakingFactory;
    // Service registry contract address
    address public immutable serviceRegistry;

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
    // Reentrancy lock
    uint256 internal _locked = 1;

    // Contract owner
    address public owner;

    // Map of request counts for corresponding requester
    mapping(address => uint256) public mapRequestCounts;
    // Map of delivery counts for corresponding requester
    mapping(address => uint256) public mapDeliveryCounts;
    // Map of delivery counts for mechs
    mapping(address => uint256) public mapAgentMechDeliveryCounts;
    // Map of delivery counts for corresponding mech service multisig
    mapping(address => uint256) public mapMechServiceDeliveryCounts;
    // Mapping of request Id => mech delivery information
    mapping(uint256 => MechDelivery) public mapRequestIdDeliveries;
    // Mapping of whitelisted mech factories
    mapping(address => bool) public mapMechFactories;
    // Map of mech => its creating factory
    mapping(address => address) public mapAgentMechFactories;
    // Map of mech type => balanceTracker address
    mapping(uint8 => address) public mapPaymentTypeBalanceTrackers;
    // Mapping of account nonces
    mapping(address => uint256) public mapNonces;
    // Set of mechs created by this marketplace
    address[] public setMechs;


    /// @dev MechMarketplace constructor.
    /// @param _serviceRegistry Service registry contract address.
    /// @param _stakingFactory Staking factory contract address.
    /// @param _karma Karma proxy contract address.
    constructor(
        address _serviceRegistry,
        address _stakingFactory,
        address _karma
    ) {
        // Check for zero address
        if (_serviceRegistry == address(0) || _stakingFactory == address(0) || _karma == address(0)) {
            revert ZeroAddress();
        }

        serviceRegistry = _serviceRegistry;
        stakingFactory = _stakingFactory;
        karma = _karma;

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
        if (newFee == 0 || newMinResponseTimeout == 0 || newMaxResponseTimeout == 0) {
            revert ZeroValue();
        }

        // Check for fee value
        if (newFee > 10_000) {
            revert Overflow(newFee, 10_000);
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

    /// @dev MechMarketplace initializer.
    /// @param _fee Marketplace fee.
    /// @param _minResponseTimeout Min response time in sec.
    /// @param _maxResponseTimeout Max response time in sec.
    function initialize(uint256 _fee, uint256 _minResponseTimeout, uint256 _maxResponseTimeout) external {
        if (owner != address(0)) {
            revert AlreadyInitialized();
        }

        _changeMarketplaceParams(_fee, _minResponseTimeout, _maxResponseTimeout);

        owner = msg.sender;
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
        // solhint-disable-next-line avoid-low-level-calls
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
    /// @param serviceId Service id.
    /// @param mechFactory Mech factory address.
    /// @return mech The created mech instance address.
    function create(uint256 serviceId, address mechFactory, bytes memory payload) external returns (address mech) {
        // Check for factory status
        if (!mapMechFactories[mechFactory]) {
            revert UnauthorizedAccount(mechFactory);
        }

        mech = IMechFactory(mechFactory).createMech(address(this), serviceRegistry, serviceId, payload);

        // This should never be the case
        if (mech == address(0)) {
            revert ZeroAddress();
        }

        // Record factory that created a mech
        mapAgentMechFactories[mech] = mechFactory;
        // Add mech address into the global set
        setMechs.push(mech);

        emit CreateMech(mech, serviceId);
    }

    /// @dev Sets mech factory statues.
    /// @param mechFactories Mech marketplace contract addresses.
    /// @param statuses Corresponding whitelisting statues.
    function setMechFactoryStatuses(address[] memory mechFactories, bool[] memory statuses) external {
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
    function setPaymentTypeBalanceTrackers(uint8[] memory paymentTypes, address[] memory balanceTrackers) external {
        // Check for the ownership
        if (msg.sender != owner) {
            revert OwnerOnly(msg.sender, owner);
        }

        if (paymentTypes.length != balanceTrackers.length) {
            revert WrongArrayLength(paymentTypes.length, balanceTrackers.length);
        }

        // Traverse all the mech types and balanceTrackers
        for (uint256 i = 0; i < paymentTypes.length; ++i) {
            // Check for zero address
            if (balanceTrackers[i] == address(0)) {
                revert ZeroAddress();
            }

            mapPaymentTypeBalanceTrackers[paymentTypes[i]] = balanceTrackers[i];
        }

        emit SetPaymentTypeBalanceTrackers(paymentTypes, balanceTrackers);
    }

    // TODO: leave optional fields or remove?
    /// @dev Registers a request.
    /// @notice The request is going to be registered for a specified priority mech.
    /// @param data Self-descriptive opaque data-blob.
    /// @param priorityMech Address of a priority mech.
    /// @param priorityMechStakingInstance Address of a priority mech staking instance (optional).
    /// @param priorityMechServiceId Priority mech service Id.
    /// @param requesterStakingInstance Staking instance of a service whose multisig posts a request (optional).
    /// @param requesterServiceId Corresponding service Id in the staking contract (optional).
    /// @param responseTimeout Relative response time in sec.
    /// @return requestId Request Id.
    function request(
        bytes memory data,
        address priorityMech,
        address priorityMechStakingInstance,
        uint256 priorityMechServiceId,
        address requesterStakingInstance,
        uint256 requesterServiceId,
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

        // Check that mech staking contract is different from requester one
        if (priorityMechStakingInstance == requesterStakingInstance && priorityMechStakingInstance != address(0)) {
            revert UnauthorizedAccount(priorityMechStakingInstance);
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

        // Check priority mech
        checkMech(priorityMech, priorityMechStakingInstance, priorityMechServiceId);

        // Check requester
        checkRequester(msg.sender, requesterStakingInstance, requesterServiceId);

        // Get the request Id
        requestId = getRequestId(msg.sender, data, mapNonces[msg.sender]);

        // Get balance tracker address
        uint8 mechPaymentType = IMech(priorityMech).getPaymentType();
        address balanceTracker = mapPaymentTypeBalanceTrackers[mechPaymentType];

        // Check and record mech delivery rate
        IBalanceTracker(balanceTracker).checkAndRecordDeliveryRate{value: msg.value}(priorityMech, msg.sender, requestId);

        // Update requester nonce
        mapNonces[msg.sender]++;

        // Get mech delivery info struct
        MechDelivery storage mechDelivery = mapRequestIdDeliveries[requestId];

        // Record priorityMech and response timeout
        mechDelivery.priorityMech = priorityMech;
        // responseTimeout from relative time to absolute time
        mechDelivery.responseTimeout = responseTimeout + block.timestamp;
        // Record request account
        mechDelivery.requester = msg.sender;
        // Record deliveryRate for request
        mechDelivery.deliveryRate = msg.value;

        // Increase mech requester karma
        IKarma(karma).changeRequesterMechKarma(msg.sender, priorityMech, 1);

        // Record the request count
        mapRequestCounts[msg.sender]++;
        // Increase the number of undelivered requests
        numUndeliveredRequests++;
        // Increase the total number of requests
        numTotalRequests++;

        // Process request by a specified priority mech
        IMech(priorityMech).requestFromMarketplace(msg.sender, data, requestId);

        emit MarketplaceRequest(msg.sender, priorityMech, requestId, data);

        _locked = 1;
    }

    /// @dev Delivers a request.
    /// @notice This function can only be called by the mech delivering the request.
    /// @param requestId Request id.
    /// @param requestData Self-descriptive opaque data-blob.
    /// @param deliveryMechStakingInstance Delivery mech staking instance address (optional).
    /// @param deliveryMechServiceId Mech service Id.
    function deliverMarketplace(
        uint256 requestId,
        bytes memory requestData,
        address deliveryMechStakingInstance,
        uint256 deliveryMechServiceId
    ) external {
        // Reentrancy guard
        if (_locked > 1) {
            revert ReentrancyGuard();
        }
        _locked = 2;

        // Check delivery mech and get its service multisig
        address mechServiceMultisig = checkMech(msg.sender, deliveryMechStakingInstance, deliveryMechServiceId);

        // Get mech delivery info struct
        MechDelivery storage mechDelivery = mapRequestIdDeliveries[requestId];
        address priorityMech = mechDelivery.priorityMech;

        // Check for request existence
        if (priorityMech == address(0)) {
            revert ZeroAddress();
        }

        // Check that the delivery mech is not a requester
        address requester = mechDelivery.requester;
        if (msg.sender == requester) {
            revert UnauthorizedAccount(msg.sender);
        }

        // Check that the request is not already delivered
        if (mechDelivery.deliveryMech != address(0)) {
            revert AlreadyDelivered(requestId);
        }

        // If delivery mech is different from the priority one
        if (priorityMech != msg.sender) {
            // Within the defined response time only a chosen priority mech is able to deliver
            if (block.timestamp > mechDelivery.responseTimeout) {
                // Decrease priority mech karma as the mech did not deliver
                IKarma(karma).changeMechKarma(priorityMech, -1);
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
        // Increase the amount of requester delivered requests
        mapDeliveryCounts[requester]++;
        // Increase the amount of mech delivery counts
        mapAgentMechDeliveryCounts[msg.sender]++;
        // Increase the amount of mech service multisig delivered requests
        mapMechServiceDeliveryCounts[mechServiceMultisig]++;

        // Increase mech karma that delivers the request
        IKarma(karma).changeMechKarma(msg.sender, 1);

        // Get balance tracker address
        uint8 mechPaymentType = IMech(priorityMech).getPaymentType();
        address balanceTracker = mapPaymentTypeBalanceTrackers[mechPaymentType];

        // Process payment
        IBalanceTracker(balanceTracker).finalizeDeliveryRate(msg.sender, mechDelivery.requester, requestId,
            mechDelivery.deliveryRate);

        emit MarketplaceDeliver(priorityMech, msg.sender, requester, requestId, requestData);

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
    ) public view returns (uint256 requestId) {
        requestId = uint256(keccak256(
            abi.encodePacked(
                "\x19\x01",
                getDomainSeparator(),
                keccak256(
                    abi.encode(
                        address(this),
                        account,
                        data,
                        nonce
                    )
                )
            )
        ));
    }

    /// @dev Checks for service validity and optionally for service staking correctness.
    /// @param stakingInstance Staking instance address.
    /// @param serviceId Service Id.
    /// @return multisig Service multisig address.
    function checkServiceAndGetMultisig(
        address stakingInstance,
        uint256 serviceId
    ) public view returns (address multisig) {
        // Check mech service Id
        if (stakingInstance == address(0)) {
            IServiceRegistry.ServiceState state;
            (, multisig, , , , , state) = IServiceRegistry(serviceRegistry).mapServices(serviceId);
            if (state != IServiceRegistry.ServiceState.Deployed) {
                revert WrongServiceState(uint256(state), serviceId);
            }
        } else {
            // Check staking instance
            checkStakingInstance(stakingInstance, serviceId);

            // Get the staked service info for the mech
            IStaking.ServiceInfo memory serviceInfo = IStaking(stakingInstance).getServiceInfo(serviceId);
            multisig = serviceInfo.multisig;
        }
    }

    /// @dev Checks for staking instance contract validity.
    /// @param stakingInstance Staking instance address.
    /// @param serviceId Service Id.
    function checkStakingInstance(address stakingInstance, uint256 serviceId) public view {
        // Check that the mech staking instance is valid
        if (!IStakingFactory(stakingFactory).verifyInstance(stakingInstance)) {
            revert UnauthorizedAccount(stakingInstance);
        }

        // Check if the mech service is staked
        IStaking.StakingState state = IStaking(stakingInstance).getStakingState(serviceId);
        if (state != IStaking.StakingState.Staked) {
            revert ServiceNotStaked(stakingInstance, serviceId);
        }
    }

    /// @dev Checks for mech validity.
    /// @dev mech Agent mech contract address.
    /// @param mechStakingInstance Agent mech staking instance address.
    /// @param mechServiceId Agent mech service Id.
    /// @return multisig Service multisig address.
    function checkMech(
        address mech,
        address mechStakingInstance,
        uint256 mechServiceId
    ) public view returns (address multisig) {
        // Check for zero value
        if (mechServiceId == 0) {
            revert ZeroValue();
        }

        // Check mech validity as it must be created and recorded via this marketplace
        if (mapAgentMechFactories[mech] == address(0)) {
            revert UnauthorizedAccount(mech);
        }

        // Check mech service Id and staking instance, if applicable
        multisig = checkServiceAndGetMultisig(mechStakingInstance, mechServiceId);

        // Check that service multisig is the priority mech service multisig
        if (!IMech(mech).isOperator(multisig)) {
            revert UnauthorizedAccount(mech);
        }
    }

    /// @dev Checks for requester validity.
    /// @dev requester Requester contract address.
    /// @param requesterStakingInstance Requester staking instance address.
    /// @param requesterServiceId Requester service Id.
    function checkRequester(
        address requester,
        address requesterStakingInstance,
        uint256 requesterServiceId
    ) public view {
        // Check for requester service
        if (requesterServiceId > 0) {
            address multisig = checkServiceAndGetMultisig(requesterStakingInstance, requesterServiceId);

            // Check staked service multisig
            if (multisig != requester) {
                revert OwnerOnly(requester, multisig);
            }
        } else if (requesterStakingInstance != address(0)) {
            // Check for inconsistency between zero service Id and non-zero staking instance
            revert ZeroValue();
        }
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

    /// @dev Gets the requests count for a specific account.
    /// @param account Account address.
    /// @return Requests count.
    function getRequestsCount(address account) external view returns (uint256) {
        return mapRequestCounts[account];
    }

    /// @dev Gets the deliveries count for a specific account.
    /// @param account Account address.
    /// @return Deliveries count.
    function getDeliveriesCount(address account) external view returns (uint256) {
        return mapDeliveryCounts[account];
    }

    // TODO Check if needed
    /// @dev Gets deliveries count for a specific mech.
    /// @param agentMech Agent mech address.
    /// @return Deliveries count.
    function getAgentMechDeliveriesCount(address agentMech) external view returns (uint256) {
        return mapAgentMechDeliveryCounts[agentMech];
    }

    /// @dev Gets deliveries count for a specific mech service multisig.
    /// @param mechServiceMultisig Agent mech service multisig address.
    /// @return Deliveries count.
    function getMechServiceDeliveriesCount(address mechServiceMultisig) external view returns (uint256) {
        return mapMechServiceDeliveryCounts[mechServiceMultisig];
    }

    /// @dev Gets mech delivery info.
    /// @param requestId Request Id.
    /// @return Mech delivery info.
    function getMechDeliveryInfo(uint256 requestId) external view returns (MechDelivery memory) {
        return mapRequestIdDeliveries[requestId];
    }

    /// @dev Gets  global number of created mechs.
    /// @return Number of mechs in a global set.
    function getNumMechs() external view returns (uint256) {
        return setMechs.length;
    }
}
