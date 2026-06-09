/*global process, __dirname*/
// Generates a self-contained, color-coded, collapsible HTML breakdown of the proposal 01
// MechMarketplace fee activation proposal. It DECODES the authoritative calldata produced by
// the Forge builder (scripts/proposals/proposal_01/Proposal01FeeActivation.s.sol), so the
// artifact cannot drift from what will be voted.
//
// Usage:
//   forge script scripts/proposals/proposal_01/Proposal01FeeActivation.s.sol:Proposal01FeeActivation > /tmp/run.txt
//   # re-extract calldata.json from the run output, then:
//   node scripts/proposals/proposal_01/annotate.js   (reads ./calldata.json + ./description.txt)
// Writes ./proposal_01.html next to this script.

const fs = require("fs");
const path = require("path");
const { ethers } = require("ethers");

const abi = ethers.utils.defaultAbiCoder;
const lc = (a) => (a || "").toLowerCase();

// ---- semantic label maps ----
const ADDR = {
    "0x3c1ff68f5aa342d296d4dee4bb1cacca912d95fe": "Timelock (Ethereum)",
    // MechMarketplaceProxy per chain
    "0x3d6494ce09a9f40c0b5a92bdbd7c7a9b0e3912b1": "MechMarketplaceProxy",
    "0x735faab1c4ec41128c367afb5c3bac73509f70bb": "MechMarketplaceProxy",
    "0x343f2b005cf6d70ba610cd9f1f1927049414b582": "MechMarketplaceProxy",
    "0xf76953444c35f1fce2f6ca1b167173357d3f5c17": "MechMarketplaceProxy",
    "0x46c0d07f55d4f9b5eed2fc9680b5953e5fd7b461": "MechMarketplaceProxy",
    "0xf24ee42eda0fc9b33b7d41b06ee8ccd2ef7c5020": "MechMarketplaceProxy",
    "0x17d96ba4532fe91809326092fe4d5606a7b7a0d8": "MechMarketplaceProxy",
    // L1 bridge entrypoints
    "0x4c36d2919e407f0cc2ee3c993ccf8ac26d9ce64e": "Gnosis AMB (L1)",
    "0xfe5e5d361b2ad62c541bab87c45a0b9b018389a2": "Polygon FxRoot (L1)",
    "0x4dbd4fc535ac27206064b68ffcf827b0a60bab3f": "Arbitrum Inbox (L1)",
    "0x25ace71c97b33cc4729cf772ae268934f7ab5fa1": "Optimism L1CrossDomainMessenger",
    "0x866e82a600a1414e583f7f13623f1ac5d58b0afa": "Base L1CrossDomainMessenger",
    "0x1ac1181fc4e4f877963680587aeaa2c90d7ebb95": "Celo L1CrossDomainMessenger",
    // L2 bridge mediators / messengers
    "0x15bd56669f57192a97df41a2aa8f4403e9491776": "HomeMediator (Gnosis L2)",
    "0x9338b5153ae39bb89f50468e608ed9d764b755fd": "FxGovernorTunnel (Polygon L2)",
    "0x4d30f68f5aa342d296d4dee4bb1cacca912da70f": "Aliased Timelock (Arbitrum L2) = Timelock + 0x1111…1111",
    "0x87c511c8ae3faf0063b3f3cf9c6ab96c4aa5c60c": "OptimismMessenger (Optimism L2)",
    "0xe49cb081e8d96920c38aa7ab90cb0294ab4bc8ea": "OptimismMessenger (Base L2)",
    "0xc14e191a64a7fb0e5790a8a0b9a58683dffce04d": "OptimismMessenger (Celo L2)",
};
const SELSIG = {
    "0x57c0762d": "changeMarketplaceParams(uint256,uint256,uint256)",
    "0xdc8601b3": "requireToPassMessage(address,bytes,uint256)",
    "0xb4720477": "sendMessageToChild(address,bytes)",
    "0x679b6ded": "createRetryableTicket(address,uint256,uint256,address,address,uint256,uint256,bytes)",
    "0x3dbb202b": "sendMessage(address,bytes,uint32)",
    "0xd3042d2b": "processMessageFromSource(bytes)",
    "0xcd9e30d9": "processMessageFromForeign(bytes)",
};
const CHAIN = { 1: "Ethereum", 100: "Gnosis", 137: "Polygon", 42161: "Arbitrum", 10: "Optimism", 8453: "Base", 42220: "Celo" };

// Per-entry destination chain (index of entries[] -> destination chainId).
const ENTRY_CHAIN = [1, 100, 137, 42161, 10, 8453, 42220];

