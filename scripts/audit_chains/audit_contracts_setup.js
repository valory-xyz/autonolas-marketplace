/*global process*/

const { ethers } = require("ethers");
const { expect } = require("chai");
const fs = require("fs");

const verifyRepo = false;
const verifySetup = true;

// ===================== CSV CONFIG =====================
const WRITE_OWNERSHIP_CSV = true;
const OWNERSHIP_CSV_PATH = "scripts/audit_chains/ownable_owners.csv";

// Autonolas deployer (for classification)
const AUTONOLAS_DEPLOYER = "0xEB2A22b27C7Ad5eeE424Fd90b376c745E60f914E";

// Minimal helper: normalize addresses (case-insensitive compare)
const norm = (a) => (a ? ethers.utils.getAddress(a) : a);

// Global accumulator for CSV rows (collected during setup checks)
const ownershipRows = [];

// Custom expect that is wrapped into try / catch block
function customExpect(arg1, arg2, log) {
    try {
        expect(arg1).to.equal(arg2);
    } catch (error) {
        console.log(log);
        if (error.status) {
            console.error(error.status);
            console.log("\n");
        } else {
            console.error(error);
            console.log("\n");
        }
    }
}

// Custom expect for contain clause that is wrapped into try / catch block
function customExpectContain(arg1, arg2, log) {
    try {
        expect(arg1).contain(arg2);
    } catch (error) {
        console.log(log);
        if (error.status) {
            console.error(error.status);
            console.log("\n");
        } else {
            console.error(error);
            console.log("\n");
        }
    }
}

// Write ownership CSV
function writeOwnershipCsv(rows, outPath) {
    const headers = [
        "chainId",
        "contractName",
        "contractAddress",
        "ownerAddress",
        "ownerCategory",
        "expectedDaoExecutor",
        "ownershipChangeRequired",
    ];

    const escapeCsv = (v) => {
        if (v === null || v === undefined) return "";
        const s = String(v);
        if (s.includes("\"") || s.includes(",") || s.includes("\n")) {
            return `"${s.replace(/"/g, "\"\"")}"`;
        }
        return s;
    };

    const lines = [
        headers.join(","),
        ...rows.map((r) => headers.map((h) => escapeCsv(r[h])).join(",")),
    ];

    fs.writeFileSync(outPath, lines.join("\n"), "utf8");
    console.log(`\n[CSV] Wrote ${rows.length} rows to ${outPath}\n`);
}

// Push a row into the ownership CSV accumulator
function recordOwnershipRow(chainId, contractName, contractAddress, ownerInfo) {
    if (!WRITE_OWNERSHIP_CSV || !ownerInfo) return;

    ownershipRows.push({
        chainId: String(chainId),
        contractName: contractName,
        contractAddress: norm(contractAddress),
        ownerAddress: ownerInfo.owner,
        ownerCategory: ownerInfo.ownerCategory,
        expectedDaoExecutor: ownerInfo.expectedDaoExecutor,
        ownershipChangeRequired: ownerInfo.ownershipChangeRequired,
    });
}

// Check the contract owner
async function checkOwner(chainId, contract, globalsInstance, log) {
    const owner = norm(await contract.owner());
    const expected = chainId == 1 ? norm(globalsInstance["timelockAddress"]) : norm(globalsInstance["bridgeMediatorAddress"]);

    customExpect(owner, expected, log + ", function: owner()");

    const ownerCategory =
        owner === norm(AUTONOLAS_DEPLOYER)
            ? "autonolas_deployer"
            : (owner === expected ? "dao_executor" : "other");

    const ownershipChangeRequired = owner === expected ? "no" : "yes";

    return {
        owner,
        expectedDaoExecutor: expected,
        ownerCategory: ownerCategory,
        ownershipChangeRequired: ownershipChangeRequired,
    };
}

// Check the bytecode
async function checkBytecode(provider, configContracts, contractName, log) {
    // Get the contract number from the set of configuration contracts
    for (let i = 0; i < configContracts.length; i++) {
        if (configContracts[i]["name"] === contractName) {
            // Get the contract instance
            const contractFromJSON = fs.readFileSync(configContracts[i]["artifact"], "utf8");
            const parsedFile = JSON.parse(contractFromJSON);
            // Forge JSON
            let bytecode = parsedFile["deployedBytecode"]["object"];
            if (bytecode === undefined) {
                // Hardhat JSON
                bytecode = parsedFile["deployedBytecode"];
            }
            const onChainCreationCode = await provider.getCode(configContracts[i]["address"]);
            // Bytecode DEBUG
            //if (contractName === "ContractName") {
            //    console.log("onChainCreationCode", onChainCreationCode);
            //    console.log("bytecode", bytecode);
            //}

            // Compare last 43 bytes as they reflect the deployed contract metadata hash
            // We cannot compare the full one since the repo deployed bytecode does not contain immutable variable info
            customExpectContain(onChainCreationCode, bytecode.slice(-86),
                log + ", address: " + configContracts[i]["address"] + ", failed bytecode comparison");
            return;
        }
    }
}

