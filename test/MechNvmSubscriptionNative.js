/*global describe, context, beforeEach, it*/

const { expect } = require("chai");
const { config, ethers } = require("hardhat");

describe("MechNvmSubscriptionNative", function () {
    let priorityMechAddress;
    let priorityMech;
    let serviceRegistry;
    let mechMarketplace;
    let karma;
    let mechFactoryNvmSubscriptionNative;
    let BalanceTrackerNvmSubscriptionNative;
    let balanceTrackerNvmSubscriptionNative;
    let mockNvmSubscriptionNative;
    let weth;
    let paymentType;
    let signers;
    let deployer;
    const AddressZero = ethers.constants.AddressZero;
    const maxDeliveryRate = 10;
    const data = "0x00";
    const fee = 100;
    // In 1e18 form
    const tokenCreditRatio = ethers.utils.parseEther("3");
    // In regular form
    const normalizedRatio = Number(tokenCreditRatio.div(ethers.utils.parseEther("1")));
    const subscriptionId = 1;
    const minResponseTimeout = 10;
    const maxResponseTimeout = 20;
    const mechServiceId = 1;
    const mechCreationData = ethers.utils.defaultAbiCoder.encode(["uint256"], [maxDeliveryRate]);

    beforeEach(async function () {
        signers = await ethers.getSigners();
        deployer = signers[0];

        // Karma implementation and proxy
        const Karma = await ethers.getContractFactory("Karma");
        const karmaImplementation = await Karma.deploy();
        await karmaImplementation.deployed();

        // Initialize karma
        let proxyData = karmaImplementation.interface.encodeFunctionData("initialize", []);
        const KarmaProxy = await ethers.getContractFactory("KarmaProxy");
        const karmaProxy = await KarmaProxy.deploy(karmaImplementation.address, proxyData);
        await karmaProxy.deployed();

        karma = await ethers.getContractAt("Karma", karmaProxy.address);

        const ServiceRegistry = await ethers.getContractFactory("MockServiceRegistry");
        serviceRegistry = await ServiceRegistry.deploy();
        await serviceRegistry.deployed();

        // Mech Marketplace
        const MechMarketplace = await ethers.getContractFactory("MechMarketplace");
        mechMarketplace = await MechMarketplace.deploy(serviceRegistry.address, karma.address);
        await mechMarketplace.deployed();

        // Deploy and initialize marketplace proxy
        proxyData = MechMarketplace.interface.encodeFunctionData("initialize",
            [fee, minResponseTimeout, maxResponseTimeout]);
        const MechMarketplaceProxy = await ethers.getContractFactory("MechMarketplaceProxy");
        const mechMarketplaceProxy = await MechMarketplaceProxy.deploy(mechMarketplace.address, proxyData);
        await mechMarketplaceProxy.deployed();

        mechMarketplace = await ethers.getContractAt("MechMarketplace", mechMarketplaceProxy.address);

        // Deploy mech factory
        const MechFactoryNvmSubscriptionNative = await ethers.getContractFactory("MechFactoryNvmSubscriptionNative");
        mechFactoryNvmSubscriptionNative = await MechFactoryNvmSubscriptionNative.deploy(mechMarketplace.address);
        await mechFactoryNvmSubscriptionNative.deployed();

        // Whitelist mech factory
        await mechMarketplace.setMechFactoryStatuses([mechFactoryNvmSubscriptionNative.address], [true]);

        // Whitelist marketplace in the karma proxy
        await karma.setMechMarketplaceStatuses([mechMarketplace.address], [true]);

        // Pseudo-create two services
        await serviceRegistry.setServiceOwner(mechServiceId, deployer.address);
        await serviceRegistry.setServiceOwner(mechServiceId + 1, deployer.address);

        // Create default priority mech
        let tx = await mechMarketplace.create(mechServiceId, mechFactoryNvmSubscriptionNative.address, mechCreationData);
        let res = await tx.wait();
        // Get mech contract address from the event
        priorityMechAddress = "0x" + res.logs[0].topics[1].slice(26);
        // Get mech contract instance
        priorityMech = await ethers.getContractAt("MechNvmSubscriptionNative", priorityMechAddress);

        const WETH = await ethers.getContractFactory("WETH9");
        weth = await WETH.deploy();
        await weth.deployed();

        // Deploy balance tracker
        // Buy back burner are not relevant for now
        BalanceTrackerNvmSubscriptionNative = await ethers.getContractFactory("BalanceTrackerNvmSubscriptionNative");
        balanceTrackerNvmSubscriptionNative = await BalanceTrackerNvmSubscriptionNative.deploy(mechMarketplace.address,
            deployer.address, weth.address);
        await balanceTrackerNvmSubscriptionNative.deployed();

        // Deploy mock NVM subscription
        const MockNvmSubscriptionNative = await ethers.getContractFactory("MockNvmSubscriptionNative");
        mockNvmSubscriptionNative = await MockNvmSubscriptionNative.deploy(balanceTrackerNvmSubscriptionNative.address,
            tokenCreditRatio);
        await mockNvmSubscriptionNative.deployed();

        // Set subscription contract address
        await balanceTrackerNvmSubscriptionNative.setSubscription(mockNvmSubscriptionNative.address, subscriptionId,
            tokenCreditRatio);

        // Whitelist balance tracker
        paymentType = await priorityMech.paymentType();
        await mechMarketplace.setPaymentTypeBalanceTrackers([paymentType], [balanceTrackerNvmSubscriptionNative.address]);
    });

    context("Initialization", async function () {
        it("Checking for arguments passed to the constructor and subscription setting", async function () {
            // Subscription already set
            await expect(
                balanceTrackerNvmSubscriptionNative.setSubscription(AddressZero, AddressZero, 0)
            ).to.be.revertedWithCustomError(BalanceTrackerNvmSubscriptionNative, "OwnerOnly");

            // Deploy another balance tracker contract
            const balanceTrackerNvmSubscriptionNativeTest = await BalanceTrackerNvmSubscriptionNative.deploy(mechMarketplace.address,
                deployer.address, weth.address);
            await balanceTrackerNvmSubscriptionNativeTest.deployed();

            // Zero subscription address
            await expect(
                balanceTrackerNvmSubscriptionNativeTest.setSubscription(AddressZero, 0, 0)
            ).to.be.revertedWithCustomError(BalanceTrackerNvmSubscriptionNative, "ZeroAddress");

            // Zero subscription token Id
            await expect(
                balanceTrackerNvmSubscriptionNativeTest.setSubscription(deployer.address, 0, 0)
            ).to.be.revertedWithCustomError(BalanceTrackerNvmSubscriptionNative, "ZeroValue");

            // Zero tokenCreditRatio
            await expect(
                balanceTrackerNvmSubscriptionNativeTest.setSubscription(deployer.address, subscriptionId, 0)
            ).to.be.revertedWithCustomError(BalanceTrackerNvmSubscriptionNative, "ZeroValue");
        });
    });

    context("Deliver", async function () {
        it("Delivering request by a priority mech", async function () {
            const requestId = await mechMarketplace.getRequestId(priorityMech.address, deployer.address, data,
                maxDeliveryRate, paymentType, 0);

            // Try to create a request without any subscription balance
            await expect(
                mechMarketplace.request(data, maxDeliveryRate, paymentType, priorityMech.address, minResponseTimeout, "0x")
            ).to.be.reverted;

            const numCredits = maxDeliveryRate * 10;

            // Buy subscription
            await mockNvmSubscriptionNative.mint(subscriptionId, numCredits, {value: numCredits * normalizedRatio});

            // Post a request
            await mechMarketplace.request(data, maxDeliveryRate, paymentType, priorityMech.address, minResponseTimeout, "0x");

            // Get the request status (requested priority)
            let status = await mechMarketplace.getRequestStatus(requestId);
            expect(status).to.equal(1);

            const deliverData = ethers.utils.defaultAbiCoder.encode(["uint256", "bytes"], [maxDeliveryRate, data]);

            // Deliver a request
            await priorityMech.deliverToMarketplace([requestId], [deliverData]);

            // Get the request status (delivered)
            status = await mechMarketplace.getRequestStatus(requestId);
            expect(status).to.equal(3);

            // Try to deliver the same request again
            await priorityMech.deliverToMarketplace([requestId], [deliverData]);

            // Check mech karma
            let mechKarma = await karma.mapMechKarma(priorityMech.address);
            expect(mechKarma).to.equal(1);
            // Check requester mech karma
            mechKarma = await karma.mapRequesterMechKarma(deployer.address, priorityMech.address);
            expect(mechKarma).to.equal(1);
        });

        it("Delivering request by a priority mech", async function () {
            // Get request Id
            const requestId = await mechMarketplace.getRequestId(priorityMech.address, deployer.address, data,
                maxDeliveryRate, paymentType, 0);

            // Buy insufficient subscription
            await mockNvmSubscriptionNative.mint(subscriptionId, maxDeliveryRate - 1,
                {value: maxDeliveryRate * normalizedRatio - 1});

            // Try to create request with insufficient pre-paid amount
            await expect(
                mechMarketplace.request(data, maxDeliveryRate, paymentType, priorityMech.address, minResponseTimeout, "0x")
            ).to.be.revertedWithCustomError(balanceTrackerNvmSubscriptionNative, "InsufficientBalance");

            // Try to send additional value when creating a request
            await expect(
                mechMarketplace.request(data, maxDeliveryRate, paymentType, priorityMech.address, minResponseTimeout, "0x", {value: 1})
            ).to.be.revertedWithCustomError(balanceTrackerNvmSubscriptionNative, "NoDepositAllowed");

            const numCredits = maxDeliveryRate * 10;

            // Buy more credits
            await mockNvmSubscriptionNative.mint(subscriptionId, numCredits, {value: numCredits * normalizedRatio});

            // Try to process zero mech balance
            await expect(
                balanceTrackerNvmSubscriptionNative.processPaymentByMultisig(priorityMech.address)
            ).to.be.revertedWithCustomError(balanceTrackerNvmSubscriptionNative, "ZeroValue");

            let requesterBalance1155Before = await mockNvmSubscriptionNative.balanceOf(deployer.address, subscriptionId);

            // Post a request
            await mechMarketplace.request(data, maxDeliveryRate, paymentType, priorityMech.address, minResponseTimeout, "0x");

            // Get the request status (requested priority)
            let status = await mechMarketplace.getRequestStatus(requestId);
            expect(status).to.equal(1);

            const deliverData = ethers.utils.defaultAbiCoder.encode(["uint256", "bytes"], [maxDeliveryRate, data]);

            // Deliver a request
            await priorityMech.deliverToMarketplace([requestId], [deliverData]);

            // Check priority mech balance now
            let mechBalance = await balanceTrackerNvmSubscriptionNative.mapMechBalances(priorityMech.address);
            expect(mechBalance).to.equal(maxDeliveryRate);

            let balanceBefore = await ethers.provider.getBalance(priorityMech.address);
            // Process payment for mech
            await balanceTrackerNvmSubscriptionNative.processPaymentByMultisig(priorityMech.address);
            let balanceAfter = await ethers.provider.getBalance(priorityMech.address);

            // Check charged fee
            let collectedFees = await balanceTrackerNvmSubscriptionNative.collectedFees();
            // Since the delivery rate is smaller than MAX_FEE_FACTOR, the minimal fee was charged
            expect(collectedFees).to.equal(1);

            // Drain funds to a buy back burner mock
            await balanceTrackerNvmSubscriptionNative.drain();
            collectedFees = await balanceTrackerNvmSubscriptionNative.collectedFees();
            expect(collectedFees).to.equal(0);

            // Check mech payout: payment - fee
            let balanceDiff = balanceAfter.sub(balanceBefore);
            expect(balanceDiff).to.equal(maxDeliveryRate * normalizedRatio - 1);

            let requesterBalance1155After = await mockNvmSubscriptionNative.balanceOf(deployer.address, subscriptionId);
            balanceDiff = requesterBalance1155Before.sub(requesterBalance1155After);
            expect(balanceDiff).to.equal(maxDeliveryRate);
        });

        it("Delivering request with a decrease delivery rate", async function () {
            // Get request Id
            const requestId = await mechMarketplace.getRequestId(priorityMech.address, deployer.address, data,
                maxDeliveryRate, paymentType, 0);

            // Buy a subscription
            await mockNvmSubscriptionNative.mint(subscriptionId, maxDeliveryRate, {value: maxDeliveryRate * normalizedRatio});

            // Post a request
            await mechMarketplace.request(data, maxDeliveryRate, paymentType, priorityMech.address, minResponseTimeout, "0x");

            // Try to deliver by a mech with bigger max Delivery rate (it's not going to be delivered)
            let deliverData = ethers.utils.defaultAbiCoder.encode(["uint256", "bytes"], [maxDeliveryRate + 1, data]);
            await priorityMech.deliverToMarketplace([requestId], [deliverData]);

            // Change max delivery rate to lower than it was
            deliverData = ethers.utils.defaultAbiCoder.encode(["uint256", "bytes"], [maxDeliveryRate - 1, data]);

            // Deliver a request
            await priorityMech.deliverToMarketplace([requestId], [deliverData]);

            // Check priority mech balance now
            let mechBalance = await balanceTrackerNvmSubscriptionNative.mapMechBalances(priorityMech.address);
            expect(mechBalance).to.equal(maxDeliveryRate - 1);

            // Process payment for mech
            await balanceTrackerNvmSubscriptionNative.processPaymentByMultisig(priorityMech.address);

            // Check charged fee
            let collectedFees = await balanceTrackerNvmSubscriptionNative.collectedFees();
            // Since the delivery rate is smaller than MAX_FEE_FACTOR, the minimal fee was charged
            expect(collectedFees).to.equal(1);
        });

        it("Delivering request with a zero fee", async function () {
            // Get request Id
            const requestId = await mechMarketplace.getRequestId(priorityMech.address, deployer.address, data,
                maxDeliveryRate, paymentType, 0);

            // Buy a subscription
            await mockNvmSubscriptionNative.mint(subscriptionId, maxDeliveryRate, {value: maxDeliveryRate * normalizedRatio});

            // Post a request
            await mechMarketplace.request(data, maxDeliveryRate, paymentType, priorityMech.address, minResponseTimeout, "0x");

            // Change max delivery rate to lower than it was
            const deliverData = ethers.utils.defaultAbiCoder.encode(["uint256", "bytes"], [maxDeliveryRate, data]);

            // Change fee to zero
            await mechMarketplace.changeMarketplaceParams(0, minResponseTimeout, maxResponseTimeout);

            // Deliver a request
            await priorityMech.deliverToMarketplace([requestId], [deliverData]);

            // Check priority mech balance now
            let mechBalance = await balanceTrackerNvmSubscriptionNative.mapMechBalances(priorityMech.address);
            expect(mechBalance).to.equal(maxDeliveryRate);

            // Process payment for mech
            let balanceBefore = await ethers.provider.getBalance(priorityMech.address);
            await balanceTrackerNvmSubscriptionNative.processPaymentByMultisig(priorityMech.address);
            let balanceAfter = await ethers.provider.getBalance(priorityMech.address);
            // Zero fee is charged
            let balanceDiff = balanceAfter.sub(balanceBefore);
            expect(balanceDiff).to.equal(maxDeliveryRate * normalizedRatio);

            // Check charged fee
            let collectedFees = await balanceTrackerNvmSubscriptionNative.collectedFees();
            // Zero fee is charged
            expect(collectedFees).to.equal(0);
        });

        it("Requests with signatures", async function () {
            const numRequests = 10;
            const datas = new Array();
            const requestIds = new Array();
            const signatures = new Array();
            const deliveryRates = new Array(numRequests).fill(maxDeliveryRate);
            let requestCount = 0;

            // Buy a subscription
            await mockNvmSubscriptionNative.mint(subscriptionId, numRequests * maxDeliveryRate,
                {value: numRequests * maxDeliveryRate * normalizedRatio});

            // Get deployer wallet
            const accounts = config.networks.hardhat.accounts;
            const wallet = ethers.Wallet.fromMnemonic(accounts.mnemonic, accounts.path + `/${0}`);
            const signingKey = new ethers.utils.SigningKey(wallet.privateKey);

            // Try to update mech num requests not by a Marketplace
            await expect(
                priorityMech.updateNumRequests(numRequests)
            ).to.be.revertedWithCustomError(priorityMech, "MarketplaceOnly");

            // Stack all requests
            for (let i = 0; i < numRequests; i++) {
                datas[i] = data + "00".repeat(i);
                requestIds[i] = await mechMarketplace.getRequestId(priorityMech.address, deployer.address, datas[i],
                    maxDeliveryRate, paymentType, requestCount);
                const signature = signingKey.signDigest(requestIds[i]);
                // Extract v, r, s
                const r = ethers.utils.arrayify(signature.r);
                const s = ethers.utils.arrayify(signature.s);
                const v = ethers.utils.arrayify(signature.v);
                // Assemble 65 bytes of signature
                signatures[i] = ethers.utils.hexlify(ethers.utils.concat([r, s, v]));
                requestCount++;
            }

            // Try to deliver requests not in order
            let reverseDatas = Array.from(datas);
            reverseDatas = reverseDatas.reverse();

            let deliverWithSignatures = [];
            for (let i = 0; i < requestCount; i++) {
                deliverWithSignatures.push({requestData: reverseDatas[i], signature: signatures[i], deliveryData: reverseDatas[i]});
            }

            await expect(
                priorityMech["deliverMarketplaceWithSignatures(address,(bytes,bytes,bytes)[],uint256[],bytes)"](deployer.address, deliverWithSignatures,
                    deliveryRates, "0x")
            ).to.be.revertedWithCustomError(mechMarketplace, "SignatureNotValidated");

            deliverWithSignatures = [];
            for (let i = 0; i < requestCount; i++) {
                deliverWithSignatures.push({requestData: datas[i], signature: signatures[i], deliveryData: datas[i]});
            }
        });

        it("Requests with signatures and per-request caps", async function () {
            const numRequests = 10;
            const datas = new Array();
            const requestIds = new Array();
            const signatures = new Array();
            // Signed caps and the lower actual rates the mech charges
            const maxRates = new Array(numRequests).fill(maxDeliveryRate);
            const deliveryRates = new Array(numRequests).fill(maxDeliveryRate - 1);
            let requestCount = 0;

            // Buy a subscription sized for the caps
            await mockNvmSubscriptionNative.mint(subscriptionId, numRequests * maxDeliveryRate,
                {value: numRequests * maxDeliveryRate * normalizedRatio});

            // Get deployer wallet
            const accounts = config.networks.hardhat.accounts;
            const wallet = ethers.Wallet.fromMnemonic(accounts.mnemonic, accounts.path + `/${0}`);
            const signingKey = new ethers.utils.SigningKey(wallet.privateKey);

            // Stack all requests; the signed request Id is computed over the cap (maxRates), not the charged rate
            for (let i = 0; i < numRequests; i++) {
                datas[i] = data + "00".repeat(i);
                requestIds[i] = await mechMarketplace.getRequestId(priorityMech.address, deployer.address, datas[i],
                    maxRates[i], paymentType, requestCount);
                const signature = signingKey.signDigest(requestIds[i]);
                const r = ethers.utils.arrayify(signature.r);
                const s = ethers.utils.arrayify(signature.s);
                const v = ethers.utils.arrayify(signature.v);
                // Assemble 65 bytes of signature
                signatures[i] = ethers.utils.hexlify(ethers.utils.concat([r, s, v]));
                requestCount++;
            }

            const deliverWithSignatures = [];
            for (let i = 0; i < requestCount; i++) {
                deliverWithSignatures.push({requestData: datas[i], signature: signatures[i], deliveryData: datas[i]});
            }

            // Array length mismatch reverts
            await expect(
                priorityMech["deliverMarketplaceWithSignatures(address,(bytes,bytes,bytes)[],uint256[],uint256[],bytes)"](
                    deployer.address, deliverWithSignatures, deliveryRates.slice(1), maxRates, "0x")
            ).to.be.revertedWithCustomError(mechMarketplace, "WrongArrayLength");

            // Charging above the signed cap reverts
            const overCap = Array.from(deliveryRates);
            overCap[0] = maxRates[0] + 1;
            await expect(
                priorityMech["deliverMarketplaceWithSignatures(address,(bytes,bytes,bytes)[],uint256[],uint256[],bytes)"](
                    deployer.address, deliverWithSignatures, overCap, maxRates, "0x")
            ).to.be.revertedWithCustomError(mechMarketplace, "RateOverCap");

            // Mismatched maxRates length reverts (reporting the maxRates length)
            await expect(
                priorityMech["deliverMarketplaceWithSignatures(address,(bytes,bytes,bytes)[],uint256[],uint256[],bytes)"](
                    deployer.address, deliverWithSignatures, deliveryRates, maxRates.slice(1), "0x")
            ).to.be.revertedWithCustomError(mechMarketplace, "WrongArrayLength");

            // Successful delivery charging the actual (below-cap) rates
            const mechBalanceBefore = await balanceTrackerNvmSubscriptionNative.mapMechBalances(priorityMech.address);
            await priorityMech["deliverMarketplaceWithSignatures(address,(bytes,bytes,bytes)[],uint256[],uint256[],bytes)"](
                deployer.address, deliverWithSignatures, deliveryRates, maxRates, "0x");
            const mechBalanceAfter = await balanceTrackerNvmSubscriptionNative.mapMechBalances(priorityMech.address);

            // The mech is credited the sum of the ACTUAL delivery rates, not the signed caps
            const sumDeliveryRates = deliveryRates.reduce((a, b) => a + b, 0);
            const sumMaxRates = maxRates.reduce((a, b) => a + b, 0);
            expect(mechBalanceAfter.sub(mechBalanceBefore)).to.equal(sumDeliveryRates);
            expect(mechBalanceAfter.sub(mechBalanceBefore)).to.not.equal(sumMaxRates);

            // The recorded delivery rate is the actual charged rate, not the signed cap
            const requestInfo = await mechMarketplace.mapRequestIdInfos(requestIds[0]);
            expect(requestInfo.deliveryRate).to.equal(deliveryRates[0]);
        });
    });
});
