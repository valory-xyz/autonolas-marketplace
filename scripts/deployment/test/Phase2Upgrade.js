/*global process, __dirname*/

// Rehearse only the existing-proxy upgrade using actual scripts and a disposable local chain.
const assert = require("assert");
const fs = require("fs");
const os = require("os");
const path = require("path");
const net = require("net");
const {spawn, execFile} = require("child_process");
const {promisify} = require("util");
const {ethers, artifacts} = require("hardhat");
const execute = promisify(execFile);
const root = path.resolve(__dirname, "../../..");
let checks = 0;
function check(label, condition) { assert(condition, label); console.log("PASS:", label); checks++; }

async function main() {
    const temporary = fs.mkdtempSync(path.join(os.tmpdir(), "marketplace-upgrade-"));
    const server = net.createServer();
    await new Promise((resolve, reject) => { server.once("error", reject); server.listen(0, "127.0.0.1", resolve); });
    const port = server.address().port;
    await new Promise(resolve => server.close(resolve));
    const cleanEnv = {PATH: process.env.PATH, HOME: process.env.HOME};
    if (process.env.FOUNDRY_SOLC) cleanEnv.FOUNDRY_SOLC = process.env.FOUNDRY_SOLC;
    const anvil = spawn("anvil", ["--silent", "--port", String(port), "--chain-id", "31337"], {env: cleanEnv, stdio: "ignore"});
    let startError;
    anvil.on("error", error => { startError = error; });
    try {
        const provider = new ethers.providers.JsonRpcProvider("http://127.0.0.1:" + port);
        let connected = false;
        for (let attempt = 0; attempt < 100; attempt++) {
            if (startError) throw startError;
            try { await provider.getBlockNumber(); connected = true; break; }
            catch { await new Promise(resolve => setTimeout(resolve, 100)); }
        }
        assert(connected, "Anvil did not start");
        const owner = ethers.Wallet.createRandom().connect(provider);
        const requester = ethers.Wallet.createRandom().connect(provider);
        await provider.send("anvil_setBalance", [owner.address, ethers.utils.hexValue(ethers.utils.parseEther("100"))]);
        const env = {...cleanEnv, PRIVATE_KEY: owner.privateKey};
        const deployment = path.join(temporary, "scripts/deployment");
        fs.mkdirSync(deployment, {recursive: true});
        for (const name of ["deploy_03_mech_marketplace.sh", "deploy_05_mech_factory_fixed_price_native.sh",
            "deploy_07a_mech_factory_fixed_price_token_olas.sh", "deploy_07b_mech_factory_fixed_price_token_usdc.sh",
            "script_06_change_implementaion_mech_marketplace_proxy.sh", "script_02a_marketplace_set_factories_fixed.sh",
            "check_marketplace_implementation.py", "check_marketplace_domain.js"])
            fs.copyFileSync(path.join(root, "scripts/deployment", name), path.join(deployment, name));
        for (const name of ["contracts", "lib", "node_modules", "test", "foundry.toml"])
            fs.symlinkSync(path.join(root, name), path.join(temporary, name));
        const globals = path.join(deployment, "globals_local.json");
        let config;
        const save = () => fs.writeFileSync(globals, JSON.stringify(config, null, 2) + "\n");
        const run = async (script, ...args) => {
            const result = await execute("bash", [path.join(deployment, script), "local", ...args],
                {env, cwd: temporary, timeout: 180000, maxBuffer: 1024 * 1024});
            config = JSON.parse(fs.readFileSync(globals, "utf8"));
            return result.stdout;
        };
        const reject = async (label, script, args, message) => {
            const before = fs.readFileSync(globals, "utf8");
            const nonce = await owner.getTransactionCount("latest");
            let error;
            try { await run(script, ...args); } catch (caught) { error = caught; }
            check(label, error && error.stderr.includes(message) && fs.readFileSync(globals, "utf8") === before &&
                await owner.getTransactionCount("latest") === nonce);
        };
        const contract = async (name, address) => new ethers.Contract(ethers.utils.getAddress(address), (await artifacts.readArtifact(name)).abi, owner);
        const deploy = async (name, ...args) => {
            const artifact = await artifacts.readArtifact(name);
            const instance = await new ethers.ContractFactory(artifact.abi, artifact.bytecode, owner).deploy(...args);
            await instance.deployed();
            return instance;
        };
        const fixture = async (filename, ...args) => {
            const artifact = JSON.parse(fs.readFileSync(path.join(root, "abis", filename), "utf8"));
            let bytecode = typeof artifact.bytecode === "string" ? artifact.bytecode : artifact.bytecode.object;
            if (!bytecode.startsWith("0x")) bytecode = "0x" + bytecode;
            const instance = await new ethers.ContractFactory(artifact.abi, bytecode, owner).deploy(...args);
            await instance.deployed();
            return instance;
        };
        const registry = await deploy("MockServiceRegistry");
        const karma = await deploy("Karma");
        await (await karma.initialize()).wait();
        const old = await fixture("0.8.30/MechMarketplace.json", registry.address, karma.address);
        const proxy = await deploy("MechMarketplaceProxy", old.address, old.interface.encodeFunctionData("initialize", [100, 10, 20]));
        const marketplace = await contract("MechMarketplace", proxy.address);
        await (await karma.setMechMarketplaceStatuses([proxy.address], [true])).wait();
        const legacyDomain = await marketplace.getDomainSeparator();
        const assets = [await deploy("WETH9"), await deploy("ERC20Token"), await deploy("ERC20Token")];
        const trackers = [await deploy("BalanceTrackerFixedPriceNative", proxy.address, owner.address, assets[0].address),
            await deploy("BalanceTrackerFixedPriceToken", proxy.address, owner.address, assets[1].address),
            await deploy("BalanceTrackerFixedPriceToken", proxy.address, owner.address, assets[2].address)];
        const paymentNames = ["FixedPriceNative", "FixedPriceToken", "FixedPriceTokenUSDC"];
        const paymentTypes = paymentNames.map(ethers.utils.id);
        await (await marketplace.setPaymentTypeBalanceTrackers(paymentTypes, trackers.map(tracker => tracker.address))).wait();
        // Existing balances must survive: fund them before deploying or upgrading anything.
        for (let i = 0; i < trackers.length; i++) {
            if (i === 0) await (await trackers[i].depositFor(requester.address, {value: 1000})).wait();
            else {
                await (await assets[i].mint(owner.address, 1000)).wait();
                await (await assets[i].approve(trackers[i].address, 1000)).wait();
                await (await trackers[i].depositFor(requester.address, 1000)).wait();
            }
        }
        const oldFactory = await fixture("0.8.28/MechFactoryFixedPriceNative.json", proxy.address);
        await (await marketplace.setMechFactoryStatuses([oldFactory.address], [true])).wait();
        config = {chainId: "31337", networkURL: "http://127.0.0.1:" + port, useLedger: false, contractVerification: false,
            serviceRegistryAddress: registry.address, karmaProxyAddress: karma.address, mechMarketplaceAddress: old.address,
            mechMarketplaceProxyAddress: proxy.address, mechFactoryFixedPriceNativeAddress: oldFactory.address,
            balanceTrackerFixedPriceNativeAddress: trackers[0].address, balanceTrackerFixedPriceTokenOLASAddress: trackers[1].address,
            balanceTrackerFixedPriceTokenUSDCAddress: trackers[2].address, wrappedNativeTokenAddress: assets[0].address,
            olasAddress: assets[1].address, usdcAddress: assets[2].address};
        save();
        await reject("registration rejects the old Marketplace before sending", "script_02a_marketplace_set_factories_fixed.sh",
            ["native"], "Upgrade the Marketplace proxy");
        await run("deploy_03_mech_marketplace.sh");
        const implementation = await contract("MechMarketplace", config.mechMarketplaceAddress);
        check("implementation deployment saves verified version 1.2.0", await implementation.VERSION() === "1.2.0");
        const checkImplementation = () => execute("python3", [path.join(deployment, "check_marketplace_implementation.py"),
            "--implementation", implementation.address, "--proxy", proxy.address, "--chain-id", "31337"],
        {env: {...cleanEnv, MARKETPLACE_RPC_URL: config.networkURL}, cwd: temporary, timeout: 180000});
        const audit = async (name, previous, activated = false, expectedFailures = []) => {
            const args = [path.join(root, "scripts/audit_chains/audit_contracts_setup.js"), "--candidate", name,
                "--globals", globals, "--artifact", path.join(temporary, "out", name + ".sol", name + ".json")];
            if (previous) args.push("--previous-factory", previous);
            if (activated) args.push("--activated");
            let error;
            try {
                await execute(process.execPath, args,
                    {env: {...cleanEnv, MARKETPLACE_RPC_URL: config.networkURL}, cwd: root, timeout: 30000});
            } catch (caught) { error = caught; }
            if (expectedFailures.length) {
                check(name + " audit reports " + expectedFailures.join(", "), error &&
                    expectedFailures.every(text => error.stderr.includes(text)));
            } else {
                if (error) throw error;
                check(name + " audit passes " + (activated ? "after" : "before") + " factory activation", true);
            }
        };
        const beforeCheck = await owner.getTransactionCount("latest");
        await audit("MechMarketplace", undefined, false,
            ["AUDIT FAILED: 2 checks: proxy implementation, proxy VERSION()", "expected=", "observed="]);
        const validChain = config.chainId;
        config.chainId = "1"; save();
        await audit("MechMarketplace", undefined, false, ["RPC chainId versus globals.chainId"]);
        config.chainId = validChain; save();
        await checkImplementation();
        check("governance implementation check works without a signing key or transaction",
            await owner.getTransactionCount("latest") === beforeCheck);
        // Extra unreachable code keeps all getters unchanged but is a different build.
        const reviewedCode = await provider.getCode(implementation.address);
        await provider.send("anvil_setCode", [implementation.address, reviewedCode + "00"]);
        try {
            check("different runtime can retain the same version and constructor getters",
                await implementation.VERSION() === "1.2.0" && await implementation.serviceRegistry() === registry.address &&
                await implementation.karma() === karma.address && (await implementation.chainId()).eq(31337));
            let error;
            try { await checkImplementation(); } catch (caught) { error = caught; }
            check("governance check rejects different code with identical getters",
                error && error.stderr.includes("Implementation does not match the current build"));
            await audit("MechMarketplace", undefined, false,
                ["AUDIT FAILED: 3 checks: runtime hash, proxy implementation, proxy VERSION()"]);
            await reject("upgrade rejects different code before sending", "script_06_change_implementaion_mech_marketplace_proxy.sh",
                [], "Implementation does not match the current build");
        } finally {
            await provider.send("anvil_setCode", [implementation.address, reviewedCode]);
        }
        for (const dependency of ["registry", "karma"]) {
            const wrong = await deploy("MechMarketplace", dependency === "registry" ? assets[0].address : registry.address,
                dependency === "karma" ? assets[0].address : karma.address);
            config.mechMarketplaceAddress = wrong.address; save();
            await audit("MechMarketplace", undefined, false,
                ["runtime hash", dependency === "registry" ? "serviceRegistry()" : "karma()", "proxy implementation"]);
            await reject("upgrade rejects a wrong " + dependency, "script_06_change_implementaion_mech_marketplace_proxy.sh",
                [], "Implementation dependencies differ");
        }
        config.mechMarketplaceAddress = implementation.address; save();
        await run("script_06_change_implementaion_mech_marketplace_proxy.sh");
        await audit("MechMarketplace");
        const validImplementation = config.mechMarketplaceAddress;
        config.mechMarketplaceAddress = requester.address; save();
        await audit("MechMarketplace", undefined, false,
            ["AUDIT FAILED: 6 checks:", "check unavailable", "proxy implementation"]);
        config.mechMarketplaceAddress = validImplementation; save();
        check("upgrade retains the proxy, owner and legacy domain", await proxy.getImplementation() === implementation.address &&
            await marketplace.owner() === owner.address && await marketplace.getDomainSeparator() === legacyDomain);
        check("upgrade retains fee and response timeouts", (await marketplace.fee()).eq(100) &&
            (await marketplace.minResponseTimeout()).eq(10) && (await marketplace.maxResponseTimeout()).eq(20));
        const domain = {name: "MechMarketplace", version: "2", chainId: 31337, verifyingContract: proxy.address};
        check("new explicit-nonce domain matches the standard encoder", await marketplace.getDomainSeparatorWithNonce() === ethers.utils._TypedDataEncoder.hashDomain(domain));
        const checkDomain = (chainId = "31337", address = proxy.address) => execute(process.execPath,
            [path.join(deployment, "check_marketplace_domain.js"), address, chainId],
            {env: {...cleanEnv, MARKETPLACE_RPC_URL: config.networkURL}, cwd: temporary, timeout: 15000});
        const beforeDomainCheck = await owner.getTransactionCount("latest");
        await checkDomain();
        check("post-upgrade domain command works without a signing key or transaction",
            await owner.getTransactionCount("latest") === beforeDomainCheck);
        let domainError;
        try { await checkDomain("1"); } catch (error) { domainError = error; }
        check("domain command rejects the wrong RPC chain", domainError && domainError.stderr.includes("RPC chain ID does not match"));
        domainError = undefined;
        try { await checkDomain("31337", requester.address); } catch (error) { domainError = error; }
        check("domain command rejects an unreadable target", domainError && domainError.stderr.includes("Cannot read the explicit-nonce domain"));
        const proxyCode = await provider.getCode(proxy.address);
        const wrongDomain = ethers.utils._TypedDataEncoder.hashDomain({...domain, version: "1.1.0"});
        try {
            // Local-only replacement returns a valid bytes32 with the wrong signing version.
            await provider.send("anvil_setCode", [proxy.address, "0x7f" + wrongDomain.slice(2) + "60005260206000f3"]);
            domainError = undefined;
            try { await checkDomain(); } catch (error) { domainError = error; }
            check("domain command rejects an incorrect signing domain", domainError && domainError.stderr.includes("does not match the expected EIP-712 domain"));
        } finally {
            await provider.send("anvil_setCode", [proxy.address, proxyCode]);
        }
        await run("deploy_05_mech_factory_fixed_price_native.sh");
        await run("deploy_07a_mech_factory_fixed_price_token_olas.sh");
        await run("deploy_07b_mech_factory_fixed_price_token_usdc.sh");
        // Independently audit both replacement types before and after their permission changes.
        const oldUSDCFactory = await deploy("MechFactoryFixedPriceTokenUSDC", proxy.address);
        await (await marketplace.setMechFactoryStatuses([oldUSDCFactory.address], [true])).wait();
        const replacementTypes = ["MechFactoryFixedPriceNative", "MechFactoryFixedPriceTokenUSDC"];
        const oldFactories = [oldFactory.address, oldUSDCFactory.address];
        const replacementAddresses = [config.mechFactoryFixedPriceNativeAddress, config.mechFactoryFixedPriceTokenUSDCAddress];
        const auditNonce = await owner.getTransactionCount("latest");
        for (let i = 0; i < replacementTypes.length; i++) {
            await audit(replacementTypes[i], oldFactories[i]);
            await audit(replacementTypes[i], oldFactories[i], true,
                ["AUDIT FAILED: 2 checks: new factory permission, previous factory permission"]);
        }
        check("candidate audits send no transactions", await owner.getTransactionCount("latest") === auditNonce);
        await audit(replacementTypes[0], undefined, false, ["--previous-factory must be a nonzero address"]);
        await audit(replacementTypes[0], replacementAddresses[0], false, ["--previous-factory must differ"]);
        const nativeCode = await provider.getCode(replacementAddresses[0]);
        try {
            // Change embedded mech creation code, retaining the factory getter, length and outer metadata.
            const mechArtifact = JSON.parse(fs.readFileSync(path.join(temporary, "out/MechFixedPriceNative.sol/MechFixedPriceNative.json"), "utf8"));
            const offset = nativeCode.indexOf(mechArtifact.bytecode.object.replace(/^0x/, ""));
            assert(offset > 2, "Factory must embed the reviewed mech creation code");
            const changed = nativeCode.slice(0, offset) + "fe" + nativeCode.slice(offset + 2);
            await provider.send("anvil_setCode", [replacementAddresses[0], changed]);
            await audit(replacementTypes[0], oldFactories[0], false, ["AUDIT FAILED: 1 checks: runtime hash"]);
        } finally {
            await provider.send("anvil_setCode", [replacementAddresses[0], nativeCode]);
        }
        const wrongBindingFactory = await deploy("MechFactoryFixedPriceNative", requester.address);
        config.mechFactoryFixedPriceNativeAddress = wrongBindingFactory.address; save();
        await audit(replacementTypes[0], oldFactories[0], false, ["runtime hash", "mechMarketplace()"]);
        config.mechFactoryFixedPriceNativeAddress = replacementAddresses[1]; save();
        await audit(replacementTypes[0], oldFactories[0], false, ["AUDIT FAILED: 1 checks: runtime hash"]);
        config.mechFactoryFixedPriceNativeAddress = replacementAddresses[0]; save();
        await (await marketplace.setMechFactoryStatuses(replacementAddresses, [true, true])).wait();
        await audit(replacementTypes[0], oldFactories[0], true, ["AUDIT FAILED: 1 checks: previous factory permission"]);
        await (await marketplace.setMechFactoryStatuses(oldFactories, [false, false])).wait();
        for (let i = 0; i < replacementTypes.length; i++) await audit(replacementTypes[i], oldFactories[i], true);
        // Restore the pre-registration fixture for the existing deployment-script tests below.
        await (await marketplace.setMechFactoryStatuses([...replacementAddresses, ...oldFactories], [false, false, true, true])).wait();
        const full = {...config};
        const register = "script_02a_marketplace_set_factories_fixed.sh";
        config.mechFactoryFixedPriceNativeAddress = oldFactory.address; save();
        await reject("old factory bytecode is rejected", register, ["native"], "Factory does not match the current build");
        config.mechFactoryFixedPriceNativeAddress = full.mechFactoryFixedPriceTokenOLASAddress; save();
        await reject("wrong factory type is rejected", register, ["native"], "Factory does not match the current build");
        config = {...full}; config.usdcAddress = assets[1].address; save();
        await reject("wrong USDC asset is rejected", register, ["usdc"], "Tracker asset differs");
        config = {...full}; save();
        await (await marketplace.setPaymentTypeBalanceTrackers([paymentTypes[0]], [trackers[1].address])).wait();
        await reject("missing expected tracker mapping is rejected", register, ["native"], "Expected tracker is not registered");
        await (await marketplace.setPaymentTypeBalanceTrackers([paymentTypes[0]], [trackers[0].address])).wait();
        for (const key of ["mechFactoryFixedPriceTokenUSDCAddress", "balanceTrackerFixedPriceTokenUSDCAddress", "usdcAddress"]) delete config[key];
        save(); await run(register, "native", "olas");
        check("native/OLAS selection leaves USDC factory disabled", !await marketplace.mapMechFactories(full.mechFactoryFixedPriceTokenUSDCAddress));
        await (await marketplace.setMechFactoryStatuses([full.mechFactoryFixedPriceTokenOLASAddress], [false])).wait();
        config = {...full};
        for (const key of ["mechFactoryFixedPriceTokenOLASAddress", "balanceTrackerFixedPriceTokenOLASAddress", "olasAddress"]) delete config[key];
        save(); await run(register, "native", "usdc");
        check("native/USDC selection leaves OLAS factory disabled", !await marketplace.mapMechFactories(full.mechFactoryFixedPriceTokenOLASAddress));
        config = {...full}; save(); await run(register, "native", "olas", "usdc");
        check("existing factory status is retained", await marketplace.mapMechFactories(oldFactory.address));
        const fields = ["mechFactoryFixedPriceNativeAddress", "mechFactoryFixedPriceTokenOLASAddress", "mechFactoryFixedPriceTokenUSDCAddress"];
        const mechNames = ["MechFixedPriceNative", "MechFixedPriceToken", "MechFixedPriceTokenUSDC"];
        const types = {ExplicitNonceDelivery: [
            {name: "mech", type: "address"}, {name: "requester", type: "address"}, {name: "data", type: "bytes"},
            {name: "maxDeliveryRate", type: "uint256"}, {name: "paymentType", type: "bytes32"},
            {name: "nonce", type: "uint256"}, {name: "deadline", type: "uint256"}
        ]};
        for (let i = 0; i < fields.length; i++) {
            check(paymentNames[i] + " tracker and pre-upgrade balance retained", await marketplace.mapPaymentTypeBalanceTrackers(paymentTypes[i]) === trackers[i].address &&
                (await trackers[i].mapRequesterBalances(requester.address)).eq(1000));
            await (await registry.setServiceOwner(i + 1, owner.address)).wait();
            const receipt = await (await marketplace.create(i + 1, config[fields[i]], ethers.utils.defaultAbiCoder.encode(["uint256"], [100]))).wait();
            const mech = await contract(mechNames[i], receipt.events.find(event => event.event === "CreateMech").args.mech);
            check(paymentNames[i] + " factory creates mech 1.1.0", await mech.VERSION() === "1.1.0");
            const deadline = (await provider.getBlock("latest")).timestamp + 3600;
            const message = {mech: mech.address, requester: requester.address, data: "0x1234", maxDeliveryRate: 100,
                paymentType: paymentTypes[i], nonce: 77, deadline};
            const signature = await requester._signTypedData(domain, types, message);
            const digest = ethers.utils._TypedDataEncoder.hash(domain, types, message);
            await (await mech["deliverMarketplaceWithSignatures(address,(bytes,bytes,bytes)[],uint256[],uint256[],uint256[],uint256[],bytes)"](
                requester.address, [{requestData: message.data, deliveryData: "0xabcd", signature}], [80], [100], [77], [deadline], "0x")).wait();
            check(paymentNames[i] + " signed settlement uses the retained tracker", await marketplace.getRequestStatus(digest) === 3 &&
                (await trackers[i].mapRequesterBalances(requester.address)).eq(920) && (await mech.numTotalDeliveries()).eq(1));
        }
        await (await marketplace.changeOwner(requester.address)).wait();
        await reject("wrong owner cannot register factories", register, ["native"], "Signer is not Marketplace owner");
        console.log("Upgrade rehearsal checks passed:", checks);
    } finally {
        if (anvil.pid && anvil.exitCode === null) {
            const exited = new Promise(resolve => anvil.once("exit", resolve));
            anvil.kill(); await exited;
        }
        fs.rmSync(temporary, {recursive: true, force: true});
    }
}
main().catch(error => { console.error(error.stderr || error.message); process.exitCode = 1; });