// Find the contract name from the configuration data
async function findContractInstance(provider, configContracts, contractName, tokenName) {
    // Get the contract number from the set of configuration contracts
    for (let i = 0; i < configContracts.length; i++) {
        if (configContracts[i]["name"] === contractName) {
            // Get the contract instance
            let contractFromJSON = fs.readFileSync(configContracts[i]["artifact"], "utf8");

            // Additional step for proxy contracts
            if (contractName === "KarmaProxy" || contractName === "MechMarketplaceProxy") {
                // Get previous ABI
                contractFromJSON = fs.readFileSync(configContracts[i - 1]["artifact"], "utf8");
            }

            // Search for corresponding BalanceTrackerFixedPriceToken
            if (contractName === "BalanceTrackerFixedPriceToken" && configContracts[i]["token"] !== tokenName) {
                continue;
            }

            const parsedFile = JSON.parse(contractFromJSON);
            const abi = parsedFile["abi"];
            const contractInstance = new ethers.Contract(configContracts[i]["address"], abi, provider);
            return contractInstance;
        }
    }
}

// Check KarmaProxy: chain Id, provider, parsed globals, configuration contracts, contract name
async function checkKarmaProxy(chainId, provider, globalsInstance, configContracts, contractName, log) {
    // Check the bytecode
    await checkBytecode(provider, configContracts, contractName, log);

    // Get the contract instance
    const karmaProxy = await findContractInstance(provider, configContracts, contractName, "");

    log += ", address: " + karmaProxy.address;
    // Check owner + record CSV
    const ownerInfo = await checkOwner(chainId, karmaProxy, globalsInstance, log);
    recordOwnershipRow(chainId, contractName, karmaProxy.address, ownerInfo);

    // Check the whitelisted marketplace
    const isMarketplaceWhitelisted = await karmaProxy.mapMechMarketplaces(globalsInstance["mechMarketplaceProxyAddress"]);
    customExpect(isMarketplaceWhitelisted, true, log + ", function: mapMechMarketplaces()");
}

