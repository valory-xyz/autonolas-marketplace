// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import {BalanceTrackerFixedPriceNative, ZeroAddress} from "../../mechs/native/BalanceTrackerFixedPriceNative.sol";
import {ZeroValue, InsufficientBalance} from "../../BalanceTrackerBase.sol";

interface IERC1155 {
    /// @dev Gets the amount of tokens owned by a specified account.
    /// @param account Account address.
    /// @param tokenId Token Id.
    /// @return Amount of tokens owned.
    function balanceOf(address account, uint256 tokenId) external view returns (uint256);

    /// @dev Burns a specified amount of account's tokens.
    /// @param account Account address.
    /// @param tokenId Token Id.
    /// @param amount Amount of tokens.
    function burn(address account, uint256 tokenId, uint256 amount) external;
}

/// @dev Only `owner` has a privilege, but the `sender` was provided.
/// @param sender Sender address.
/// @param owner Required sender address as an owner.
error OwnerOnly(address sender, address owner);

/// @dev Value overflow.
/// @param provided Overflow value.
/// @param max Maximum possible value.
error Overflow(uint256 provided, uint256 max);

/// @dev No incoming msg.value is allowed.
/// @param amount Value amount.
error NoDepositAllowed(uint256 amount);

/// @title BalanceTrackerFixedPriceNative - smart contract for tracking mech and requester subscription balances based on native token
contract BalanceTrackerNvmSubscriptionNative is BalanceTrackerFixedPriceNative {
    event SubscriptionSet(address indexed token, uint256 indexed tokenId);
    event RequesterCreditsRedeemed(address indexed account, uint256 amount);

    // Subscription NFT
    address public subscriptionNFT;
    // Subscription token Id
    uint256 public subscriptionTokenId;
    // Credit to token ratio in 1e18 form
    // N credits for M tokens, tokenCreditRatio = M * 10^18 / N
    uint256 public tokenCreditRatio;

    // Current contract balance
    uint256 public trackerBalance;
    // Temporary owner address
    address public owner;

    /// @dev BalanceTrackerSubscription constructor.
    /// @param _mechMarketplace Mech marketplace address.
    /// @param _drainer Drainer address.
    /// @param _wrappedNativeToken Wrapped native token address.
    constructor(address _mechMarketplace, address _drainer, address _wrappedNativeToken)
        BalanceTrackerFixedPriceNative(_mechMarketplace, _drainer, _wrappedNativeToken)
    {
        owner = msg.sender;
    }

    /// @dev Adjusts initial requester balance accounting for max request delivery rate (credit).
    /// @param balance Initial requester balance.
    /// @param maxDeliveryRate Max delivery rate.
    function _adjustInitialBalance(
        address requester,
        uint256 balance,
        uint256 maxDeliveryRate,
        bytes memory
    ) internal virtual override returns (uint256) {
        // Get requester actual subscription balance
        uint256 subscriptionBalance = IERC1155(subscriptionNFT).balanceOf(requester, subscriptionTokenId);

        uint256 totalBalance = balance + subscriptionBalance;

        // Check the request delivery rate for a fixed price
        if (totalBalance < maxDeliveryRate) {
            revert InsufficientBalance(totalBalance, maxDeliveryRate);
        }

        // Calculate how many actual credits need to burn accounting for discount balance
        if (balance > maxDeliveryRate) {
            balance -= maxDeliveryRate;
        } else {
            maxDeliveryRate -= balance;
            balance = 0;
            IERC1155(subscriptionNFT).burn(requester, subscriptionTokenId, maxDeliveryRate);

            emit RequesterCreditsRedeemed(requester, maxDeliveryRate);
        }

        return balance;
    }

    /// @dev Gets native token value or restricts receiving one.
    /// @notice Since the contract is subscription based, no additional funding can be sent when posting a request.
    /// @return Received value.
    function _getOrRestrictNativeValue() internal virtual override returns (uint256) {
        // Check for msg.value
        if (msg.value > 0) {
            revert NoDepositAllowed(msg.value);
        }

        return 0;
    }

    /// @dev Process mech payment.
    /// @param mech Mech address.
    /// @return mechPayment Mech payment.
    function _processPayment(address mech) internal virtual override returns (uint256, uint256) {
        // Get mech balance
        uint256 balance = mapMechBalances[mech];
        // Check for zero value
        if (balance == 0) {
            revert ZeroValue();
        }

        // Convert mech credits balance into tokens
        balance = (balance * tokenCreditRatio) / 1e18;
        mapMechBalances[mech] = balance;

        // Check current contract balance
        if (balance > trackerBalance) {
            revert Overflow(balance, trackerBalance);
        }

        // Proceed with the default mech payment logic
        return super._processPayment(mech);
    }

    /// @dev Sets subscription.
    /// @param _subscriptionNFT Subscription NFT address.
    /// @param _subscriptionTokenId Subscription token Id.
    /// @param _tokenCreditRatio Token to credit ratio in 1e18 form.
    function setSubscription(address _subscriptionNFT, uint256 _subscriptionTokenId, uint256 _tokenCreditRatio) external {
        // Check for ownership
        if (msg.sender != owner) {
            revert OwnerOnly(msg.sender, owner);
        }

        if (_subscriptionNFT == address(0)) {
            revert ZeroAddress();
        }

        if (_subscriptionTokenId == 0 || _tokenCreditRatio == 0) {
            revert ZeroValue();
        }

        subscriptionNFT = _subscriptionNFT;
        subscriptionTokenId = _subscriptionTokenId;
        tokenCreditRatio = _tokenCreditRatio;

        // Reset owner after setting subscription params
        owner = address(0);

        emit SubscriptionSet(_subscriptionNFT, _subscriptionTokenId);
    }

    /// @dev Deposits funds reflecting subscription.
    receive() external virtual override payable {
        // Record actual balance
        trackerBalance += msg.value;

        emit Deposit(msg.sender, address(0), msg.value);
    }

    /// @dev Deposits token funds for requester.
    function depositFor(address) external payable virtual override {
        revert NoDepositAllowed(msg.value);
    }
}