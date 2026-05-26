# Internal audit of autonolas-marketplace
The review has been performed based on the contract code in the following repository:<br>
`https://github.com/valory-xyz/autonolas-marketplace` <br>
commit: 7b31870dfa20e5b227c76b646cda415a7b9112d9 (tag: v0.4.0-pre-internal-audit4) <br> 

## Objectives
The audit focused on updated marketplace contracts in this repo. <br>
Limits: The subject of the audit is not contracts used as library contracts. Thus, this audit is not a full-fledged audit of contracts underlying the contract ERC721Mech. <br>


## Coverage
```
------------------------------------------|----------|----------|----------|----------|----------------|
File                                      |  % Stmts | % Branch |  % Funcs |  % Lines |Uncovered Lines |
------------------------------------------|----------|----------|----------|----------|----------------|
 contracts/                               |    79.91 |    65.52 |    81.82 |    73.43 |                |
  BalanceTrackerBase.sol                  |    78.26 |    54.76 |    72.73 |    65.66 |... 380,382,384 |
  Karma.sol                               |     62.5 |       30 |    57.14 |    42.42 |... 126,142,155 |
  MechFixedPriceBase.sol                  |      100 |      100 |      100 |      100 |                |
  MechMarketplace.sol                     |    75.21 |    69.84 |    85.71 |    73.48 |... 784,786,788 |
  OlasMech.sol                            |    96.23 |    79.55 |    92.31 |    90.63 |... 234,240,307 |
 contracts/interfaces/                    |      100 |      100 |      100 |      100 |                |
  IBalanceTracker.sol                     |      100 |      100 |      100 |      100 |                |
  IErrorsMarketplace.sol                  |      100 |      100 |      100 |      100 |                |
  IErrorsMech.sol                         |      100 |      100 |      100 |      100 |                |
  IKarma.sol                              |      100 |      100 |      100 |      100 |                |
  IMech.sol                               |      100 |      100 |      100 |      100 |                |
  IServiceRegistry.sol                    |      100 |      100 |      100 |      100 |                |
  IStaking.sol                            |      100 |      100 |      100 |      100 |                |
 contracts/mechs/native/                  |    78.95 |    58.33 |    77.78 |       70 |                |
  BalanceTrackerFixedPriceNative.sol      |    66.67 |    66.67 |    66.67 |    64.71 |... 45,47,76,86 |
  MechFactoryFixedPriceNative.sol         |      100 |       50 |      100 |    76.92 |       49,54,70 |
  MechFixedPriceNative.sol                |      100 |      100 |      100 |      100 |                |
 contracts/mechs/nevermined/              |        0 |        0 |        0 |        0 |                |
  BalanceTrackerNvmSubscriptionNative.sol |        0 |        0 |        0 |        0 |... 190,192,197 |
  MechFactoryNvmSubscription.sol          |        0 |        0 |        0 |        0 |... 66,70,71,74 |
  MechNvmSubscription.sol                 |        0 |      100 |        0 |        0 |... 69,70,72,73 |
 contracts/mechs/token/                   |      100 |       50 |      100 |    82.76 |                |
  BalanceTrackerFixedPriceToken.sol       |      100 |       50 |      100 |     87.5 |          40,60 |
  MechFactoryFixedPriceToken.sol          |      100 |       50 |      100 |    76.92 |       49,54,70 |
  MechFixedPriceToken.sol                 |      100 |      100 |      100 |      100 |                |
 contracts/proxies/                       |      100 |       50 |      100 |    68.42 |                |
  KarmaProxy.sol                          |      100 |       50 |      100 |    66.67 |       37,42,52 |
  MechMarketplaceProxy.sol                |      100 |       50 |      100 |       70 |       36,41,53 |
------------------------------------------|----------|----------|----------|----------|----------------|
All files                                 |    72.93 |    57.82 |    73.33 |    65.57 |                |
------------------------------------------|----------|----------|----------|----------|----------------|
```
insufficient testing coverage
[]