// Check MechMarketplaceProxy: chain Id, provider, parsed globals, configuration contracts, contract name
async function checkMechMarketplaceProxy(chainId, provider, globalsInstance, configContracts, contractName, log) {
    // Check the bytecode
    await checkBytecode(provider, configContracts, contractName, log);

    // Get the contract instance
    const mechMarketplaceProxy = await findContractInstance(provider, configContracts, contractName, "");

    log += ", address: " + mechMarketplaceProxy.address;
    // Check owner + record CSV
    const ownerInfo = await checkOwner(chainId, mechMarketplaceProxy, globalsInstance, log);
    recordOwnershipRow(chainId, contractName, mechMarketplaceProxy.address, ownerInfo);

    // Check service registry address
    const serviceRegistry = await mechMarketplaceProxy.serviceRegistry();
    customExpect(serviceRegistry, globalsInstance["serviceRegistryAddress"], log + ", function: serviceRegistry()");

    // Check karma address
    const karma = await mechMarketplaceProxy.karma();
    customExpect(karma, globalsInstance["karmaProxyAddress"], log + ", function: karma()");

    // Check fee
    const fee = await mechMarketplaceProxy.fee();
    customExpect(fee.toString(), globalsInstance["fee"], log + ", function: fee()");

    // Check min response time
    const minResponseTimeout = await mechMarketplaceProxy.minResponseTimeout();
    customExpect(minResponseTimeout.toString(), globalsInstance["minResponseTimeout"], log + ", function: minResponseTimeout()");

    // Check max response time
    const maxResponseTimeout = await mechMarketplaceProxy.maxResponseTimeout();
    customExpect(maxResponseTimeout.toString(), globalsInstance["maxResponseTimeout"], log + ", function: maxResponseTimeout()");

    // Check whitelisted factories
    let isFactoryWhitelisted = await mechMarketplaceProxy.mapMechFactories(globalsInstance["mechFactoryFixedPriceNativeAddress"]);
    customExpect(isFactoryWhitelisted, true, log + ", function: mapMechFactories()");
    if (chainId != 100) {
        isFactoryWhitelisted = await mechMarketplaceProxy.mapMechFactories(globalsInstance["mechFactoryFixedPriceTokenUSDCAddress"]);
        customExpect(isFactoryWhitelisted, true, log + ", function: mapMechFactories()");

        isFactoryWhitelisted = await mechMarketplaceProxy.mapMechFactories(globalsInstance["mechFactoryFixedPriceTokenOLASAddress"]);
        customExpect(isFactoryWhitelisted, true, log + ", function: mapMechFactories()");
    }
    if (chainId == 100) {
        isFactoryWhitelisted = await mechMarketplaceProxy.mapMechFactories(globalsInstance["mechFactoryNvmSubscriptionNativeAddress"]);
        customExpect(isFactoryWhitelisted, true, log + ", function: mapMechFactories()");
    } else if (typeof globalsInstance["mechFactoryNvmSubscriptionTokenUSDCAddress"] !== "undefined") {
        isFactoryWhitelisted = await mechMarketplaceProxy.mapMechFactories(globalsInstance["mechFactoryNvmSubscriptionTokenUSDCAddress"]);
        customExpect(isFactoryWhitelisted, true, log + ", function: mapMechFactories()");
    }

    // Check whitelisted balance trackers
    // FixedPriceNative
    let paymentType = "0xba699a34be8fe0e7725e93dcbce1701b0211a8ca61330aaeb8a05bf2ec7abed1";
    let balanceTracker = await mechMarketplaceProxy.mapPaymentTypeBalanceTrackers(paymentType);
    customExpect(balanceTracker, globalsInstance["balanceTrackerFixedPriceNativeAddress"], log + ", function: mapPaymentTypeBalanceTrackers()");

    // gnosis has a different behavior since its native is a stablecoin
    if (chainId != 100) {
        // FixedPriceToken (usdc)
        paymentType = "0x6406bb5f31a732f898e1ce9fdd988a80a808d36ab5d9a4a4805a8be8d197d5e3";
        balanceTracker = await mechMarketplaceProxy.mapPaymentTypeBalanceTrackers(paymentType);
        customExpect(balanceTracker, globalsInstance["balanceTrackerFixedPriceTokenUSDCAddress"], log + ", function: mapPaymentTypeBalanceTrackers()");

        // FixedPriceToken (olas)
        paymentType = "0x3679d66ef546e66ce9057c4a052f317b135bc8e8c509638f7966edfd4fcf45e9";
        balanceTracker = await mechMarketplaceProxy.mapPaymentTypeBalanceTrackers(paymentType);
        customExpect(balanceTracker, globalsInstance["balanceTrackerFixedPriceTokenOLASAddress"], log + ", function: mapPaymentTypeBalanceTrackers()");
    }

    // gnosis has a different behavior since its native is a stablecoin
    if (chainId == 100) {
        // NvmSubscriptionNative
        paymentType = "0x803dd08fe79d91027fc9024e254a0942372b92f3ccabc1bd19f4a5c2b251c316";
        balanceTracker = await mechMarketplaceProxy.mapPaymentTypeBalanceTrackers(paymentType);
        customExpect(balanceTracker, globalsInstance["balanceTrackerNvmSubscriptionNativeAddress"], log + ", function: mapPaymentTypeBalanceTrackers()");
    } else if (typeof globalsInstance["balanceTrackerNvmSubscriptionTokenUSDCAddress"] !== "undefined") {
        // NvmSubscriptionToken (usdc)
        paymentType = "0x0d6fd99afa9c4c580fab5e341922c2a5c4b61d880da60506193d7bf88944dd14";
        balanceTracker = await mechMarketplaceProxy.mapPaymentTypeBalanceTrackers(paymentType);
        customExpect(balanceTracker, globalsInstance["balanceTrackerNvmSubscriptionTokenUSDCAddress"], log + ", function: mapPaymentTypeBalanceTrackers()");
    }
}

