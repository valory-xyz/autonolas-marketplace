// Sources flattened with hardhat v2.22.17 https://hardhat.org

// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

/// @dev Mech interface
interface IMech {
    /// @dev Registers a request by a marketplace.
    /// @param account Requester account address.
    /// @param data Self-descriptive opaque data-blob.
    /// @param requestId Request Id.
    function requestFromMarketplace(address account, bytes memory data, uint256 requestId) external;

    /// @dev Revokes the request from the mech that does not deliver it.
    /// @notice Only marketplace can call this function if the request is not delivered by the chosen priority mech.
    /// @param requestId Request Id.
    function revokeRequest(uint256 requestId) external;

    /// @dev Gets mech max delivery rate.
    /// @return Mech maximum delivery rate.
    function maxDeliveryRate() external returns (uint256);

    /// @dev Gets mech payment type hash.
    /// @return Mech payment type hash.
    function paymentType() external returns (bytes32);

    /// @dev Gets finalized delivery rate for a request Id.
    /// @param requestId Request Id.
    /// @return Finalized delivery rate.
    function getFinalizedDeliveryRate(uint256 requestId) external returns (uint256);

    /// @dev Gets mech token Id (service Id).
    /// @return serviceId Service Id.
    function tokenId() external view returns (uint256);

    /// @dev Gets mech operator (service multisig).
    /// @return Service multisig address.
    function getOperator() external view returns (address);

    /// @dev Checks the mech operator (service multisig).
    /// @param multisig Service multisig being checked against.
    /// @return True, if mech service multisig matches the provided one.
    function isOperator(address multisig) external view returns (bool);
}


// File contracts/BalanceTrackerFixedPriceBase.sol


interface IMechMarketplace {
    function fee() external returns(uint256);
}

/// @dev Only `marketplace` has a privilege, but the `sender` was provided.
/// @param sender Sender address.
/// @param marketplace Required marketplace address.
error MarketplaceOnly(address sender, address marketplace);

/// @dev Provided zero address.
error ZeroAddress();

/// @dev Provided zero value.
error ZeroValue();

/// @dev Not enough balance to cover costs.
/// @param current Current balance.
/// @param required Required balance.
error InsufficientBalance(uint256 current, uint256 required);

/// @dev Caught reentrancy violation.
error ReentrancyGuard();

/// @dev Account is unauthorized.
/// @param account Account address.
error UnauthorizedAccount(address account);

/// @dev No incoming msg.value is allowed.
/// @param amount Value amount.
error NoDepositAllowed(uint256 amount);

/// @dev Payload length is incorrect.
/// @param provided Provided payload length.
/// @param expected Expected payload length.
error InvalidPayloadLength(uint256 provided, uint256 expected);

/// @dev Failure of a transfer.
/// @param token Address of a token.
/// @param from Address `from`.
/// @param to Address `to`.
/// @param amount Amount value.
error TransferFailed(address token, address from, address to, uint256 amount);

