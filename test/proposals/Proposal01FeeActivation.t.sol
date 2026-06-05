// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import "forge-std/Test.sol";
import {Proposal01Builder} from "../../scripts/proposals/proposal_01/Proposal01FeeActivation.s.sol";

interface IMechMarketplace {
    function fee() external view returns (uint256);
    function minResponseTimeout() external view returns (uint256);
    function maxResponseTimeout() external view returns (uint256);
    function owner() external view returns (address);
}

interface IGovernor {
    function propose(address[] memory targets, uint256[] memory values, bytes[] memory calldatas, string memory description) external returns (uint256);
    function castVote(uint256 proposalId, uint8 support) external returns (uint256);
    function queue(address[] memory targets, uint256[] memory values, bytes[] memory calldatas, bytes32 descriptionHash) external returns (uint256);
    function execute(address[] memory targets, uint256[] memory values, bytes[] memory calldatas, bytes32 descriptionHash) external payable returns (uint256);
    function state(uint256 proposalId) external view returns (uint8);
    function proposalEta(uint256 proposalId) external view returns (uint256);
    function votingDelay() external view returns (uint256);
    function votingPeriod() external view returns (uint256);
    function token() external view returns (address);
    function hashProposal(address[] memory targets, uint256[] memory values, bytes[] memory calldatas, bytes32 descriptionHash) external pure returns (uint256);
}