// Check BalanceTracker: chain Id, provider, parsed globals, configuration contracts, contract name, token type
async function checkBalanceTracker(chainId, provider, globalsInstance, configContracts, contractName, tokenName, log) {
    // Get the contract instance
    const balanceTracker = await findContractInstance(provider, configContracts, contractName, tokenName);
    // Check if the contract exists, since different networks might have different set of balance trackers
    if (typeof balanceTracker === "undefined") {
        return;
    }

    // Check the bytecode
    await checkBytecode(provider, configContracts, contractName, log);

    log += ", address: " + balanceTracker.address;
    // Check mech marketplace
    const mechMarketplace = await balanceTracker.mechMarketplace();
    customExpect(mechMarketplace, globalsInstance["mechMarketplaceProxyAddress"], log + ", function: mechMarketplace()");

    // Check drainer
    const drainer = await balanceTracker.drainer();
    const checkDrainerAddress = (chainId == 1 && tokenName === "olas") ?
        globalsInstance["burnerAddress"] : globalsInstance["drainerAddress"];
    customExpect(drainer, checkDrainerAddress, log + ", function: drainer()");

    // Additionally check fixed native token
    if (contractName === "BalanceTrackerFixedPriceNative") {
        const wrappedNativeToken = await balanceTracker.wrappedNativeToken();
        customExpect(wrappedNativeToken, globalsInstance["wrappedNativeTokenAddress"], log + ", function: wrappedNativeToken()");
    }

    // Additionally check fixed token: gnosis is ignored since its native is a stablecoin
    if (contractName === "BalanceTrackerFixedPriceToken" && chainId != 100) {
        const token = await balanceTracker.token();
        const tokenNameAddress = tokenName + "Address";
        customExpect(token, globalsInstance[tokenNameAddress], log + ", function: token()");
    }

    // Additionally check NVM subscription for native
    if (contractName === "BalanceTrackerNvmSubscriptionNative") {
        const subscriptionNFT = await balanceTracker.subscriptionNFT();
        customExpect(subscriptionNFT, globalsInstance["subscriptionNFTAddress"], log + ", function: subscriptionNFT()");

        // Check if subscription exists
        if (globalsInstance["subscriptionTokenId"] !== "") {
            const subscriptionTokenId = await balanceTracker.subscriptionTokenId();
            customExpect(subscriptionTokenId.toString(), ethers.BigNumber.from(globalsInstance["subscriptionTokenId"]).toString(), log + ", function: subscriptionTokenId()");

            const tokenCreditRatio = await balanceTracker.tokenCreditRatio();
            customExpect(tokenCreditRatio.toString(), ethers.BigNumber.from(globalsInstance["tokenCreditRatio"]).toString(), log + ", function: tokenCreditRatio()");
        }
    }

    // Additionally check NVM subscription for tokens
    if (contractName === "BalanceTrackerNvmSubscriptionToken") {
        const subscriptionNFT = await balanceTracker.subscriptionNFT();
        customExpect(subscriptionNFT, globalsInstance["subscriptionNFTAddress"], log + ", function: subscriptionNFT()");

        // Different possible tokens
        if (typeof globalsInstance["subscriptionTokenIdUSDC"] !== "undefined") {
            const subscriptionTokenId = await balanceTracker.subscriptionTokenId();
            customExpect(subscriptionTokenId.toString(), ethers.BigNumber.from(globalsInstance["subscriptionTokenIdUSDC"]).toString(), log + ", function: subscriptionTokenIdUSDC()");

            const tokenCreditRatio = await balanceTracker.tokenCreditRatio();
            customExpect(tokenCreditRatio.toString(), ethers.BigNumber.from(globalsInstance["tokenCreditRatio"]).toString(), log + ", function: tokenCreditRatio()");
        }
    }
}

