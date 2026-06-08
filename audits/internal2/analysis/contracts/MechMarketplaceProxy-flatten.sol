// Sources flattened with hardhat v2.22.13 https://hardhat.org

// SPDX-License-Identifier: MIT

pragma solidity ^0.8.0;

/// @dev Zero implementation address.
error ZeroImplementationAddress();

/// @dev Zero initialization data.
error ZeroData();

/// @dev Proxy initialization failed.
error InitializationFailed();

/*
* This is a MechMarketplace proxy contract.
* Proxy implementation is created based on the Universal Upgradeable Proxy Standard (UUPS) EIP-1822.
* The implementation address must be located in a unique storage slot of the proxy contract.
* The upgrade logic must be located in the implementation contract.
* Special mechMarketplace implementation address slot is produced by hashing the "MECH_MARKETPLACE_PROXY"
* string in order to make the slot unique.
* The fallback() implementation for all the delegatecall-s is inspired by the Gnosis Safe set of contracts.
*/

/// @title MechMarketplaceProxy - Smart contract for mech marketplace proxy
/// @author Aleksandr Kuperman - <aleksandr.kuperman@valory.xyz>
/// @author Andrey Lebedev - <andrey.lebedev@valory.xyz>
contract MechMarketplaceProxy {
    // Code position in storage is keccak256("MECH_MARKETPLACE_PROXY") = "0xe6194b93a7bff0a54130ed8cd277223408a77f3e48bb5104a9db96d334f962ca"
    bytes32 public constant MECH_MARKETPLACE_PROXY = 0xe6194b93a7bff0a54130ed8cd277223408a77f3e48bb5104a9db96d334f962ca;

    /// @dev MechMarketplaceProxy constructor.
    /// @param implementation MechMarketplace implementation address.
    /// @param mechMarketplaceData MechMarketplace initialization data.
    constructor(address implementation, bytes memory mechMarketplaceData) {
        // Check for the zero address, since the delegatecall works even with the zero one
        if (implementation == address(0)) {
            revert ZeroImplementationAddress();
        }

        // Check for the zero data
        if (mechMarketplaceData.length == 0) {
            revert ZeroData();
        }

        // Store the mechMarketplace implementation address
        // solhint-disable-next-line avoid-low-level-calls
        assembly {
            sstore(MECH_MARKETPLACE_PROXY, implementation)
        }

        // Initialize proxy tokenomics storage
        (bool success, ) = implementation.delegatecall(mechMarketplaceData);
        if (!success) {
            revert InitializationFailed();
        }
    }

    /// @dev Delegatecall to all the incoming data.
    fallback() external {
        // solhint-disable-next-line avoid-low-level-calls
        assembly {
            let implementation := sload(MECH_MARKETPLACE_PROXY)
            calldatacopy(0, 0, calldatasize())
            let success := delegatecall(gas(), implementation, 0, calldatasize(), 0, 0)
            returndatacopy(0, 0, returndatasize())
            if eq(success, 0) {
                revert(0, returndatasize())
            }
            return(0, returndatasize())
        }
    }

    /// @dev Gets the implementation address.
    /// @return implementation Implementation address.
    function getImplementation() external view returns (address implementation) {
        // solhint-disable-next-line avoid-low-level-calls
        assembly {
            implementation := sload(MECH_MARKETPLACE_PROXY)
        }
    }
}