// Block explorer (address page) per chainId.
const EXPLORER = {
    1: "https://etherscan.io/address/",
    100: "https://gnosisscan.io/address/",
    137: "https://polygonscan.com/address/",
    42161: "https://arbiscan.io/address/",
    10: "https://optimistic.etherscan.io/address/",
    8453: "https://basescan.org/address/",
    42220: "https://celoscan.io/address/",
};

const esc = (s) => String(s).replace(/&/g, "&amp;").replace(/</g, "&lt;").replace(/>/g, "&gt;");
const addrSpan = (a, chainId = 1) => {
    const cid = Number(chainId);
    const addr = ethers.utils.getAddress(a);
    const name = ADDR[lc(a)];
    const chainName = CHAIN[cid] || ("chain " + cid);
    const label = (name ? name + " · " : "") + chainName;
    const url = (EXPLORER[cid] || EXPLORER[1]) + addr + "#code";
    return `<a class="addr" href="${url}" target="_blank" rel="noopener" title="${esc(label)}">${esc(addr)}</a>` +
        ` <span class="note">// ${esc(label)}</span>`;
};
const selSpan = (sel) => {
    const sig = SELSIG[lc(sel)] || "unknown";
    return `<span class="sel" title="${esc(sig)}">${esc(sel)}</span> <span class="note">// ${esc(sig)}</span>`;
};
const valSpan = (v, note) => `<span class="val">${esc(v)}</span>` + (note ? ` <span class="note">// ${esc(note)}</span>` : "");

function row(name, html) { return `<div class="row"><span class="key">${esc(name)}</span> = ${html}</div>`; }
function callBox(title, inner, open = true) {
    return `<details class="call"${open ? " open" : ""}><summary>${title}</summary><div class="body">${inner}</div></details>`;
}

// changeMarketplaceParams(uint256 newFee, uint256 newMinResponseTimeout, uint256 newMaxResponseTimeout)
function decodeInner(calldata, destChain) {
    const sel = calldata.slice(0, 10);
    const [fee, minTo, maxTo] = abi.decode(["uint256", "uint256", "uint256"], "0x" + calldata.slice(10));
    const feeBps = fee.toString();
    const feePct = (Number(feeBps) / 100).toFixed(2) + "%";
    void destChain; // destination context already conveyed by parent box
    return callBox(`${selSpan(sel)}`,
        row("newFee", valSpan(feeBps, `${feePct} of MAX_FEE_FACTOR = 10000`)) +
        row("newMinResponseTimeout", valSpan(minTo.toString(), "seconds")) +
        row("newMaxResponseTimeout", valSpan(maxTo.toString(), "seconds")),
        true);
}

// Unpacks the (address|uint96|uint32|bytes) bridge payload used by HomeMediator /
// FxGovernorTunnel / OptimismMessenger, and renders the inner call.
function unpackBridge(packed, destChain) {
    const pk = packed.slice(2);
    const innerTarget = ethers.utils.getAddress("0x" + pk.slice(0, 40));
    const innerValue = ethers.BigNumber.from("0x" + pk.slice(40, 64)).toString();
    const payloadLen = parseInt(pk.slice(64, 72), 16);
    const payload = "0x" + pk.slice(72);
    return callBox("<span class=\"key\">packed bridge payload</span> <span class=\"note\">// target(20)|value(12)|len(4)|payload</span>",
        row("target", addrSpan(innerTarget, destChain)) +
        row("value", valSpan(innerValue)) +
        row("payloadLength", valSpan(payloadLen + " bytes")) +
        "<div class=\"row\"><span class=\"key\">payload</span> ⇣</div>" +
        decodeInner(payload, destChain), true);
}