abstract contract BalanceTrackerFixedPriceBase {
    event MechPaymentCalculated(address indexed mech, uint256 indexed requestId, uint256 deliveryRate, uint256 rateDiff);
    event Deposit(address indexed account, address indexed token, uint256 amount);
    event Withdraw(address indexed account, address indexed token, uint256 amount);
    event Drained(address indexed token, uint256 collectedFees);

    // Max marketplace fee factor (100%)
    uint256 public constant MAX_FEE_FACTOR = 10_000;

    // Mech marketplace address
    address public immutable mechMarketplace;
    // Buy back burner address
    address public immutable buyBackBurner;
    // Collected fees
    uint256 public collectedFees;
    // Reentrancy lock
    uint256 internal _locked = 1;

    // Map of requester => current debit balance
    mapping(address => uint256) public mapRequesterBalances;
    // Map of mech => => current debit balance
    mapping(address => uint256) public mapMechBalances;

    /// @dev BalanceTrackerFixedPrice constructor.
    /// @param _mechMarketplace Mech marketplace address.
    /// @param _buyBackBurner Buy back burner address.
    constructor(address _mechMarketplace, address _buyBackBurner) {
        // Check for zero address
        if (_mechMarketplace == address(0) || _buyBackBurner == address(0)) {
            revert ZeroAddress();
        }

        mechMarketplace = _mechMarketplace;
        buyBackBurner = _buyBackBurner;
    }

    /// @dev Drains specified amount.
    function _drain(uint256 amount) internal virtual;

    /// @dev Gets native token value or restricts receiving one.
    /// @return Received value.
    function _getOrRestrictNativeValue() internal virtual returns (uint256);

    /// @dev Gets required token funds.
    /// @param requester Requester address.
    /// @param amount Token amount.
    /// @return Received amount.
    function _getRequiredFunds(address requester, uint256 amount) internal virtual returns (uint256);

    /// @dev Process mech payment.
    /// @param mech Mech address.
    /// @return mechPayment Mech payment.
    /// @return marketplaceFee Marketplace fee.
    function _processPayment(address mech) internal returns (uint256 mechPayment, uint256 marketplaceFee) {
        // Reentrancy guard
        if (_locked > 1) {
            revert ReentrancyGuard();
        }
        _locked = 2;

        // Get mech balance
        uint256 balance = mapMechBalances[mech];
        // If balance is 1, the marketplace fee is still 1, and thus mech payment will be zero
        if (balance < 2) {
            revert ZeroValue();
        }

        // Calculate mech payment and marketplace fee
        uint256 fee = IMechMarketplace(mechMarketplace).fee();

        // If requested balance is too small, charge the minimal fee
        // ceil(a, b) = (a + b - 1) / b
        // This formula will always get at least a fee of 1
        marketplaceFee = (balance * fee + (MAX_FEE_FACTOR - 1)) / MAX_FEE_FACTOR;

        // Calculate mech payment
        mechPayment = balance - marketplaceFee;

        // Check for zero value, although this must never happen
        if (marketplaceFee == 0 || mechPayment == 0) {
            revert ZeroValue();
        }

        // Adjust marketplace fee
        collectedFees += marketplaceFee;

        // Clear balances
        mapMechBalances[mech] = 0;

        // Process withdraw
        _withdraw(mech, mechPayment);

        _locked = 1;
    }

    /// @dev Withdraws funds.
    /// @param account Account address.
    /// @param amount Token amount.
    function _withdraw(address account, uint256 amount) internal virtual;

    /// @dev Checks and records delivery rate.
    /// @param requester Requester address.
    /// @param maxDeliveryRate Request max delivery rate.
    function checkAndRecordDeliveryRate(
        address requester,
        uint256 maxDeliveryRate,
        bytes memory
    ) external payable {
        // Reentrancy guard
        if (_locked > 1) {
            revert ReentrancyGuard();
        }
        _locked = 2;

        // Check for marketplace access
        if (msg.sender != mechMarketplace) {
            revert MarketplaceOnly(msg.sender, mechMarketplace);
        }

        // Check for native value
        uint256 initAmount = _getOrRestrictNativeValue();

        // Get account balance
        uint256 balance = mapRequesterBalances[requester] + initAmount;

        // Check the request delivery rate for a fixed price
        if (balance < maxDeliveryRate) {
            // Get balance difference
            uint256 balanceDiff = maxDeliveryRate - balance;
            // Adjust balance
            balance += _getRequiredFunds(requester, balanceDiff);
        }

        if (balance < maxDeliveryRate) {
            revert InsufficientBalance(balance, maxDeliveryRate);
        }

        // Adjust account balance
        balance -= maxDeliveryRate;
        mapRequesterBalances[requester] = balance;

        _locked = 1;
    }

    /// @dev Finalizes mech delivery rate based on requested and actual ones.
    /// @param mech Delivery mech address.
    /// @param requester Requester address.
    /// @param requestId Request Id.
    /// @param maxDeliveryRate Requested max delivery rate.
    function finalizeDeliveryRate(address mech, address requester, uint256 requestId, uint256 maxDeliveryRate) external {
        // Check for marketplace access
        if (msg.sender != mechMarketplace) {
            revert MarketplaceOnly(msg.sender, mechMarketplace);
        }

        // Get actual delivery rate
        uint256 actualDeliveryRate = IMech(mech).getFinalizedDeliveryRate(requestId);

        // Check for zero value
        if (actualDeliveryRate == 0) {
            revert ZeroValue();
        }

        // Check for delivery rate difference
        uint256 rateDiff;
        if (maxDeliveryRate > actualDeliveryRate) {
            // Return back requester overpayment debit
            rateDiff = maxDeliveryRate - actualDeliveryRate;
            mapRequesterBalances[requester] += rateDiff;
        } else {
            // Limit the rate by the max chosen one as that is what the requester agreed on
            actualDeliveryRate = maxDeliveryRate;
        }

        // Record payment into mech balance
        mapMechBalances[mech] += actualDeliveryRate;

        emit MechPaymentCalculated(mech, requestId, actualDeliveryRate, rateDiff);
    }

    /// @dev Drains collected fees by sending them to a Buy back burner contract.
    function drain() external {
        // Reentrancy guard
        if (_locked > 1) {
            revert ReentrancyGuard();
        }
        _locked = 2;

        uint256 localCollectedFees = collectedFees;

        // Check for zero value
        if (localCollectedFees == 0) {
            revert ZeroValue();
        }

        collectedFees = 0;

        // Drain
        _drain(localCollectedFees);

        _locked = 1;
    }

    /// @dev Processes mech payment by mech service multisig.
    /// @param mech Mech address.
    /// @return Mech payment.
    /// @return Marketplace fee.
    function processPaymentByMultisig(address mech) external returns (uint256, uint256) {
        // Check for mech service multisig address
        if (!IMech(mech).isOperator(msg.sender)) {
            revert UnauthorizedAccount(msg.sender);
        }

        return _processPayment(mech);
    }

    /// @dev Processes mech payment.
    /// @return Mech payment.
    /// @return Marketplace fee.
    function processPayment() external returns (uint256, uint256) {
        return _processPayment(msg.sender);
    }

    /// @dev Withdraws funds for a specific requester account.
    function withdraw() external {
        // Reentrancy guard
        if (_locked > 1) {
            revert ReentrancyGuard();
        }
        _locked = 2;

        // Get account balance
        uint256 balance = mapRequesterBalances[msg.sender];
        if (balance == 0) {
            revert ZeroValue();
        }

        // Clear balances
        mapRequesterBalances[msg.sender] = 0;

        // Process withdraw
        _withdraw(msg.sender, balance);

        _locked = 1;
    }
}