### Security issues. Updated 14-01-24
#### Critical. Please, back to stable/old version of reentrancy lock
```
bool internal transient _locked;
Using new mechanics has unexplored pitfalls.
1. Testing and Edge Cases
Locking mechanisms can sometimes fail in complex scenarios or when interacting with:

Proxies and upgradeable patterns: Upgraded logic contracts might inadvertently break _locked-related assumptions.
External libraries or contracts: Shared state or delegate calls might bypass or conflict with the lock logic.
Layer 2 solutions: Variations in gas metering, rollups, or state channels might behave differently than expected

2. Compatibility with Meta-Transactions
Some EVM networks or meta-transaction relayers rely on intermediate contract calls or simulate transactions before executing them. If your lock implementation interacts poorly with these, it might block valid executions:

Pre-execution simulation (via STATICCALL) might not update _locked properly.
Some meta-transaction frameworks might inadvertently bypass your reentrancy lock if not carefully tested.

3. The previous code was native to the developer and he did not make any mistakes in the constructions.
In general, As auditor I against making unnecessary changes just to follow new concepts. We need unbreakable code.
Ref: Missing _locked = false;
/// @dev Processes mech payment by mech service multisig.
    /// @param mech Mech address.
    /// @return mechPayment Mech payment.
    /// @return marketplaceFee Marketplace fee.
    function processPaymentByMultisig(address mech) external returns (uint256 mechPayment, uint256 marketplaceFee) {
        // Reentrancy guard
        if (_locked) {
            revert ReentrancyGuard();
        }
        _locked = true;

        // Check for mech service multisig address
        if (!IMech(mech).isOperator(msg.sender)) {
            revert UnauthorizedAccount(msg.sender);
        }

        (mechPayment, marketplaceFee) = _processPayment(mech);
    }
```
[x] fixed

#### Medium. Potentially silent function.
```
    A silent function that may not do anything according to its logic, but will be successfully executed.
    Experience has shown that it is a dangerous design when a function does not revert even though no action is actually performed.

    /// @dev Delivers requests.
    /// @notice This function can only be called by the mech delivering the request.
    /// @param requestIds Set of request ids.
    /// @param deliveryRates Corresponding set of actual charged delivery rates for each request.
    /// @param deliveryDatas Set of corresponding self-descriptive opaque delivery data-blobs.
    function deliverMarketplace(
        uint256[] memory requestIds,
        uint256[] memory deliveryRates,
        bytes[] memory deliveryDatas
    ) external returns (bool[] memory deliveredRequests) {
        for (uint256 i = 0; i < numRequests; ++i) {
            ...
            numDeliveries++;
        }
        if (numDeliveries > 0) {
            ...
            emit MarketplaceDelivery(msg.sender, requesters, requestIds, deliveryDatas);
        }
    }
    +
    emit MarketplaceDelivery(msg.sender, requesters, requestIds, deliveryDatas); inside if
```
[x] fixed

#### Notice/Low. Why does this contract accept native token?
```
    ref: https://solidity-by-example.org/hacks/self-destruct/
    Don't rely on address(this).balance 

    BalanceTrackerNvmSubscriptionNative.sol
    /// @dev Deposits funds reflecting subscription.
    receive() external virtual override payable {
        emit Deposit(msg.sender, address(0), msg.value);
    }
```
[x] fixed

#### Notice. Use symantic constant.
```
if (balance < 2) {
            revert ZeroValue();
        }
```
[x] fixed

#### Notice. Group functions
```
In Solidity, it is common practice to group functions based on their visibility and purpose, following a logical and standardized structure to improve code readability and maintainability.
```
[]


#### Notice. Unify revert msg
```
function _verifySignedHash(address requester, bytes32 requestHash, bytes memory signature) internal view {
    revert HashNotValidated(requester, requestHash, signature); // 1271
    ...
    revert WrongRequesterAddress(recRequester, requester); // ECDSA
```
[x] fixed







