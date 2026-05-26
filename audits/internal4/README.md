# Internal audit of autonolas-marketplace
The review has been performed based on the contract code in the following repository:<br>
`https://github.com/valory-xyz/autonolas-marketplace` <br>
commit: 4f5c44c069e5c94435420abbbac6e0f0cba67c39 (tag: v0.4.0-pre-internal-audit3) <br> 

## Objectives
The audit focused on updated marketplace contracts in this repo. <br>
Limits: The subject of the audit is not contracts used as library contracts. Thus, this audit is not a full-fledged audit of contracts underlying the contract ERC721Mech. <br>

### Flatten version
Flatten version of contracts. [contracts](https://github.com/valory-xyz/autonolas-marketplace/blob/main/audits/internal4/analysis/contracts)

### Security issues. Updated 07-01-24
#### Problems found instrumentally
Several checks are obtained automatically. They are commented. <br>
All automatic warnings are listed in the following file, concerns of which we address in more detail below: <br>
[slither-full](https://github.com/valory-xyz/autonolas-staking-programmes/blob/main/audits/internal4/analysis/slither_full.txt) <br>
Most of the issues raised by instrumental analysis are outside the scope of the audit. <br>

### Issue
#### Medium/Issue? Bug in processPayment(address requester) ? 
```
        // Get credits to burn
        uint256 creditsToBurn = subscriptionBalance - balance;
        if (creditsToBurn == 0) {
            revert InsufficientBalance(0, 0);
        }

        // Clear balances
        mapRequesterBalances[requester] = 0;

        // Burn credits of the request Id sender upon delivery
        IERC1155(subscriptionNFT).burn(requester, subscriptionTokenId, creditsToBurn);
Question:
        // Get requester credit balance
        uint256 balance = mapRequesterBalances[requester];
        // Get requester actual subscription balance
        uint256 subscriptionBalance = IERC1155(subscriptionNFT).balanceOf(requester, subscriptionTokenId);

        Let balance = A
        subscriptionBalance = B
        if OK new subscriptionBalance = subscriptionBalance - balance ?
        So,
        IERC1155(subscriptionNFT).burn(requester, subscriptionTokenId, balance);
Re-check all balance logic.
```
[x] fixed

#### Medium/Notes. Design of balance update.
```
        // Adjust account balance
        balance -= maxDeliveryRate;
        mapRequesterBalances[requester] = balance;

        vs

                // Check for delivery rate difference
        uint256 rateDiff;
        if (maxDeliveryRate > actualDeliveryRate) {
            // Return back requester overpayment debit
            rateDiff = maxDeliveryRate - actualDeliveryRate;
            mapRequesterBalances[requester] += rateDiff;
        } else {
            // Limit the rate by the max chosen one as that is what the requester agreed on
            actualDeliveryRate = maxDeliveryRate;
        }

        // Record payment into mech balance
        mapMechBalances[mech] += actualDeliveryRate;
    Atomic (IMO) operation that is spread over two different time actions. 
    Isn't it more correct to update balances at one time and in one function than to do crediting
```
[x] False positive, mapRequesterBalances is different from mapMechBalances

#### Medium/Notes (docstring) issue: There is no official ERC or EIP that mandates the behavior or interface of wrapped tokens.
```
The interface for WETH or any wrapped native token (like wETH, wBNB, wMATIC, wFTM, etc.) is not universally standardized across all EVM-compatible chains.
Here's an overview of major L2 networks and the compatibility of this pattern:
- Optimism
- Arbitrum
- Polygon
- Base (as OP)
Needed re-check and possible in-compatibility
- zkSync
- StarkNet
- Avalanche
- Celo
Example code for CELO
/// @dev Drains the specified amount.
/// @param amount Token amount.
function _drain(uint256 amount) internal virtual override {
    // Transfer CELO directly to the Buy back burner
    IToken(wrappedNativeToken).transfer(buyBackBurner, amount);

    emit Drained(wrappedNativeToken, amount);
}

Ref code:
    /// @dev Wraps native token.
    /// @param amount Token amount.
    function _wrap(uint256 amount) internal virtual {
        IWrappedToken(wrappedNativeToken).deposit{value: amount}();
    }
```
[x] Function is virtual, can be overridden with other instructions

#### Low issue: Not checking mech != address(0) in checkMech
```
function checkMech(address mech) public view returns (address multisig) {
        uint256 mechServiceId = IMech(mech).tokenId();

        // Check mech validity as it must be created and recorded via this marketplace
        // ISSUE address(0) != address(0)
        if (mapServiceIdMech[mechServiceId] != mech) {
            revert UnauthorizedAccount(mech);
        }

        // Check mech service Id and get its multisig
        multisig = IMech(mech).getOperator();
    }
Not checking mech != address(0)
```
[x] fixed


#### Low issue: An asymmetric pattern for using function of OLAS (included L2-version) token. issue "transfer"
```
in function _withdraw(address account, uint256 amount) internal virtual override {
        bool success = IToken(olas).transfer(account, amount);
-> checking status
-> not checking status in
~/valory/autonolas-marketplace$ grep -r ".transfer" ./contracts/ | grep IToken
./contracts/mechs/token/BalanceTrackerFixedPriceToken.sol:        IToken(olas).transfer(buyBackBurner, amount);
./contracts/mechs/token/BalanceTrackerFixedPriceToken.sol:        IToken(olas).transferFrom(requester, address(this), amount);
./contracts/mechs/token/BalanceTrackerFixedPriceToken.sol:        IToken(olas).transferFrom(msg.sender, address(this), amount);
./contracts/mechs/native/BalanceTrackerFixedPriceNative.sol:        IToken(wrappedNativeToken).transfer(buyBackBurner, amount);
~/valory/autonolas-marketplace$ 

```
[x] fixed

#### Low issue: An asymmetric pattern for using function of OLAS (included L2-version) token. issue "re-base (?!)" "OLAS"
```
function _getRequiredFunds(address requester, uint256 amount) internal virtual override returns (uint256) {
        uint256 balanceBefore = IToken(olas).balanceOf(address(this));
        // Get tokens from requester
        IToken(olas).transferFrom(requester, address(this), amount);
        uint256 balanceAfter = IToken(olas).balanceOf(address(this));

        // Check the balance
        uint256 diff = balanceAfter - balanceBefore;
        if (diff != amount) {
            revert TransferFailed(olas, requester, address(this), amount);
        }
Only here is it additionally checked that the action actually changes the balances correctly. 
This raises questions, since in one case it is considered possible, and in others it is not. 
OLAS does not belong to the family of tokens ERC-20, where this behavior is possible.
```
[x] fixed

#### Low issue: Not CEI in *Token.sol
```
/// @dev Withdraws funds.
    /// @param account Account address.
    /// @param amount Token amount.
    function _withdraw(address account, uint256 amount) internal virtual override {
        bool success = IToken(olas).transfer(account, amount);

        // Check transfer
        if (!success) {
            revert TransferFailed(olas, address(this), account, amount);
        }

        emit Withdraw(msg.sender, olas, amount);
    }

    /// @dev Deposits token funds for requester.
    /// @param amount Token amount.
    function deposit(uint256 amount) external {
        IToken(olas).transferFrom(msg.sender, address(this), amount);

        // Update account balances
        mapRequesterBalances[msg.sender] += amount;

        emit Deposit(msg.sender, olas, amount);
    }
}
Correct:
Check: First, validate all the conditions necessary for the function to proceed.
Effects: Then, update the state of the contract.
Interactions: Finally, interact with external contracts or send Ether.

```
[x] fixed

#### Low issue: Predicted msg.sender in createMech()
```
Most likely it was meant as an idea that in keccak256(abi.encode(block.timestamp, msg.sender, serviceId, localNonce)) msg.sender is random.
But, de-facto msg.sender is always eq mechMarketplace
Using tx.origin is generally not recommended for any critical logic, even for something as seemingly harmless as including it in a salt for keccak256. 
Instead:
- Stick with msg.sender or parameters directly provided by the caller (e.g., user-provided data in payload).
- Use block.number for ensuring uniqueness.
- Do nothing (documented it)
Ref:
function createMech(
        address serviceRegistry,
        uint256 serviceId,
        bytes memory payload
    ) external returns (address mech) {
        ...
        if (msg.sender != mechMarketplace) {
            revert MarketplaceOnly(msg.sender, mechMarketplace);
        }
        ...
        // Get salt
        bytes32 salt = keccak256(abi.encode(block.timestamp, msg.sender, serviceId, localNonce))
```
[x] fixed

#### Notes/Issue? creditsToBurn to zero is revert
```
See, above
/// @dev Processes requester credits.
    /// @param requester Requester address.
    function processPayment(address requester) external {
        // Get credits to burn
        uint256 creditsToBurn = subscriptionBalance - balance;
        if (creditsToBurn == 0) {
            revert InsufficientBalance(0, 0);
        }
Why does writing off exactly to zero cause revert()
```
[x] fixed

