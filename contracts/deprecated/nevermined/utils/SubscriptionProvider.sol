// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

interface NVM {
    enum ConditionState { Uninitialized, Unfulfilled, Fulfilled, Aborted }

    /// @notice Settles payment from escrow to target receivers via NVM escrowPaymentCondition contract.
    function fulfill(bytes32 _agreementId, bytes32 _did, uint256[] memory _amounts, address[] memory _receivers,
        address _returnAddress, address _lockPaymentAddress, address _tokenAddress, bytes32 _lockCondition,
        bytes32 _releaseCondition) external returns (ConditionState);

    /// @notice fulfill the transfer NFT condition
    /// @dev Fulfill method transfer a certain amount of NFTs
    ///       to the _nftReceiver address in the DIDRegistry contract.
    ///       When true then fulfill the condition
    /// @param _agreementId agreement identifier
    /// @param _did refers to the DID in which secret store will issue the decryption keys
    /// @param _nftReceiver is the address of the account to receive the NFT
    /// @param _nftAmount amount of NFTs to transfer
    /// @param _lockPaymentCondition lock payment condition identifier
    /// @param _nftHolder is the address of the account to receive the NFT
    /// @param _nftContractAddress the address of the ERC-1155 NFT contract
    /// @param _transfer if yes it does a transfer if false it mints the NFT
    /// @param _expirationBlock Block in which the token expires. If zero means no expiration
    /// @return condition state (Fulfilled/Aborted)
    function fulfillForDelegate(bytes32 _agreementId, bytes32 _did, address _nftHolder, address _nftReceiver,
        uint256 _nftAmount, bytes32 _lockPaymentCondition, address _nftContractAddress, bool _transfer,
        uint256 _expirationBlock) external returns (ConditionState);

    /// @notice addDIDProvider add new DID provider.
    /// @dev Adds new DID provider to the providers list. A provider is any entity that can serve the registered asset
    /// @param _did refers to decentralized identifier (a bytes32 length ID).
    /// @param _provider provider's address.
    function addDIDProvider(bytes32 _did, address _provider) external;

    /// @notice removeDIDProvider delete an existing DID provider.
    /// @param _did refers to decentralized identifier (a bytes32 length ID).
    /// @param _provider provider's address.
    function removeDIDProvider(bytes32 _did, address _provider) external;

    /// @dev Transfers DID ownership.
    /// @param _did refers to decentralized identifier (a bytes32 length ID).
    /// @param _newOwner new owner address.
    function transferDIDOwnership(bytes32 _did, address _newOwner) external;
}

/// @dev Only `owner` has a privilege, but the `sender` was provided.
/// @param sender Sender address.
/// @param owner Required sender address as an owner.
error OwnerOnly(address sender, address owner);

/// @dev Provided zero address.
error ZeroAddress();

struct FulfillParams {
    uint256[] amounts;
    address[] receivers;
    address returnAddress;
    address lockPaymentAddress;
    address tokenAddress;
    bytes32 lockCondition;
    bytes32 releaseCondition;
}

struct FulfillForDelegateParams {
    address nftHolder;
    address nftReceiver;
    uint256 nftAmount;
    bytes32 lockPaymentCondition;
    address nftContractAddress;
    bool transfer;
    uint256 expirationBlock;
}

/// @title SubscriptionProvider - smart contract for subscription provider management
contract SubscriptionProvider {
    event OwnerUpdated(address indexed owner);

    // DID registry address
    address public immutable didRegistry;
    // Transfer NFT Condition address
    address public immutable transferNFTCondition;
    // Escrow Payment Condition address
    address public immutable escrowPaymentCondition;

    // Temporary owner address
    address public owner;

    /// @dev SubscriptionProvider constructor.
    constructor(address _didRegistry, address _transferNFTCondition, address _escrowPaymentCondition) {
        didRegistry = _didRegistry;
        transferNFTCondition = _transferNFTCondition;
        escrowPaymentCondition = _escrowPaymentCondition;

        owner = msg.sender;
    }

    /// @dev Changes contract owner address.
    /// @param newOwner Address of a new owner.
    function changeOwner(address newOwner) external {
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

    /// @dev Fulfills subscription NFT condition.
    /// @param agreementId Agreement identifier.
    /// @param did Refers to the DID in which secret store will issue the decryption keys.
    /// @param fulfillForDelegateParams Fulfill for delegate params.
    /// @param fulfillParams Fulfill params.
    function fulfill(
        bytes32 agreementId,
        bytes32 did,
        FulfillForDelegateParams memory fulfillForDelegateParams,
        FulfillParams memory fulfillParams
    ) external returns (NVM.ConditionState fulfillForDelegateConditionState, NVM.ConditionState fulfillConditionState) {
        fulfillForDelegateConditionState = NVM(transferNFTCondition).fulfillForDelegate(agreementId, did,
            fulfillForDelegateParams.nftHolder, fulfillForDelegateParams.nftReceiver, fulfillForDelegateParams.nftAmount,
            fulfillForDelegateParams.lockPaymentCondition, fulfillForDelegateParams.nftContractAddress,
            fulfillForDelegateParams.transfer, fulfillForDelegateParams.expirationBlock);

        fulfillConditionState = NVM(escrowPaymentCondition).fulfill(agreementId, did, fulfillParams.amounts,
            fulfillParams.receivers, fulfillParams.returnAddress, fulfillParams.lockPaymentAddress,
            fulfillParams.tokenAddress, fulfillParams.lockCondition, fulfillParams.releaseCondition);
    }

    /// @dev Adds new DID provider.
    /// @param did Refers to decentralized identifier (a bytes32 length ID).
    /// @param provider Provider address.
    function addDIDProvider(bytes32 did, address provider) external {
        // Check for the ownership
        if (msg.sender != owner) {
            revert OwnerOnly(msg.sender, owner);
        }

        NVM(didRegistry).addDIDProvider(did, provider);
    }

    /// @dev Removes DID provider.
    /// @param did Refers to decentralized identifier (a bytes32 length ID).
    /// @param provider Provider address.
    function removeDIDProvider(bytes32 did, address provider) external {
        // Check for the ownership
        if (msg.sender != owner) {
            revert OwnerOnly(msg.sender, owner);
        }

        NVM(didRegistry).removeDIDProvider(did, provider);
    }

    /// @dev Transfers DID ownership.
    /// @param did Refers to decentralized identifier (a bytes32 length ID).
    /// @param newOwner New owner address.
    function transferDIDOwnership(bytes32 did, address newOwner) external {
        // Check for the ownership
        if (msg.sender != owner) {
            revert OwnerOnly(msg.sender, owner);
        }

        NVM(didRegistry).transferDIDOwnership(did, newOwner);
    }
}