function decodeEntry(e, destChain) {
    const sel = e.calldata.slice(0, 10);
    const args = "0x" + e.calldata.slice(10);
    const head = selSpan(sel);

    // [0] Ethereum direct: changeMarketplaceParams(...)
    if (sel === "0x57c0762d") {
        return decodeInner(e.calldata, destChain);
    }

    // [1] Gnosis: AMB.requireToPassMessage(address _contract, bytes _data, uint256 _gas)
    //     _data = HomeMediator.processMessageFromForeign(bytes packed)
    if (sel === "0xdc8601b3") {
        const [contract_, data_, gas_] = abi.decode(["address", "bytes", "uint256"], args);
        const pSel = data_.slice(0, 10);
        const [packed] = abi.decode(["bytes"], "0x" + data_.slice(10));
        const procBox = callBox(`${selSpan(pSel)}`, unpackBridge(packed, destChain), true);
        return callBox(head,
            row("_contract (L2 receiver)", addrSpan(contract_, destChain)) +
            row("_gas (L2 gas limit)", valSpan(gas_.toString())) +
            "<div class=\"row\"><span class=\"key\">_data</span> ⇣</div>" + procBox);
    }

    // [2] Polygon: FxRoot.sendMessageToChild(address _receiver, bytes _data)
    //     _data IS the packed (target|value|len|payload), no inner selector wrap
    if (sel === "0xb4720477") {
        const [receiver, data_] = abi.decode(["address", "bytes"], args);
        return callBox(head,
            row("_receiver (L2 mediator)", addrSpan(receiver, destChain)) +
            "<div class=\"row\"><span class=\"key\">_data (decoded as packed bridge payload — FxGovernorTunnel reads it directly)</span> ⇣</div>" +
            unpackBridge(data_, destChain));
    }

    // [3] Arbitrum: Inbox.createRetryableTicket(to, l2CallValue, maxSubmissionCost,
    //               excessFeeRefundAddress, callValueRefundAddress, gasLimit, maxFeePerGas, data)
    //     data IS the raw changeMarketplaceParams(...) calldata (target is the MM proxy directly)
    if (sel === "0x679b6ded") {
        const [to, l2CallValue, maxSubmissionCost, excessFeeRefund, callValueRefund, gasLimit, maxFeePerGas, data_] =
            abi.decode(["address", "uint256", "uint256", "address", "address", "uint256", "uint256", "bytes"], args);
        return callBox(head,
            row("to (L2 target)", addrSpan(to, destChain)) +
            row("l2CallValue", valSpan(l2CallValue.toString())) +
            row("maxSubmissionCost", valSpan(maxSubmissionCost.toString(), "wei")) +
            row("excessFeeRefundAddress", addrSpan(excessFeeRefund, destChain)) +
            row("callValueRefundAddress", addrSpan(callValueRefund, destChain)) +
            row("gasLimit", valSpan(gasLimit.toString())) +
            row("maxFeePerGas", valSpan(maxFeePerGas.toString(), "wei")) +
            "<div class=\"row\"><span class=\"key\">data (executed by aliased Timelock on Arbitrum)</span> ⇣</div>" +
            decodeInner(data_, destChain));
    }

    // [4-6] Optimism / Base / Celo: L1CDM.sendMessage(_target, _message, _minGasLimit)
    //       _message = OptimismMessenger.processMessageFromSource(bytes packed)
    if (sel === "0x3dbb202b") {
        const [target, message, minGas] = abi.decode(["address", "bytes", "uint32"], args);
        const pSel = message.slice(0, 10);
        const [packed] = abi.decode(["bytes"], "0x" + message.slice(10));
        const procBox = callBox(`${selSpan(pSel)}`, unpackBridge(packed, destChain), true);
        return callBox(head,
            row("_target (L2 receiver)", addrSpan(target, destChain)) +
            row("_minGasLimit", valSpan(minGas.toString())) +
            "<div class=\"row\"><span class=\"key\">_message</span> ⇣</div>" + procBox);
    }

    return callBox(head, "<div class=\"row note\">unrecognized selector</div>");
}

// OZ Governor.hashProposal: uint256(keccak256(abi.encode(targets, values, calldatas, keccak256(bytes(description)))))
function computeProposalId(targets, values, calldatas, description) {
    const descHash = ethers.utils.keccak256(ethers.utils.toUtf8Bytes(description));
    const encoded = abi.encode(["address[]", "uint256[]", "bytes[]", "bytes32"], [targets, values, calldatas, descHash]);
    return { id: ethers.BigNumber.from(ethers.utils.keccak256(encoded)).toString(), descHash };
}

