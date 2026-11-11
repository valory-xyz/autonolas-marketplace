// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import {MechMarketplace} from "../contracts/MechMarketplace.sol";
import {MechMarketplaceProxy} from "../contracts/proxies/MechMarketplaceProxy.sol";
import {Karma} from "../contracts/Karma.sol";
import {DeliverWithSignature} from "../contracts/OlasMech.sol";
import {MechFixedPriceNative} from "../contracts/mechs/native/MechFixedPriceNative.sol";
import {MechFactoryFixedPriceNative} from "../contracts/mechs/native/MechFactoryFixedPriceNative.sol";
import {BalanceTrackerFixedPriceNative} from "../contracts/mechs/native/BalanceTrackerFixedPriceNative.sol";
import {MockServiceRegistry} from "../lib/autonolas-registries/contracts/test/MockServiceRegistry.sol";
import {MockOperatorContract} from "../lib/autonolas-registries/contracts/test/MockOperatorContract.sol";

// Keep these tests independent of forge-std; no additional submodule is required.
interface VmDomainSeparator {
    function chainId(uint256) external;
    function addr(uint256) external returns (address);
    function sign(uint256, bytes32) external returns (uint8, bytes32, bytes32);
    function deal(address, uint256) external;
    function expectPartialRevert(bytes4) external;
    function getCode(string calldata) external returns (bytes memory);
    function readFile(string calldata) external view returns (string memory);
    function parseJsonBytes(string calldata, string calldata) external pure returns (bytes memory);
    function parseJsonUint(string calldata, string calldata) external pure returns (uint256);
    function parseJsonAddress(string calldata, string calldata) external pure returns (address);
    function parseJsonString(string calldata, string calldata) external pure returns (string memory);
    function createSelectFork(string calldata, uint256) external returns (uint256);
    function prank(address) external;
    function load(address, bytes32) external view returns (bytes32);
    function envOr(string calldata, bool) external returns (bool);
    function skip(bool) external;
}

abstract contract MarketplaceDomainTestBase {
    VmDomainSeparator internal constant vm = VmDomainSeparator(address(uint160(uint256(keccak256("hevm cheat code")))));

    function _deploy(bytes memory code, bytes memory args) internal returns (address deployed) {
        bytes memory creation = bytes.concat(code, args);
        assembly {
            deployed := create(0, add(creation, 32), mload(creation))
        }
        require(deployed != address(0), "implementation deployment failed");
    }

    function _candidate(address registry, address karma) internal returns (address) {
        return _deploy(vm.getCode("MechMarketplace.sol:MechMarketplace"), abi.encode(registry, karma));
    }

    function _legacy(address registry, address karma) internal returns (address) {
        // Pinned legacy (1.1.0) implementation fixture; its legacy signed-delivery entrypoint is
        // sufficient to reproduce both signature directions for the backward-compatibility regression.
        string memory artifact = vm.readFile("test/fixtures/MechMarketplace_1.1.0.json");
        return _deploy(vm.parseJsonBytes(artifact, ".bytecode.object"), abi.encode(registry, karma));
    }

    function _domain(uint256 id, address proxy) internal pure returns (bytes32) {
        // Independent legacy encoding, deliberately pinned rather than reading VERSION from the SUT.
        return keccak256(
            abi.encode(
                keccak256("EIP712Domain(string name,string version,uint256 chainId,address verifyingContract)"),
                keccak256("MechMarketplace"),
                keccak256(abi.encode("1.1.0")),
                id,
                proxy
            )
        );
    }

    function _rootStorage(address proxy) internal view returns (bytes32) {
        bytes32[18] memory slots;
        // Current storage slots 0-17, including mapping roots. The implementation slot is separate.
        for (uint256 i; i < slots.length; ++i) {
            slots[i] = vm.load(proxy, bytes32(i));
        }
        return keccak256(abi.encode(slots));
    }
}

