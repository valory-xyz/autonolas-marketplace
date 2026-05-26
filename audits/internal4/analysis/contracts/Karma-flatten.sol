// Sources flattened with hardhat v2.22.17 https://hardhat.org

// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

/// @dev Only `owner` has a privilege, but the `sender` was provided.
/// @param sender Sender address.
/// @param owner Required sender address as an owner.
error OwnerOnly(address sender, address owner);

/// @dev Provided zero address.
error ZeroAddress();

/// @dev The contract is already initialized.
error AlreadyInitialized();

/// @dev Account is unauthorized.
/// @param account Account address.
error UnauthorizedAccount(address account);

/// @dev Wrong length of two arrays.
/// @param numValues1 Number of values in a first array.
/// @param numValues2 Number of values in a second array.
error WrongArrayLength(uint256 numValues1, uint256 numValues2);

/// @title Karma - Karma contract for agent mechs
contract Karma {
    event ImplementationUpdated(address indexed implementation);
    event OwnerUpdated(address indexed owner);
    event SetMechMarketplaceStatuses(address[] mechMarketplaces, bool[] statuses);
    event MechKarmaChanged(address indexed mech, int256 karmaChange);
    event RequesterMechKarmaChanged(address indexed requester, address indexed mech, int256 karmaChange);

    // Version number
    string public constant VERSION = "1.0.0";
    // Code position in storage is keccak256("KARMA_PROXY") = "0x1e4b6d67098d4183ce03b91c95f9376a98c5440ec22f2cf171d6dca04a5a29d8"
    bytes32 public constant KARMA_PROXY = 0x1e4b6d67098d4183ce03b91c95f9376a98c5440ec22f2cf171d6dca04a5a29d8;

    // Contract owner
    address public owner;

    // Mapping of whitelisted marketplaces
    mapping(address => bool) public mapMechMarketplaces;
    // Mapping of mech address => karma
    mapping(address => int256) public mapMechKarma;
    // Mapping of requester address => mech address => karma
    mapping(address => mapping(address => int256)) public mapRequesterMechKarma;

    /// @dev Karma initializer.
    function initialize() external{
        if (owner != address(0)) {
            revert AlreadyInitialized();
        }

        owner = msg.sender;
    }

    /// @dev Changes the karma implementation contract address.
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

        // Store the karma implementation address
        // solhint-disable-next-line avoid-low-level-calls
        assembly {
            sstore(KARMA_PROXY, newImplementation)
        }

        emit ImplementationUpdated(newImplementation);
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

    /// @dev Sets mech marketplace statues.
    /// @param mechMarketplaces Mech marketplace contract addresses.
    /// @param statuses Corresponding whitelisting statues.
    function setMechMarketplaceStatuses(address[] memory mechMarketplaces, bool[] memory statuses) external {
        // Check for the ownership
        if (msg.sender != owner) {
            revert OwnerOnly(msg.sender, owner);
        }

        if (mechMarketplaces.length != statuses.length) {
            revert WrongArrayLength(mechMarketplaces.length, statuses.length);
        }

        // Traverse all the mech marketplaces and statuses
        for (uint256 i = 0; i < mechMarketplaces.length; ++i) {
            if (mechMarketplaces[i] == address(0)) {
                revert ZeroAddress();
            }

            mapMechMarketplaces[mechMarketplaces[i]] = statuses[i];
        }

        emit SetMechMarketplaceStatuses(mechMarketplaces, statuses);
    }

    /// @dev Changes agent mech karma.
    /// @param mech Agent mech address.
    /// @param karmaChange Karma change value.
    function changeMechKarma(address mech, int256 karmaChange) external {
        // Check for marketplace access
        if (!mapMechMarketplaces[msg.sender]) {
            revert UnauthorizedAccount(msg.sender);
        }

        // Change mech karma
        mapMechKarma[mech] += karmaChange;

        emit MechKarmaChanged(mech, karmaChange);
    }

    /// @dev Changes requester -> agent mech karma.
    /// @param requester Requester address.
    /// @param mech Agent mech address.
    /// @param karmaChange Karma change value.
    function changeRequesterMechKarma(address requester, address mech, int256 karmaChange) external {
        // Check for marketplace access
        if (!mapMechMarketplaces[msg.sender]) {
            revert UnauthorizedAccount(msg.sender);
        }

        // Change requester mech karma
        mapRequesterMechKarma[requester][mech] += karmaChange;

        emit RequesterMechKarmaChanged(requester, mech, karmaChange);
    }

    /// @dev Gets the implementation address.
    /// @return implementation Implementation address.
    function getImplementation() external view returns (address implementation) {
        // solhint-disable-next-line avoid-low-level-calls
        assembly {
            implementation := sload(KARMA_PROXY)
        }
    }
}
