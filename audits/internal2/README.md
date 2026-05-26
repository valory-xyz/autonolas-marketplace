# Internal audit of autonolas-staking-programmes
The review has been performed based on the contract code in the following repository:<br>
`https://github.com/valory-xyz/autonolas-marketplace` <br>
commit: 7a8708d345a2201a1b693164f97dd9266532ea1b (tag: v0.4.0-pre-internal-audit) <br> 

## Objectives
The audit focused on updated marketplace contracts in this repo. <br>
Limits: The subject of the audit is not contracts used as library contracts. Thus, this audit is not a full-fledged audit of contracts underlying the contract ERC721Mech. <br>

### Flatten version
Flatten version of contracts. [contracts](https://github.com/valory-xyz/autonolas-marketplace/blob/main/audits/internal1/analysis/contracts)

### Security issues. Updated 17-12-2024
#### Problems found instrumentally
Several checks are obtained automatically. They are commented. <br>
All automatic warnings are listed in the following file, concerns of which we address in more detail below: <br>
[slither-full](https://github.com/valory-xyz/autonolas-staking-programmes/blob/main/audits/internal2/analysis/slither_full.txt) 
Most of the issues raised by instrumental analysis are outside the scope of the audit. <br>


### Issue
#### Critical? _preDeliver() passed low then price and zero balance 
```
        // Check for the number of credits available in the subscription
        uint256 creditsBalance = IERC1155(subscriptionNFT).balanceOf(account, subscriptionTokenId);

        // Adjust the amount of credits to burn if the deliver price is bigger than the amount of credits available
        uint256 creditsToBurn = deliverPrice;
        if (creditsToBurn > creditsBalance) {
            creditsToBurn = creditsBalance;
        }

        // Burn credits of the request Id sender upon delivery
        if (creditsToBurn > 0) {
            IERC1155(subscriptionNFT).burn(account, subscriptionTokenId, creditsToBurn);
        }
1. creditsBalance = IERC1155(subscriptionNFT).balanceOf => let 1token
2. deliverPrice > creditsBalance => let 2token > 1token
3. creditsToBurn = creditsBalance => creditsToBurn = 1token
4. IERC1155(subscriptionNFT).burn(1token)
Already from my point of view it is a problem. The price is 2 tokens - and we allow to pass with 1 token for the price of 2.
next
1. creditsBalance = IERC1155(subscriptionNFT).balanceOf => let 0token
2. deliverPrice > creditsBalance => let 2token > 0token
3. creditsToBurn = creditsBalance => creditsToBurn = 0token
4. if (creditsToBurn > 0) {
            IERC1155(subscriptionNFT).burn(account, subscriptionTokenId, creditsToBurn);
        } - skip
5. pass        
```
[x] Outdated due to design change

#### Medium. _calculatePayment not update collectedFees;
```
function _calculatePayment(
        address mech,
        uint256 payment
    ) internal virtual returns (uint256 mechPayment, uint256 marketplaceFee) {
```
[x] Outdated due to design change

#### Medium. payable fallback()
```
Must be payable.
fallback() external {
        // solhint-disable-next-line avoid-low-level-calls
```
[x] Fixed

#### Medium. Typo in check. 
```
price == 0 => _price == 0
constructor(address _mechMarketplace, address _serviceRegistry, uint256 _serviceId, uint256 _price)
        OlasMech(_mechMarketplace, _serviceRegistry, _serviceId)
    {
        // Check for zero value
        if (price == 0) {
            revert ZeroValue();
        }
```
[x] Outdated due to design change

####  Low? Notices? OlasMech.setUp(bytes) event
[x] Noticed, internal storage writing

#### Low? Notices? Karma.sol Uniform approach to location getImplementation() (proxy/implementation)
```
Depending on what they understand better for etherscan. Probably in proxy better.
    /// @dev Gets the implementation address.
    /// @return implementation Implementation address.
    function getImplementation() external view returns (address implementation) {
        // solhint-disable-next-line avoid-low-level-calls
        assembly {
            implementation := sload(KARMA_PROXY)
        }
    }
```
[x] Noticed

### Low? improvement create2(), due to unpredictability.
```
function createMech(
        address mechMarketplace,
        address serviceRegistry,
        uint256 serviceId,
        bytes memory payload
    ) external returns (address mech) {
        // Check payload length
        if (payload.length != 32) {
            revert IncorrectDataLength(payload.length, 32);
        }

        // Decode price
        uint256 price = abi.decode(payload, (uint256));

        // Get salt
        bytes32 salt = keccak256(abi.encode(block.timestamp, msg.sender, serviceId));

        // Service multisig is isOperator() for the mech
        mech = address((new MechFixedPrice){salt: salt}(mechMarketplace, serviceRegistry, serviceId, price));
+
require(mech != address(0), "Contract creation failed");
uint256 nonce = nonces[msg.sender]++;
bytes32 salt = keccak256(abi.encode(nonce, block.timestamp, msg.sender, serviceId));

same for contracts\integrations\nevermined\MechFactorySubscription.sol
```
[x] Fixed

### Notices
#### Low? Notices? No issue? initialize and constructor on MechMarketplace + frontrunning (?!) To discussion
```
This is not usually found in a same contract.
 /// @dev MechMarketplace constructor.
    /// @param _serviceRegistry Service registry contract address.
    /// @param _stakingFactory Staking factory contract address.
    /// @param _karma Karma proxy contract address.
    /// @param _wrappedNativeToken Wrapped native token address.
    /// @param _buyBackBurner Buy back burner address.
    constructor(
        address _serviceRegistry,
        address _stakingFactory,
        address _karma,
        address _wrappedNativeToken,
        address _buyBackBurner
    ) {
function initialize(uint256 _fee, uint256 _minResponseTimeout, uint256 _maxResponseTimeout) external {
Frontrunning is possible : between constructor() -> initialize() : No issue!
Changing the storage of implementation has no effect on changing the storage of proxy!
```
[x] Noticed

#### Low? Notices? No issue? frontrunning initialize() in Karma.sol. To discussion
```
deploy -> Karma -> frontrumming initialize() -> deploy KarmaProxy() -> initialize() (no issue, becuse used proxy context) -> Karma

To do this, a "dummy" can be installed in its constructor so that calls to the initialize() function (or similar function) are only possible through a proxy.
Example:
    constructor() {
        // dummy in context of implementation
        admin = address(1);
    }

    function initialize(address _admin) external {
        // in context of proxy
        require(admin == address(0), "Already initialized");
        admin = _admin;
    }
Changing the storage of implementation has no effect on changing the storage of proxy!
```
[x] Noticed, already initialized

### Notices. Variable "price". Problem of terminology
```
Problem of terminology. Price is usually expressed as amount0/amount1 
if (amount < price) {}
```
[x] Outdated

### Notices. for design createMech()
```
Can be called by anyone, a small limitation is that it is called from the marketPlace?
function createMech()
-> callback IMechMarketplace(mechMarketplace).mapMechFactories[mechFactory] == address(this)
```
[x] Fixed

### Notices. Pure? _calculatePayment()
```
function _calculatePayment(
        address mech,
        uint256 payment
    ) internal virtual returns (uint256 mechPayment, uint256 marketplaceFee)
    -> pure?
```
[x] Outdated

### Notices. Low/Notices
```
uint256 private constant FEE_BASIS_POINTS = 10_000; // 100% в bps
```
[x] Fixed


