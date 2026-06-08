# Internal audit of autonolas-marketplace
The review has been performed based on the contract code in the following repository:<br>
`https://github.com/valory-xyz/autonolas-marketplace` <br>
commit: c72195a6be5bbefcfa40af87f2e1c1bfed2fa9e7 (tag: v0.4.1-pre-internal-audit) <br> 

## Objectives
The audit focused on NVM-usdc marketplace contracts in this repo. <br>
Limits: The subject of the audit is not contracts used as library contracts. Thus, this audit is not a full-fledged audit of contracts underlying the contract ERC721Mech. <br>


## Coverage
```
------------------------------------------|----------|----------|----------|----------|----------------|
File                                      |  % Stmts | % Branch |  % Funcs |  % Lines |Uncovered Lines |
------------------------------------------|----------|----------|----------|----------|----------------|
  contracts/mechs/nevermined_token/        |    94.12 |     87.5 |    57.14 |    85.71 |                |
  BalanceTrackerNvmSubscriptionToken.sol  |    94.12 |     87.5 |    57.14 |    85.71 |... 122,160,166 |
 contracts/mechs/nevermined_token/usdc/   |      100 |      100 |      100 |      100 |                |
  MechFactoryNvmSubscriptionTokenUSDC.sol |      100 |      100 |      100 |      100 |                |
  MechNvmSubscriptionTokenUSDC.sol        |      100 |      100 |      100 |      100 |                |

```
insufficient testing coverage
[]

### Security issues. 
#### Notes
```
Does different decimals in ERC20 affect it somehow? I don't think so, and everything is calculated and compared in raw values. For discussion.
        // Convert mech credits balance into tokens
        balance = (balance * tokenCreditRatio) / 1e18;
        mapMechBalances[mech] = balance;

        // Check current contract balance
        uint256 trackerBalance = IERC20(token).balanceOf(address(this));
        if (balance > trackerBalance) {
            revert Overflow(balance, trackerBalance);
        }
```
[x] Discussed, not an issue