/// @title Proposal01FeeActivation fork test
/// @dev Two checks against a mainnet fork, both asserting the same post-activation state:
///      - test_FullGovernanceLifecycle: the REAL pipeline through the GovernorOLAS currently holding the
///        Timelock PROPOSER role + Timelock (propose -> vote -> queue -> execute). Confirms the state
///        machine, timelock scheduling and the atomic batch execution. Only veOLAS vote-weight reads
///        are mocked.
///      - test_FullProposalExecutes: fast path that executes the batch as the Timelock (final step only).
///
///      The L1 (Ethereum) entry write lands on the live MechMarketplaceProxy at MM_MAINNET and is asserted
///      directly. The six bridged entries (Gnosis / Polygon / Arbitrum / Optimism / Base / Celo) leave
///      L1-side traces only (the bridge entrypoints don't revert and emit their respective events);
///      destination-chain state changes are validated separately via Tenderly simulation on each L2.
///
///      Run: forge test --fork-url $MAINNET_RPC --match-contract Proposal01FeeActivation -vvv
contract Proposal01FeeActivationTest is Test, Proposal01Builder {
    // Active GovernorOLAS (holds the Timelock PROPOSER role at mainnet head, pre proposal_11 activation in
    // autonolas-governance). If proposal_11 has activated NEW_GOV (0x060D…51E6), switch this to NEW_GOV.
    address internal constant ACTIVE_GOV = 0x8E84B5055492901988B831817e4Ace5275A3b401;

    function setUp() public {
        assertEq(block.chainid, 1, "Must run on a mainnet fork (--fork-url $MAINNET_RPC)");
        // Arbitrum entry is payable — fund the Timelock with the retryable cost.
        vm.deal(TIMELOCK, TIMELOCK.balance + ARB_TICKET_VALUE);
    }

    function _execAll() internal {
        (address[] memory targets, uint256[] memory values, bytes[] memory calldatas,) = buildProposal();
        vm.startPrank(TIMELOCK);
        for (uint256 i; i < targets.length; ++i) {
            (bool ok, bytes memory ret) = targets[i].call{value: values[i]}(calldatas[i]);
            if (!ok) {
                console2.log("Reverted at index", i, "target", targets[i]);
                if (ret.length > 0) {
                    assembly { revert(add(ret, 0x20), mload(ret)) }
                }
                revert("call failed");
            }
        }
        vm.stopPrank();
    }

    /// @dev Asserts the post-activation L1 state. Shared by both the fast-path and the
    ///      full-governance-lifecycle tests.
    function _assertEndState() internal view {
        IMechMarketplace mm = IMechMarketplace(MM_MAINNET);
        assertEq(mm.fee(), NEW_FEE, "L1 fee not set to 15%");
        assertEq(mm.minResponseTimeout(), MIN_RESPONSE_TIMEOUT, "L1 min timeout drifted");
        assertEq(mm.maxResponseTimeout(), MAX_RESPONSE_TIMEOUT, "L1 max timeout drifted");
        // Bridged entries: destination-chain effects are not observable on a mainnet fork; correctness of
        // the L2 payload is covered by the bridge-messenger format (target | uint96 value | uint32 len |
        // payload) and the L1 bridge entrypoints accepting the call (asserted by non-revert above).
    }

    /// @dev Sanity: the pre-vote state is fee=0 and the Timelock owns the L1 MM.
    function test_PreconditionsHold() public view {
        IMechMarketplace mm = IMechMarketplace(MM_MAINNET);
        assertEq(mm.fee(), 0, "L1 fee should be 0 pre-vote");
        assertEq(mm.minResponseTimeout(), MIN_RESPONSE_TIMEOUT, "L1 min timeout pre-vote");
        assertEq(mm.maxResponseTimeout(), MAX_RESPONSE_TIMEOUT, "L1 max timeout pre-vote");
        assertEq(mm.owner(), TIMELOCK, "L1 MM owner should be Timelock");
    }

    /// @dev Fast path: the batch executes (as the Timelock would in the final step) and the L1 effect lands.
    function test_FullProposalExecutes() public {
        _execAll();
        _assertEndState();
    }

    /// @dev REAL end-to-end lifecycle through the active GovernorOLAS + Timelock:
    ///      propose -> (advance) -> castVote -> (advance) -> queue -> (warp past eta) -> execute.
    ///      Only the veOLAS voting-power reads are mocked (to isolate the proposal mechanics from token
    ///      distribution); the proposal id, state machine, timelock scheduling and batch execution are real.
    function test_FullGovernanceLifecycle() public {
        (address[] memory targets, uint256[] memory values, bytes[] memory calldatas, string memory description) =
            buildProposal();
        bytes32 descHash = keccak256(bytes(description));
        IGovernor gov = IGovernor(ACTIVE_GOV);
        address token = gov.token(); // wveOLAS used for vote weight
        address proposer = address(0xBEEF);
        address voter = address(0xCAFE);

        // Inject voting power: large weight for any account, moderate total supply so quorum (3%) is cleared.
        vm.mockCall(token, abi.encodeWithSignature("getPastVotes(address,uint256)"), abi.encode(uint256(1e27)));
        vm.mockCall(token, abi.encodeWithSignature("getVotes(address,uint256)"), abi.encode(uint256(1e27)));
        vm.mockCall(token, abi.encodeWithSignature("getPastTotalSupply(uint256)"), abi.encode(uint256(1e24)));

        // propose
        vm.prank(proposer);
        uint256 id = gov.propose(targets, values, calldatas, description);
        assertEq(id, gov.hashProposal(targets, values, calldatas, descHash), "proposalId mismatch");

        // into Active, then vote For
        vm.roll(block.number + gov.votingDelay() + 1);
        assertEq(uint256(gov.state(id)), 1, "not Active");
        vm.prank(voter);
        gov.castVote(id, 1);

        // end voting -> Succeeded
        vm.roll(block.number + gov.votingPeriod() + 1);
        assertEq(uint256(gov.state(id)), 4, "not Succeeded");

        // queue -> Queued, warp past the timelock eta, then execute -> Executed
        gov.queue(targets, values, calldatas, descHash);
        assertEq(uint256(gov.state(id)), 5, "not Queued");
        uint256 eta = gov.proposalEta(id);
        if (eta >= block.timestamp) vm.warp(eta + 1);
        // Re-fund the Timelock right before execute() — vm.warp can run far ahead but ETH balance is
        // preserved; this is defensive against any unexpected drain.
        if (TIMELOCK.balance < ARB_TICKET_VALUE) vm.deal(TIMELOCK, ARB_TICKET_VALUE);
        gov.execute(targets, values, calldatas, descHash);
        assertEq(uint256(gov.state(id)), 7, "not Executed");

        _assertEndState();
    }
}
