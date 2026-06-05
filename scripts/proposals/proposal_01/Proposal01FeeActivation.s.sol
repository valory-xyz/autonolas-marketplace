// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import {Script, console2} from "forge-std/Script.sol";

/// @title Proposal01Builder - Single source of truth for the MechMarketplace fee-activation governance proposal.
/// @dev Builds the (targets, values, calldatas, description) for the cross-chain fee activation vote:
///        [0] Ethereum (direct)              -> MechMarketplaceProxy.changeMarketplaceParams(500, 60, 300)
///        [1] Gnosis     (AMB)               -> HomeMediator(L2) -> MechMarketplaceProxy.changeMarketplaceParams(...)
///        [2] Polygon    (FxRoot)            -> FxGovernorTunnel(L2) -> MechMarketplaceProxy.changeMarketplaceParams(...)
///        [3] Arbitrum   (Inbox, payable)    -> MechMarketplaceProxy.changeMarketplaceParams(...) (aliased Timelock)
///        [4] Optimism   (L1CDM)             -> OptimismMessenger(L2) -> MechMarketplaceProxy.changeMarketplaceParams(...)
///        [5] Base       (L1CDM)             -> OptimismMessenger(L2) -> MechMarketplaceProxy.changeMarketplaceParams(...)
///        [6] Celo       (L1CDM)             -> OptimismMessenger(L2) -> MechMarketplaceProxy.changeMarketplaceParams(...)
///      Mode is intentionally excluded (no MechMarketplace deployment on Mode).
///      The proposal is submitted through the GovernorOLAS currently holding the Timelock PROPOSER role; every
///      call below is executed BY the Timelock (0x3C1fF68f5aa342D296d4DEe4Bb1cACCA912D95fE on L1).
///      All addresses were verified on-chain against scripts/deployment/globals_*_mainnet.json + live `owner()`.
///
///      newFee = 500 (5%) per MAX_FEE_FACTOR = 10_000 in MechMarketplace.sol. minResponseTimeout=60,
///      maxResponseTimeout=300 echo the current live values (mandatory: the setter overwrites all three).
abstract contract Proposal01Builder {
    // ---- Marketplace params ----
    uint256 internal constant NEW_FEE                 = 500;  // 5.00% (MAX_FEE_FACTOR = 10_000)
    uint256 internal constant MIN_RESPONSE_TIMEOUT    = 60;   // current live value, echoed
    uint256 internal constant MAX_RESPONSE_TIMEOUT    = 300;  // current live value, echoed

    // ---- L1 ----
    address internal constant TIMELOCK   = 0x3C1fF68f5aa342D296d4DEe4Bb1cACCA912D95fE;

    // ---- chain ids ----
    uint256 internal constant CID_MAINNET  = 1;
    uint256 internal constant CID_GNOSIS   = 100;
    uint256 internal constant CID_POLYGON  = 137;
    uint256 internal constant CID_ARBITRUM = 42161;
    uint256 internal constant CID_OPTIMISM = 10;
    uint256 internal constant CID_BASE     = 8453;
    uint256 internal constant CID_CELO     = 42220;

    // ---- MechMarketplaceProxy per chain (verified on-chain) ----
    address internal constant MM_MAINNET  = 0x3d6494CE09a9f40c0B5a92BdBD7c7A9b0e3912b1;
    address internal constant MM_GNOSIS   = 0x735FAAb1c4Ec41128c367AFb5c3baC73509f70bB;
    address internal constant MM_POLYGON  = 0x343F2B005cF6D70bA610CD9F1F1927049414B582;
    address internal constant MM_ARBITRUM = 0xf76953444C35F1FcE2F6CA1b167173357d3F5C17;
    address internal constant MM_OPTIMISM = 0x46C0D07F55d4F9B5Eed2Fc9680B5953e5fd7b461;
    address internal constant MM_BASE     = 0xf24eE42edA0fc9b33B7D41B06Ee8ccD2Ef7C5020;
    address internal constant MM_CELO     = 0x17d96ba4532fe91809326092fE4D5606A7B7a0d8;

    // ---- L1 bridge entrypoints ----
    address internal constant AMB_L1      = 0x4C36d2919e407f0Cc2Ee3c993ccF8ac26d9CE64e; // Gnosis (requireToPassMessage)
    address internal constant FXROOT_L1   = 0xfe5e5D361b2ad62c541bAb87C45a0B9B018389a2; // Polygon (sendMessageToChild)
    address internal constant INBOX_L1    = 0x4Dbd4fc535Ac27206064B68FfCf827b0A60BAB3f; // Arbitrum (createRetryableTicket, payable)
    address internal constant OP_L1CDM    = 0x25ace71c97B33Cc4729CF772ae268934F7ab5fA1; // Optimism (sendMessage)
    address internal constant BASE_L1CDM  = 0x866E82a600A1414e583f7F13623F1aC5d58b0Afa; // Base (sendMessage)
    address internal constant CELO_L1CDM  = 0x1AC1181fc4e4F877963680587AEAa2C90D7EbB95; // Celo (sendMessage)

    // ---- L2 bridge mediators / messengers (== MechMarketplaceProxy.owner() per chain, verified on-chain) ----
    address internal constant HOME_MEDIATOR_L2  = 0x15bd56669F57192a97dF41A2aa8f4403e9491776; // Gnosis
    address internal constant FX_TUNNEL_L2      = 0x9338b5153AE39BB89f50468E608eD9d764B755fD; // Polygon
    address internal constant ARB_ALIASED_TL    = 0x4d30F68F5AA342d296d4deE4bB1Cacca912dA70F; // Arbitrum (Timelock + 0x1111…1111 alias)
    address internal constant OP_MESSENGER_L2   = 0x87c511c8aE3fAF0063b3F3CF9C6ab96c4AA5C60c; // Optimism
    address internal constant BASE_MESSENGER_L2 = 0xE49CB081e8d96920C38aA7AB90cb0294ab4Bc8EA; // Base
    address internal constant CELO_MESSENGER_L2 = 0xC14E191A64a7FB0e5790a8a0B9a58683dFFce04d; // Celo

    // ---- Bridge gas constants ----
    uint256 internal constant AMB_REQUEST_GAS_LIMIT = 2_000_000;       // Gnosis AMB
    uint32  internal constant OP_MIN_GAS            = 2_000_000;       // OP-stack (Optimism / Base / Celo)
    // Arbitrum retryable args (conservative — recompute closer to submission via
    // Inbox.calculateRetryableSubmissionFee(data.length, basefee) and current L2 baseFee).
    uint256 internal constant ARB_MAX_SUBMISSION_COST = 1e15;          // 0.001 ETH
    uint256 internal constant ARB_GAS_LIMIT           = 1_000_000;
    uint256 internal constant ARB_MAX_FEE_PER_GAS     = 1e8;           // 0.1 gwei (verifier rejects 1)
    // Total ETH paid by Timelock for the Arbitrum retryable.
    uint256 internal constant ARB_TICKET_VALUE =
        ARB_MAX_SUBMISSION_COST + ARB_GAS_LIMIT * ARB_MAX_FEE_PER_GAS; // 0.001 + 0.0001 = 0.0011 ETH

    // Canonical proposal description. MUST match scripts/proposals/proposal_01/description.txt
    // byte-for-byte: the proposalId (in proposal_01.html, once generated) is keccak over
    // (targets, values, calldatas, keccak(description)). Single line, no embedded newlines.
    string internal constant DESCRIPTION =
        "MechMarketplace protocol fee activation. This proposal switches the universal MechMarketplace fee from 0 to 5% (newFee = 500, MAX_FEE_FACTOR = 10000) on every MechMarketplaceProxy deployment across the supported EVM mainnets, by calling changeMarketplaceParams(500, 60, 300) on each instance. Mode is excluded as no MechMarketplace is deployed on Mode. Ethereum is updated directly; Gnosis, Polygon, Arbitrum, Optimism, Base and Celo are updated through their respective L1->L2 bridge mediators (AMB, FxRoot, Arbitrum Inbox, and the OP-stack L1CrossDomainMessenger for Optimism/Base/Celo). The minResponseTimeout (60s) and maxResponseTimeout (300s) values are echoed unchanged. In accordance with Autonolas DAO Constitution at ipfs://bafybeibrhz6hnxsxcbv7dkzerq4chssotexb276pidzwclbytzj7m4t47u";

    /// @dev Builds the full fee-activation proposal.
    function buildProposal()
        public
        pure
        returns (address[] memory targets, uint256[] memory values, bytes[] memory calldatas, string memory description)
    {
        targets = new address[](7);
        values = new uint256[](7);
        calldatas = new bytes[](7);

        // Inner calldata is identical for every chain.
        bytes memory inner = abi.encodeWithSignature(
            "changeMarketplaceParams(uint256,uint256,uint256)",
            NEW_FEE, MIN_RESPONSE_TIMEOUT, MAX_RESPONSE_TIMEOUT
        );

        // [0] Ethereum (direct, Timelock is the MM owner)
        targets[0]   = MM_MAINNET;
        values[0]    = 0;
        calldatas[0] = inner;

        // [1] Gnosis (AMB.requireToPassMessage -> HomeMediator.processMessageFromForeign(packed))
        targets[1]   = AMB_L1;
        values[1]    = 0;
        calldatas[1] = _gnosisBridged(MM_GNOSIS, inner);

        // [2] Polygon (FxRoot.sendMessageToChild -> FxGovernorTunnel decodes packed directly)
        targets[2]   = FXROOT_L1;
        values[2]    = 0;
        calldatas[2] = _polygonBridged(MM_POLYGON, inner);

        // [3] Arbitrum (Inbox.createRetryableTicket, payable; data = raw target calldata)
        targets[3]   = INBOX_L1;
        values[3]    = ARB_TICKET_VALUE;
        calldatas[3] = _arbitrumRetryable(MM_ARBITRUM, inner);

        // [4] Optimism (L1CDM.sendMessage -> OptimismMessenger.processMessageFromSource(packed))
        targets[4]   = OP_L1CDM;
        values[4]    = 0;
        calldatas[4] = _opStackBridged(OP_MESSENGER_L2, MM_OPTIMISM, inner);

        // [5] Base (L1CDM.sendMessage -> OptimismMessenger.processMessageFromSource(packed))
        targets[5]   = BASE_L1CDM;
        values[5]    = 0;
        calldatas[5] = _opStackBridged(BASE_MESSENGER_L2, MM_BASE, inner);

        // [6] Celo (L1CDM.sendMessage -> OptimismMessenger.processMessageFromSource(packed))
        targets[6]   = CELO_L1CDM;
        values[6]    = 0;
        calldatas[6] = _opStackBridged(CELO_MESSENGER_L2, MM_CELO, inner);

        description = DESCRIPTION;
    }

    /// @dev Gnosis: pack (target | uint96 value | uint32 payloadLen | payload), wrap as
    /// HomeMediator.processMessageFromForeign(bytes), send via AMB.requireToPassMessage(...)
    /// HomeMediator decode loop: contracts/bridges/HomeMediator.sol (autonolas-governance).
    function _gnosisBridged(address target, bytes memory inner) internal pure returns (bytes memory) {
        bytes memory packed = abi.encodePacked(target, uint96(0), uint32(inner.length), inner);
        bytes memory l2call = abi.encodeWithSignature("processMessageFromForeign(bytes)", packed);
        return abi.encodeWithSignature(
            "requireToPassMessage(address,bytes,uint256)", HOME_MEDIATOR_L2, l2call, AMB_REQUEST_GAS_LIMIT
        );
    }

    /// @dev Polygon: FxRoot.sendMessageToChild forwards `data` directly to FxGovernorTunnel.processMessageFromRoot,
    /// so `data` IS the packed (target | uint96 value | uint32 payloadLen | payload). No outer selector.
    /// FxGovernorTunnel decode loop: contracts/bridges/FxGovernorTunnel.sol (autonolas-governance).
    function _polygonBridged(address target, bytes memory inner) internal pure returns (bytes memory) {
        bytes memory packed = abi.encodePacked(target, uint96(0), uint32(inner.length), inner);
        return abi.encodeWithSignature("sendMessageToChild(address,bytes)", FX_TUNNEL_L2, packed);
    }

    /// @dev Arbitrum: createRetryableTicket(to, l2CallValue, maxSubmissionCost, excessFeeRefund, callValueRefund,
    /// gasLimit, maxFeePerGas, data). `to` is the MechMarketplaceProxy directly; `data` is the raw inner calldata.
    /// On L2, msg.sender will be the aliased Timelock (Timelock + 0x1111..1111), which IS the MM owner.
    /// Refund addresses must equal the aliased Timelock (verifier requirement).
    /// Payable: the Timelock must hold ARB_TICKET_VALUE ETH at execution time.
    function _arbitrumRetryable(address target, bytes memory inner) internal pure returns (bytes memory) {
        return abi.encodeWithSignature(
            "createRetryableTicket(address,uint256,uint256,address,address,uint256,uint256,bytes)",
            target,
            uint256(0),                    // l2CallValue
            ARB_MAX_SUBMISSION_COST,       // maxSubmissionCost
            ARB_ALIASED_TL,                // excessFeeRefundAddress
            ARB_ALIASED_TL,                // callValueRefundAddress
            ARB_GAS_LIMIT,                 // gasLimit
            ARB_MAX_FEE_PER_GAS,           // maxFeePerGas
            inner
        );
    }

    /// @dev OP-stack (Optimism / Base / Celo): pack (target | uint96 value | uint32 payloadLen | payload),
    /// wrap as OptimismMessenger.processMessageFromSource(bytes), send via L1CDM.sendMessage(L2, l2call, minGas).
    function _opStackBridged(address l2Messenger, address target, bytes memory inner) internal pure returns (bytes memory) {
        bytes memory packed = abi.encodePacked(target, uint96(0), uint32(inner.length), inner);
        bytes memory l2call = abi.encodeWithSignature("processMessageFromSource(bytes)", packed);
        return abi.encodeWithSignature("sendMessage(address,bytes,uint32)", l2Messenger, l2call, OP_MIN_GAS);
    }
}

/// @notice Run: forge script scripts/proposals/proposal_01/Proposal01FeeActivation.s.sol:Proposal01FeeActivation
///         (no broadcast — prints the proposal arrays to copy into the governor `propose(...)` call).
contract Proposal01FeeActivation is Script, Proposal01Builder {
    function run() external pure {
        (address[] memory targets, uint256[] memory values, bytes[] memory calldatas, string memory description) =
            buildProposal();

        console2.log("=== Proposal 01: MechMarketplace fee activation ===");
        console2.log("entries:", targets.length);
        for (uint256 i; i < targets.length; ++i) {
            console2.log("--- index", i, "---");
            console2.log("target  :", targets[i]);
            console2.log("value   :", values[i]);
            console2.log("calldata:");
            console2.logBytes(calldatas[i]);
        }
        console2.log("description:");
        console2.log(description);
    }
}