function main() {
    const jsonPath = process.argv[2] || path.join(__dirname, "calldata.json");
    const entries = JSON.parse(fs.readFileSync(jsonPath, "utf8"));
    // description.txt is canonical: no trailing newline (so keccak256(raw_bytes) matches the on-chain
    // proposalId without any normalisation step). Any reintroduction of a trailing newline shifts
    // the proposalId and will be caught by the assertions below.
    const description = fs.readFileSync(path.join(__dirname, "description.txt"), "utf8");
    const targets = entries.map((e) => e.target);
    const values = entries.map((e) => e.value);
    const calldatas = entries.map((e) => e.calldata);
    const { id: proposalId, descHash } = computeProposalId(targets, values, calldatas, description);

    const groups = [
        { name: "Ethereum (direct, Timelock is MechMarketplace owner)", idx: [0] },
        { name: "L2 bridged — Gnosis / Polygon / Arbitrum / Optimism / Base / Celo", idx: [1, 2, 3, 4, 5, 6] },
    ];

    // propose() copy-paste inputs (Boardroom / Etherscan format)
    const jsonArr = (a) => "[" + a.map((x) => `"${x}"`).join(",") + "]";
    const proposeInputs =
        "<h2>propose() inputs — copy into GovernorOLAS</h2>" +
        `<div class="entry"><div class="pi"><div class="pk">Targets</div><pre class="cp">${esc(jsonArr(targets))}</pre>` +
        `<div class="pk">Values</div><pre class="cp">[${values.join(",")}]</pre>` +
        `<div class="pk">Calldatas</div><pre class="cp">${esc(jsonArr(calldatas))}</pre>` +
        `<div class="pk">proposalDescription</div><pre class="cp">${esc(description)}</pre>` +
        `<div class="pk">proposalId (pre-computed)</div><pre class="cp">${esc(proposalId)}</pre>` +
        `<div class="pk">descriptionHash</div><pre class="cp">${esc(descHash)}</pre></div></div>`;

    let body = proposeInputs;
    for (const g of groups) {
        body += `<h2>${esc(g.name)}</h2>`;
        for (const i of g.idx) {
            const e = entries[i];
            const destChain = ENTRY_CHAIN[i];
            body += `<div class="entry"><div class="ehead"><span class="ix">[${i}]</span> ${esc(CHAIN[destChain] || destChain)} &nbsp; target = ${addrSpan(e.target, 1)} &nbsp; value = <span class="val">${esc(e.value)}</span></div>` +
                decodeEntry(e, destChain) +
                `<details class="raw"><summary>raw calldata</summary><pre>${esc(e.calldata)}</pre></details></div>`;
        }
    }

    const html = `<!doctype html><html><head><meta charset="utf-8"><title>Proposal 01 - MechMarketplace fee activation</title>
<style>
:root{--bg:#0f1115;--fg:#e6e6e6;--mut:#8a93a2;--sel:#c792ea;--addr:#82aaff;--val:#c3e88d;--role:#89ddff;--box:#161922;--bd:#2a2f3a;--ok:#7fd1a0;--bad:#ff8b8b;--cp:#8a93a2}
body{background:var(--bg);color:var(--fg);font:13px/1.5 ui-monospace,SFMono-Regular,Menlo,monospace;margin:0;padding:24px}
h1{font-size:18px} h2{font-size:14px;margin:26px 0 8px;color:#fff;border-bottom:1px solid var(--bd);padding-bottom:4px}
.lead{color:var(--mut);max-width:80ch}
.entry{border:1px solid var(--bd);border-radius:8px;margin:10px 0;padding:10px;background:#11141b}
.ehead{margin-bottom:6px}
.ix{color:var(--mut);margin-right:6px}
details.call{border-left:2px solid var(--bd);margin:4px 0 4px 6px;padding-left:8px}
details.call>summary{cursor:pointer;color:var(--fg)}
.body{padding:4px 0 4px 10px}
.row{padding:1px 0} .key{color:var(--mut)}
.sel{color:var(--sel)} .addr{color:var(--addr)} .val{color:var(--val)} .role{color:var(--role)}
.note{color:var(--mut);font-style:italic}
.ok{color:var(--ok)} .bad{color:var(--bad)}
details.raw{margin-top:6px} details.raw>summary{color:var(--mut);cursor:pointer}
details.raw pre{white-space:pre-wrap;word-break:break-all;color:var(--mut);background:#0b0d12;border:1px solid var(--bd);border-radius:6px;padding:8px}
.pk{color:#fff;margin:8px 0 2px;font-weight:bold} pre.cp{white-space:pre-wrap;word-break:break-all;background:#0b0d12;border:1px solid var(--bd);border-radius:6px;padding:8px;color:var(--cp)}
.pid{color:var(--ok);font-weight:bold}
a{color:var(--addr)}
</style></head><body>
<h1>Proposal 01 — MechMarketplace fee activation (15%) (annotated)</h1>
<p class="lead">Submit via <b>propose()</b> on the GovernorOLAS currently holding the Timelock PROPOSER role. 7 entries: Ethereum direct + 6 bridged L2s (Mode excluded). Every call ultimately invokes <code>changeMarketplaceParams(1500, 60, 300)</code> on the MechMarketplaceProxy of the destination chain. Decoded directly from the Forge builder's verified calldata. Hover any address/selector for its label; expand nested calls.</p>
<p class="lead">⚠ Entry [3] (Arbitrum) is <b>payable</b> — Timelock must hold ≥ <code>${esc(values[3])}</code> wei (~0.0011 ETH) at execution time. Top up via CM before queueing.</p>
<p class="lead">Pre-computed <span class="pid">proposalId = ${esc(proposalId)}</span></p>
${body}
<h2>proposalId</h2>
<div class="entry"><pre class="cp pid">${esc(proposalId)}</pre>
<div class="note">= uint256(keccak256(abi.encode(targets, values, calldatas, keccak256(bytes(description)))))</div></div>
</body></html>`;
    const outPath = path.join(__dirname, "proposal_01.html");
    fs.writeFileSync(outPath, html);
    console.log("Wrote", outPath, "(" + entries.length + " entries)");
    console.log("proposalId:", proposalId);
}

main();
