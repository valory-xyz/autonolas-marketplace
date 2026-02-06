/*global process*/

const { ethers } = require("hardhat");
const { LedgerSigner } = require("@anders-t/ethers-ledger");

async function main() {
    const fs = require("fs");
    const globalsFile = "globals.json";
    const dataFromJSON = fs.readFileSync(globalsFile, "utf8");
    let parsedData = JSON.parse(dataFromJSON);
    const useLedger = parsedData.useLedger;
    const derivationPath = parsedData.derivationPath;
    const providerName = parsedData.providerName;
    const gasPriceInGwei = parsedData.gasPriceInGwei;
    const mechMarketplaceProxyAddress = parsedData.mechMarketplaceProxyAddress;
    const balanceTrackerFixedPriceNativeAddress = parsedData.balanceTrackerFixedPriceNativeAddress;
    const balanceTrackerFixedPriceTokenOLASAddress = parsedData.balanceTrackerFixedPriceTokenOLASAddress;
    const balanceTrackerNvmSubscriptionNativeAddress = parsedData.balanceTrackerNvmSubscriptionNativeAddress;

    let networkURL = parsedData.networkURL;
    if (providerName === "polygon") {
        if (!process.env.ALCHEMY_API_KEY_MATIC) {
            console.log("set ALCHEMY_API_KEY_MATIC env variable");
        }
        networkURL += process.env.ALCHEMY_API_KEY_MATIC;
    } else if (providerName === "polygonMumbai") {
        if (!process.env.ALCHEMY_API_KEY_MUMBAI) {
            console.log("set ALCHEMY_API_KEY_MUMBAI env variable");
            return;
        }
        networkURL += process.env.ALCHEMY_API_KEY_MUMBAI;
    }

    const provider = new ethers.providers.JsonRpcProvider(networkURL);
    const signers = await ethers.getSigners();

    let EOA;
    if (useLedger) {
        EOA = new LedgerSigner(provider, derivationPath);
    } else {
        EOA = signers[0];
    }
    // EOA address
    const deployer = await EOA.getAddress();
    console.log("EOA is:", deployer);

    // Get the contract instance
    const mechMarketplace = await ethers.getContractAt("MechMarketplace", mechMarketplaceProxyAddress);

    // Transaction signing and execution
    console.log("13. EOA to set Balance trackers");
    console.log("You are signing the following transaction: MechMarketplaceProxy.connect(EOA).setMechFactoryStatuses()");
    const gasPrice = ethers.utils.parseUnits(gasPriceInGwei, "gwei");
    const result = await mechMarketplace.connect(EOA).setPaymentTypeBalanceTrackers(
        ["0xba699a34be8fe0e7725e93dcbce1701b0211a8ca61330aaeb8a05bf2ec7abed1", "0x3679d66ef546e66ce9057c4a052f317b135bc8e8c509638f7966edfd4fcf45e9", ""],
        [balanceTrackerFixedPriceNativeAddress, balanceTrackerFixedPriceTokenOLASAddress, balanceTrackerNvmSubscriptionNativeAddress],
        { gasPrice }
    );

    // Transaction details
    console.log("Contract deployment: MechMarketplaceProxy");
    console.log("Contract address:", mechMarketplace.address);
    console.log("Transaction:", result.hash);
}

main()
    .then(() => process.exit(0))
    .catch((error) => {
        console.error(error);
        process.exit(1);
    });
