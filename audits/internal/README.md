# Internal audit of autonolas-staking-programmes
The review has been performed based on the contract code in the following repository:<br>
`https://github.com/valory-xyz/autonolas-marketplace` <br>
commit: `05ff5b68a7ff506ab8d0f0feca4015408f067979` <br> 

## Objectives
The audit focused on contracts in this repo. <br>
Limits: The subject of the audit is not contracts used as library contracts. Thus, this audit is not a full-fledged audit of contracts underlying the contract ERC721Mech. <br>

### Flatten version
Flatten version of contracts. [contracts](https://github.com/valory-xyz/autonolas-marketplace/blob/main/audits/internal/analysis/contracts) 

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

AgentMech not ERC721 (by design)
slither-check-erc --erc ERC721 AgentMech-flatten.sol AgentMech    
# Check AgentMech

## Check functions
[ ] balanceOf(address) is missing 
[ ] ownerOf(uint256) is missing 
[ ] safeTransferFrom(address,address,uint256,bytes) is missing 
[ ] safeTransferFrom(address,address,uint256) is missing 
[ ] transferFrom(address,address,uint256) is missing 
[ ] approve(address,uint256) is missing 
[ ] setApprovalForAll(address,bool) is missing 
[ ] getApproved(uint256) is missing 
[ ] isApprovedForAll(address,address) is missing 
[ ] supportsInterface(bytes4) is missing 
[ ] name() is missing (optional)
[ ] symbol() is missing (optional)
[ ] tokenURI(uint256) is missing (optional)

## Check events
[ ] Transfer(address,address,uint256) is missing
[ ] Approval(address,address,uint256) is missing
[ ] ApprovalForAll(address,address,bool) is missing
```

### Security issues. Updated 30-10-2023
#### Problems found instrumentally
Several checks are obtained automatically. They are commented. <br>
All automatic warnings are listed in the following file, concerns of which we address in more detail below: <br>
[slither-full](https://github.com/valory-xyz/autonolas-staking-programmes/blob/main/audits/internal/analysis/slither_full.txt) 
Most of the issues raised by instrumental analysis are outside the scope of the audit. <br>

##### For re-checking and discussion. False positive?
```
INFO:Detectors:
ExtendedAgentFactory.addMech(address,uint256,uint256) (ExtendedAgentFactory-flatten.sol#3933-3956) calls abi.encodePacked() with multiple dynamic arguments:
	- byteCode = abi.encodePacked(byteCode,abi.encode(registry,agentId,price)) (ExtendedAgentFactory-flatten.sol#3944)
Reference: https://github.com/crytic/slither/wiki/Detector-Documentation#abi-encodePacked-collision
Example problem:
keccak256(abi.encodePacked(name, doc));
id1 =  (bob, This is the content)
id2 = (bo, bThis is the content)
id1 == id2
abi.encode uses padding while abi.encodePacked does not. abi.encodePacked whatever will work.
```
[x] Discussed. False positive.

##### Update library contracts as possible
Contracts used as libraries include those that are obviously not needed in the "product" mode. <br> 
```bash
grep -r console ./lib/mech/contracts/    
./lib/mech/contracts/base/ImmutableStorage.sol:import "hardhat/console.sol";
```
[?] Discussed. The update may not be a very easy task. The code `./lib/mech/contracts` has changed a lot.

##### What happens to the incoming native token?
```solidity
contract AgentMech is ERC721Mech {
function request(bytes memory data) external payable returns (uint256 requestId) {
    if (msg.value < price) {
            revert NotEnoughPaid(msg.value, price);
        }

```
[x] Discussed. Used in nested contract functions.

##### Very minor issue.
lacks a zero-check on: <br>
```solidity
contract AgentFactory is GenericManager {
constructor(address _agentRegistry) {
        agentRegistry = _agentRegistry;
        owner = msg.sender;
    }

contract AgentMech is ERC721Mech {
        // Record the price
        price = _price;
...
}
```
[x] Discussed. Price can be zero by design.
