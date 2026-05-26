// Sources flattened with hardhat v2.21.0 https://hardhat.org

// SPDX-License-Identifier: MIT
pragma solidity ^0.8.25;

/// @dev Zero implementation address.
error ZeroImplementationAddress();

/*
* This is a Karma proxy contract.
* Proxy implementation is created based on the Universal Upgradeable Proxy Standard (UUPS) EIP-1822.
* The implementation address must be located in a unique storage slot of the proxy contract.
* The upgrade logic must be located in the implementation contract.
* Special karma implementation address slot is produced by hashing the "KARMA_PROXY"
* string in order to make the slot unique.
* The fallback() implementation for all the delegatecall-s is inspired by the Gnosis Safe set of contracts.
*/

/// @title KarmaProxy - Smart contract for karma proxy
/// @author Aleksandr Kuperman - <aleksandr.kuperman@valory.xyz>
/// @author Andrey Lebedev - <andrey.lebedev@valory.xyz>
/// @author Mariapia Moscatiello - <mariapia.moscatiello@valory.xyz>
contract KarmaProxy {
    // Code position in storage is keccak256("KARMA_PROXY") = "0x1e4b6d67098d4183ce03b91c95f9376a98c5440ec22f2cf171d6dca04a5a29d8"
    bytes32 public constant KARMA_PROXY = 0x1e4b6d67098d4183ce03b91c95f9376a98c5440ec22f2cf171d6dca04a5a29d8;

    /// @dev KarmaProxy constructor.
    /// @param implementation Karma implementation address.
    constructor(address implementation) {
        // Check for the zero address, since the delegatecall works even with the zero one
        if (implementation == address(0)) {
            revert ZeroImplementationAddress();
        }

        // Store the karma implementation address
        assembly {
            sstore(KARMA_PROXY, implementation)
        }
    }

    /// @dev Delegatecall to all the incoming data.
    fallback() external {
        assembly {
            let implementation := sload(KARMA_PROXY)
            calldatacopy(0, 0, calldatasize())
            let success := delegatecall(gas(), implementation, 0, calldatasize(), 0, 0)
            returndatacopy(0, 0, returndatasize())
            if eq(success, 0) {
                revert(0, returndatasize())
            }
            return(0, returndatasize())
        }
    }
}