async function main() {
    // Read configuration from the JSON file
    const configFile = "docs/configuration.json";
    const dataFromJSON = fs.readFileSync(configFile, "utf8");
    const configs = JSON.parse(dataFromJSON);

    let numChains = configs.length;
    // ################################# VERIFY CONTRACTS WITH REPO #################################
    if (verifyRepo) {
        // Traverse all chains
        for (let i = 0; i < numChains; i++) {
            console.log("\n\nNetwork:", configs[i]["name"]);
            const contracts = configs[i]["contracts"];
            const chainId = configs[i]["chainId"];
            console.log("chainId", chainId);

            // Verify contracts
            for (let j = 0; j < contracts.length; j++) {
                console.log("Checking " + contracts[j]["name"]);
                const execSync = require("child_process").execSync;
                try {
                    execSync("scripts/audit_chains/audit_repo_contract.sh " + chainId + " " + contracts[j]["name"] + " " + contracts[j]["address"]);
                } catch (err) {
                    err.stderr.toString();
                }
            }
        }
    }
    // ################################# /VERIFY CONTRACTS WITH REPO #################################

    // ################################# VERIFY CONTRACTS SETUP #################################
    if (verifySetup) {
        const globalNames = {
            "mainnet": "scripts/deployment/globals_eth_mainnet.json",
            "gnosis": "scripts/deployment/globals_gnosis_mainnet.json",
            "base": "scripts/deployment/globals_base_mainnet.json",
            "polygon": "scripts/deployment/globals_polygon_mainnet.json",
            "optimism": "scripts/deployment/globals_optimism_mainnet.json",
            "arbitrum": "scripts/deployment/globals_arbitrum_mainnet.json",
            "celo": "scripts/deployment/globals_celo_mainnet.json"
        };

        const providerLinks = {
            "mainnet": "https://eth-mainnet.g.alchemy.com/v2/" + process.env.ALCHEMY_API_KEY_MAINNET,
            "gnosis": "https://rpc.gnosischain.com",
            "base": "https://mainnet.base.org",
            "polygon": "https://polygon-mainnet.g.alchemy.com/v2/" + process.env.ALCHEMY_API_KEY_MATIC,
            "optimism": "https://public-op-mainnet.fastnode.io",
            "arbitrum": "https://arb1.arbitrum.io/rpc",
            "celo": "https://forno.celo.org"
        };

        // Get all the globals processed
        const globals = new Array();
        const providers = new Array();
        numChains = Object.keys(globalNames).length;
        for (let i = 0; i < numChains; i++) {
            const dataJSON = fs.readFileSync(globalNames[configs[i]["name"]], "utf8");
            globals.push(JSON.parse(dataJSON));
            const provider = new ethers.providers.JsonRpcProvider(providerLinks[configs[i]["name"]]);
            providers.push(provider);
        }

        console.log("\nVerifying deployed contracts setup... If no error is output, then the contracts are correct.");

        // L2 contracts
        for (let i = 0; i < numChains; i++) {
            console.log("\n######## Verifying setup on CHAIN ID", configs[i]["chainId"]);

            const initLog = "ChainId: " + configs[i]["chainId"] + ", network: " + configs[i]["name"];

            let log = initLog + ", contract: " + "KarmaProxy";
            await checkKarmaProxy(configs[i]["chainId"], providers[i], globals[i], configs[i]["contracts"], "KarmaProxy", log);

            log = initLog + ", contract: " + "MechMarketplaceProxy";
            await checkMechMarketplaceProxy(configs[i]["chainId"], providers[i], globals[i], configs[i]["contracts"], "MechMarketplaceProxy", log);

            log = initLog + ", contract: " + "BalanceTrackerFixedPriceNative";
            await checkBalanceTracker(configs[i]["chainId"], providers[i], globals[i], configs[i]["contracts"], "BalanceTrackerFixedPriceNative", "", log);

            log = initLog + ", contract: " + "BalanceTrackerFixedPriceToken: USDC";
            await checkBalanceTracker(configs[i]["chainId"], providers[i], globals[i], configs[i]["contracts"], "BalanceTrackerFixedPriceToken", "usdc", log);

            log = initLog + ", contract: " + "BalanceTrackerFixedPriceToken: OLAS";
            await checkBalanceTracker(configs[i]["chainId"], providers[i], globals[i], configs[i]["contracts"], "BalanceTrackerFixedPriceToken", "olas", log);

            // Skip networks where not deployed
            log = initLog + ", contract: " + "BalanceTrackerNvmSubscriptionNative";
            await checkBalanceTracker(configs[i]["chainId"], providers[i], globals[i], configs[i]["contracts"], "BalanceTrackerNvmSubscriptionNative", "", log);

            log = initLog + ", contract: " + "BalanceTrackerNvmSubscriptionToken";
            await checkBalanceTracker(configs[i]["chainId"], providers[i], globals[i], configs[i]["contracts"], "BalanceTrackerNvmSubscriptionToken", "usdc", log);
        }
    }
    // ################################# /VERIFY CONTRACTS SETUP #################################

    // Write CSV once at the end of setup verification
    if (WRITE_OWNERSHIP_CSV) {
        writeOwnershipCsv(ownershipRows, OWNERSHIP_CSV_PATH);
    }
}

main()
    .then(() => process.exit(0))
    .catch((error) => {
        console.error(error);
        process.exit(1);
    });