contract MechMarketplaceDomainSeparatorTest is MarketplaceDomainTestBase {
    uint256 internal constant CHAIN_A = 1;
    uint256 internal constant CHAIN_B = 100;
    uint256 internal constant REQUESTER_KEY = 0xa11ce;
    uint256 internal constant RATE = 100;
    uint256 internal constant DEPOSIT = 1000;
    bytes4 internal constant INVALID_SIGNATURE = bytes4(keccak256("SignatureNotValidated(address,bytes32,bytes)"));

    MechMarketplace internal marketplace;
    MockServiceRegistry internal registry;
    Karma internal karmaContract;
    MechFixedPriceNative internal mech;
    BalanceTrackerFixedPriceNative internal tracker;
    MockOperatorContract internal contractRequester;
    address internal requester;
    bytes32 internal paymentType;

    function setUp() public {
        vm.chainId(CHAIN_A);
        vm.deal(address(this), 1 ether);
        requester = vm.addr(REQUESTER_KEY);
        registry = new MockServiceRegistry();
        karmaContract = new Karma();
        karmaContract.initialize();
        address oldImplementation = _legacy(address(registry), address(karmaContract));
        marketplace = MechMarketplace(
            address(
                new MechMarketplaceProxy(oldImplementation, abi.encodeCall(MechMarketplace.initialize, (100, 10, 20)))
            )
        );
        address[] memory addresses = new address[](1);
        bool[] memory statuses = new bool[](1);
        addresses[0] = address(marketplace);
        statuses[0] = true;
        karmaContract.setMechMarketplaceStatuses(addresses, statuses);
        MechFactoryFixedPriceNative factory = new MechFactoryFixedPriceNative(address(marketplace));
        addresses[0] = address(factory);
        marketplace.setMechFactoryStatuses(addresses, statuses);
        registry.setServiceOwner(1, address(this));
        mech = MechFixedPriceNative(payable(marketplace.create(1, address(factory), abi.encode(RATE))));
        paymentType = mech.paymentType();
        // Wrapping/draining is not exercised; constructor requires a nonzero wrapped-native address.
        tracker = new BalanceTrackerFixedPriceNative(address(marketplace), address(this), address(1));
        bytes32[] memory types = new bytes32[](1);
        types[0] = paymentType;
        addresses[0] = address(tracker);
        marketplace.setPaymentTypeBalanceTrackers(types, addresses);
        tracker.depositFor{value: DEPOSIT}(requester);
        contractRequester = new MockOperatorContract();
        tracker.depositFor{value: DEPOSIT}(address(contractRequester));
        require(
            marketplace.domainSeparator() == _domain(CHAIN_A, address(marketplace)), "legacy artifact domain differs"
        );
    }

    function _digest(uint256 chain, address account, bytes memory data, uint256 nonce, bool explicitNonce)
        internal
        view
        returns (bytes32)
    {
        if (explicitNonce) {
            bytes32 domain = keccak256(
                abi.encode(
                    keccak256("EIP712Domain(string name,string version,uint256 chainId,address verifyingContract)"),
                    keccak256("MechMarketplace"),
                    keccak256("2"),
                    chain,
                    address(marketplace)
                )
            );
            bytes32 typeHash = keccak256(
                "ExplicitNonceDelivery(address mech,address requester,bytes data,uint256 maxDeliveryRate,bytes32 paymentType,uint256 nonce,uint256 deadline)"
            );
            bytes32 typedFields = keccak256(
                abi.encode(
                    typeHash,
                    address(mech),
                    account,
                    keccak256(data),
                    RATE,
                    paymentType,
                    nonce,
                    block.timestamp + 1 days
                )
            );
            return keccak256(abi.encodePacked(hex"1901", domain, typedFields));
        }
        bytes memory fields =
            abi.encode(address(marketplace), address(mech), account, keccak256(data), RATE, paymentType, nonce);
        return keccak256(abi.encodePacked(hex"1901", _domain(chain, address(marketplace)), keccak256(fields)));
    }

    function _signature(bytes32 digest) internal returns (bytes memory) {
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(REQUESTER_KEY, digest);
        return abi.encodePacked(r, s, v);
    }

    function _settle(uint256 path, address account, bytes memory data, bytes memory signature, uint256 nonce) internal {
        DeliverWithSignature[] memory items = new DeliverWithSignature[](1);
        items[0] = DeliverWithSignature(data, signature, hex"abcd");
        uint256[] memory rates = new uint256[](1);
        rates[0] = path == 0 ? RATE : 70;
        uint256[] memory caps = new uint256[](1);
        caps[0] = RATE;
        uint256[] memory nonces = new uint256[](1);
        nonces[0] = nonce;
        if (path == 0) {
            mech.deliverMarketplaceWithSignatures(account, items, rates, "");
        } else if (path == 1) {
            mech.deliverMarketplaceWithSignatures(account, items, rates, caps, "");
        } else {
            uint256[] memory deadlines = new uint256[](1);
            deadlines[0] = block.timestamp + 1 days;
            mech.deliverMarketplaceWithSignatures(account, items, rates, caps, nonces, deadlines, "");
        }
    }

    function test_legacyRecomputesAfterChainChangeBeforeUpgrade() public {
        vm.chainId(CHAIN_B);
        require(marketplace.chainId() == CHAIN_A, "old immutable changed");
        require(marketplace.domainSeparator() == _domain(CHAIN_A, address(marketplace)), "cache changed");
        require(marketplace.getDomainSeparator() == _domain(CHAIN_B, address(marketplace)), "legacy fallback failed");
    }

    function test_legacyUpgradeRearmsStaleCache_acceptsA_rejectsB() public {
        bytes memory data = hex"1234";
        bytes memory signatureA = _signature(_digest(CHAIN_A, requester, data, 0, false));
        bytes memory signatureB = _signature(_digest(CHAIN_B, requester, data, 0, false));
        vm.chainId(CHAIN_B);
        marketplace.changeImplementation(_legacy(address(registry), address(karmaContract)));
        require(marketplace.chainId() == CHAIN_B, "new immutable is not B");
        require(
            marketplace.getDomainSeparator() == _domain(CHAIN_A, address(marketplace)),
            "negative control lost stale cache"
        );
        vm.expectPartialRevert(INVALID_SIGNATURE);
        _settle(0, requester, data, signatureB, 0);
        _settle(0, requester, data, signatureA, 0);
        require(tracker.mapRequesterBalances(requester) == DEPOSIT - RATE, "A signature did not charge");
    }

    function test_fixedUpgradeRejectsA_acceptsB_onAllSignedPaths() public {
        vm.chainId(CHAIN_B);
        marketplace.changeImplementation(_candidate(address(registry), address(karmaContract)));
        require(marketplace.chainId() == CHAIN_B, "candidate not deployed on B");
        require(marketplace.domainSeparator() == _domain(CHAIN_A, address(marketplace)), "stored cache was overwritten");
        require(marketplace.getDomainSeparator() == _domain(CHAIN_B, address(marketplace)), "not B-bound");
        for (uint256 path; path < 3; ++path) {
            bytes memory data = abi.encode(path);
            uint256 nonce = path == 2 ? 123 : path;
            bytes memory signatureA = _signature(_digest(CHAIN_A, requester, data, nonce, path == 2));
            bytes memory signatureB = _signature(_digest(CHAIN_B, requester, data, nonce, path == 2));
            vm.expectPartialRevert(INVALID_SIGNATURE);
            _settle(path, requester, data, signatureA, nonce);
            _settle(path, requester, data, signatureB, nonce);
        }
        require(tracker.mapRequesterBalances(requester) == DEPOSIT - 240, "wrong total requester charge");
        require(tracker.mapMechBalances(address(mech)) == 240, "wrong mech balance");
        require(marketplace.mapNonces(requester) == 2, "wrong sequential nonce");
    }

    function _checkCompatibility(bool useContractRequester) internal {
        address account = useContractRequester ? address(contractRequester) : requester;
        bytes32[2] memory digests;
        bytes[2] memory signatures;
        for (uint256 path; path < 2; ++path) {
            uint256 nonce = path;
            digests[path] = _digest(CHAIN_A, account, abi.encode(path), nonce, false);
            if (useContractRequester) contractRequester.approveHash(digests[path]);
            else signatures[path] = _signature(digests[path]);
        }
        bytes32 storageBefore = _rootStorage(address(marketplace));
        address ownerBefore = marketplace.owner();
        bytes32 domainBefore = marketplace.getDomainSeparator();
        marketplace.changeImplementation(_candidate(address(registry), address(karmaContract)));
        require(_rootStorage(address(marketplace)) == storageBefore, "proxy storage changed");
        require(marketplace.owner() == ownerBefore, "owner changed");
        require(marketplace.getDomainSeparator() == domainBefore, "domain changed on same chain");
        require(marketplace.serviceRegistry() == address(registry), "registry immutable changed");
        require(marketplace.karma() == address(karmaContract), "karma immutable changed");
        for (uint256 path; path < 2; ++path) {
            bytes memory data = abi.encode(path);
            uint256 nonce = path;
            bytes32 digest = marketplace.getRequestId(address(mech), account, data, RATE, paymentType, nonce);
            require(digest == digests[path], "pre-upgrade request digest changed");
            _settle(path, account, data, signatures[path], nonce);
            require(marketplace.getRequestStatus(digest) == MechMarketplace.RequestStatus.Delivered, "not delivered");
        }
        require(tracker.mapRequesterBalances(account) == DEPOSIT - 170, "wrong requester charge");
        require(tracker.mapMechBalances(address(mech)) == 170, "wrong mech credit");
        require(marketplace.mapNonces(account) == 2, "wrong sequential nonce");
    }

    function test_sameChainUpgradePreservesEOASignatures_legacyPaths() public {
        _checkCompatibility(false);
    }

    function test_sameChainUpgradePreservesEIP1271Approvals_legacyPaths() public {
        _checkCompatibility(true);
    }

    function test_domainUsesPinnedLegacyEncodingAndProxyAddress() public {
        address candidate = _candidate(address(registry), address(karmaContract));
        marketplace.changeImplementation(candidate);
        require(marketplace.getDomainSeparator() == _domain(CHAIN_A, address(marketplace)), "legacy encoding changed");
        require(marketplace.getDomainSeparator() != _domain(CHAIN_A, candidate), "used implementation address");
        vm.chainId(CHAIN_B);
        require(marketplace.getDomainSeparator() == _domain(CHAIN_B, address(marketplace)), "chain change ignored");
        vm.chainId(CHAIN_A);
        require(
            marketplace.getDomainSeparator() == _domain(CHAIN_A, address(marketplace)),
            "return to original chain failed"
        );
    }
}
