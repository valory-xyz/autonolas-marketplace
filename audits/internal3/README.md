# Internal audit of autonolas-staking-programmes
The review has been performed based on the contract code in the following repository:<br>
`https://github.com/valory-xyz/autonolas-marketplace` <br>
commit: 7a8708d345a2201a1b693164f97dd9266532ea1b (tag: v0.4.0-pre-internal-audit2) <br> 

## Objectives
The audit focused on updated marketplace contracts in this repo. <br>
Limits: The subject of the audit is not contracts used as library contracts. Thus, this audit is not a full-fledged audit of contracts underlying the contract ERC721Mech. <br>

### Flatten version
Flatten version of contracts. [contracts](https://github.com/valory-xyz/autonolas-marketplace/blob/main/audits/internal3/analysis/contracts)

### Security issues. Updated 20-12-24
#### Problems found instrumentally
Several checks are obtained automatically. They are commented. <br>
All automatic warnings are listed in the following file, concerns of which we address in more detail below: <br>
[slither-full](https://github.com/valory-xyz/autonolas-staking-programmes/blob/main/audits/internal3/analysis/slither_full.txt) 
Most of the issues raised by instrumental analysis are outside the scope of the audit. <br>


### Issue
#### Medium. Make sure that the previous comments (internal - internal2) have been addressed.
[x] Addressed

#### Critical/Medium. checkAndRecordDeliveryRate() for native token
```
function checkAndRecordDeliveryRate()
This is not the right behavior for a case msg.value > 0 and native token contracts.
```
[x] Fixed

#### Low. More Reentrancy protection
```
function checkAndRecordDeliveryRate()
function finalizeDeliveryRate() 
+ Reentrancy protection agains IMech(mech).maxDeliveryRate()
```
[x] Fixed

#### Notices. unintuitive name vs action
```
function _checkNativeValue() internal virtual override
The function name is very unintuitive. In reality, it just does a revert if the contract type is token.
```
[x] Fixed

#### Notices. checkAndRecordDeliveryRate why are uint256 parameters needed
```
Why unused params?
/ Check and record delivery rate
    function checkAndRecordDeliveryRate(
        address mech,
        address requester,
        uint256
If this is abstract data for the future, it is better to replace it with bytes payload.
```
[x] Fixed