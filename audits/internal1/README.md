# Internal audit of autonolas-staking-programmes
The review has been performed based on the contract code in the following repository:<br>
`https://github.com/valory-xyz/autonolas-marketplace` <br>
commit: 8c80f4c97015a893dd9f0a028fe914a9336a6d28 (tag: v0.3.0-pre-internal-audit) <br> 

## Objectives
The audit focused on marketplace contracts in this repo. <br>
Limits: The subject of the audit is not contracts used as library contracts. Thus, this audit is not a full-fledged audit of contracts underlying the contract ERC721Mech. <br>

### Flatten version
Flatten version of contracts. [contracts](https://github.com/valory-xyz/autonolas-marketplace/blob/main/audits/internal1/analysis/contracts) 

### ERC20/ERC721 checks
```bash
slither-check-erc --erc ERC721 AgentRegistry-flatten.sol AgentRegistry    
# Check AgentRegistry

## Check functions
[✓] balanceOf(address) is present
        [✓] balanceOf(address) -> (uint256) (correct return type)
        [✓] balanceOf(address) is view
[✓] ownerOf(uint256) is present
        [✓] ownerOf(uint256) -> (address) (correct return type)
        [✓] ownerOf(uint256) is view
[✓] safeTransferFrom(address,address,uint256,bytes) is present
        [✓] safeTransferFrom(address,address,uint256,bytes) -> () (correct return type)
        [✓] Transfer(address,address,uint256) is emitted
[✓] safeTransferFrom(address,address,uint256) is present
        [✓] safeTransferFrom(address,address,uint256) -> () (correct return type)
        [✓] Transfer(address,address,uint256) is emitted
[✓] transferFrom(address,address,uint256) is present
        [✓] transferFrom(address,address,uint256) -> () (correct return type)
        [✓] Transfer(address,address,uint256) is emitted
[✓] approve(address,uint256) is present
        [✓] approve(address,uint256) -> () (correct return type)
        [✓] Approval(address,address,uint256) is emitted
[✓] setApprovalForAll(address,bool) is present
        [✓] setApprovalForAll(address,bool) -> () (correct return type)
        [✓] ApprovalForAll(address,address,bool) is emitted
[✓] getApproved(uint256) is present
        [✓] getApproved(uint256) -> (address) (correct return type)
        [✓] getApproved(uint256) is view
[✓] isApprovedForAll(address,address) is present
        [✓] isApprovedForAll(address,address) -> (bool) (correct return type)
        [✓] isApprovedForAll(address,address) is view
[✓] supportsInterface(bytes4) is present
        [✓] supportsInterface(bytes4) -> (bool) (correct return type)
        [✓] supportsInterface(bytes4) is view
[✓] name() is present
        [✓] name() -> (string) (correct return type)
        [✓] name() is view
[✓] symbol() is present
        [✓] symbol() -> (string) (correct return type)
[✓] tokenURI(uint256) is present
        [✓] tokenURI(uint256) -> (string) (correct return type)

## Check events
[✓] Transfer(address,address,uint256) is present
        [✓] parameter 0 is indexed
        [✓] parameter 1 is indexed
        [✓] parameter 2 is indexed
[✓] Approval(address,address,uint256) is present
        [✓] parameter 0 is indexed
        [✓] parameter 1 is indexed
        [✓] parameter 2 is indexed
[✓] ApprovalForAll(address,address,bool) is present
        [✓] parameter 0 is indexed
        [✓] parameter 1 is indexed
```

### Security issues. Updated 22-08-2024
#### Problems found instrumentally
Several checks are obtained automatically. They are commented. <br>
All automatic warnings are listed in the following file, concerns of which we address in more detail below: <br>
[slither-full](https://github.com/valory-xyz/autonolas-staking-programmes/blob/main/audits/internal1/analysis/slither_full.txt) 
Most of the issues raised by instrumental analysis are outside the scope of the audit. <br>


##### Logic for request to AgentMech without Marketplace
```
/// @dev Registers a request.
    /// @notice This function is called by the marketplace contract since this mech was specified as a priority one.
    /// @param account Requester account address.
    /// @param data Self-descriptive opaque data-blob.
    /// @param requestId Request Id.
    function request(
        address account,
        bytes memory data,
        uint256 requestId
    ) external payable {
        if (mechMarketplace != address(0) && msg.sender != mechMarketplace) {
            revert MarketplaceOnly(msg.sender, mechMarketplace);
        }

        // Check the request payment
        _preRequest(msg.value, requestId, data);
root issue:
1. if mechMarketplace == address(0), then client must calculate requestId before(!) request.
in this sense this logic without a marketplace is broken. it is necessary to either prohibit the logic in case marketplace == address(0) or recover requestId = getRequestId(msg.sender, data, mapNonces[msg.sender]); to AgentMech as failback.
due to the fact that the main problem is desynchronization requestId on Marketplace and AgentMech better: if (msg.sender != mechMarketplace) { revert(); }
2. Same problem: if mechMarketplace == address(0), account in this case MUST be msg.sender (not arbitrary account, as in case Marketplace->agentMech)
mapRequestsCounts[account]++;
```
[x] fixed

#### Incorrect changeMechKarma
```
if (priorityMech != msg.sender) {
            // Within the defined response time only a chosen priority mech is able to deliver
            if (block.timestamp > mechDelivery.responseTimeout) {
                // Decrease priority mech karma as the mech did not deliver
                IKarma(karmaProxy).changeMechKarma(msg.sender, -1);
                // Revoke request from the priority mech
                IMech(priorityMech).revokeRequest(requestId);
            } else {
                // Priority mech responseTimeout is still >= block.timestamp
                revert PriorityMechResponseTimeout(mechDelivery.responseTimeout, block.timestamp);
            }
        }
to
IKarma(karmaProxy).changeMechKarma(priorityMech, -1);
```
[x] fixed

##### Update library contracts as possible
Contracts used as libraries include those that are obviously not needed in the "product" mode. <br> 
```bash
grep -r console ./lib/mech/contracts/    
./lib/mech/contracts/base/ImmutableStorage.sol:import "hardhat/console.sol";
```
[?] Discussed before: The update may not be a very easy task. The code `./lib/mech/contracts` has changed a lot.

### Re-audit. Updated 26-08-2024
The review has been performed based on the contract code in the following repository:<br>
`https://github.com/valory-xyz/autonolas-marketplace` <br>
commit: e8b93801287ed28551eaaa908a621cffe5a082c5 (tag: v0.3.1-pre-internal-audit) <br> 

#### Medium? More checks are needed. 
```
by design requester != mech in both cases: request/delivery (correct me if I am wrong)
    function request(
        bytes memory data,
        address priorityMech,
        address priorityMechStakingInstance,
        uint256 priorityMechServiceId,
        uint256 responseTimeout,
        address requesterStakingInstance,
        uint256 requesterServiceId
    ) external payable returns (uint256 requestId) {
=>
        if(msg.sender == priorityMech) { revert()} - expected Mech cannot request delivery to itself.

function deliverMarketplace(
        uint256 requestId,
        bytes memory requestData,
        address deliveryMechStakingInstance,
        uint256 deliveryMechServiceId
    ) external
=>
        if(msg.sender == mechDelivery.requester) { revert() } - de-facto Mech cannot request delivery to itself.

try solved: IMech(mech).isOperator(requester) 

+ maybe/ maybe not
priorityMechStakingInstance != requesterStakingInstance ?? => to discussion
```
[x] fixed

#### Notices: clarification
```
AgentMech
function requestMarketplace()
maybe change the name. It is not obvious from the name who calls whom. According to the code, it is correct that the marketplace calls the agent.
Not sure.
```
[x] fixed