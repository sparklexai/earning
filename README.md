### Overview

Classic ERC4626 design pattern is used to allow a 1:N mapping for one `SparkleXVault` to multiple strategies.

Partners could use `SparkleXVault.depositWithReferral()` to mark associated deposits with a referral address which is useful for tracking referral earnings.

Owner of `SparkleXVault` (typically a `TimelockController`) could use `SparkleXVault.addStrategy()` to put new yield strategy in work and delete those deprecated via `SparkleXVault.removeStrategy()`.

In addition to withdrawal fee which is charged upon asset `withdraw()` or share `redeem()`, there is also a management fee calculated with regard to `SparkleXVault.totalAssets()`. Permissioned actor could call `SparkleXVault.accumulateManagementFee()` at fixed intervals.

Different from vanilla ERC4626 redemption(withdrawal), it is recommended to use `SparkleXVault.requestRedemption()` to unify the cases **when** there is enough idle asset (no wait needed) and **when** the redemption can't be satisfied immediately (has to be processed later such as request asset withdrwal from EtherFi).

### Strategies

Currently there are following strategies:

- `ETHEtherFiAAVEStrategy`: looping the deposit of `weETH` by borrowing `ETH` in AAVE or SparkFi while keeping a safe LTV
- `PendleAAVEStrategy`: looping the deposit of PT token by borrowing stablecoins in AAVE or SparkFi while keeping a safe LTV
- `PendleStrategy`: aims to actively search for good returns in Pendle markets by trading PTs

### Deployment

Foundry scipts are used to deploy & verify: 

- `script/DeployScript.s.sol` for core contracts like `SparkleXVault` and related strategies
- `script/DeployPeriphery.s.sol` for periphery contracts like `TimelockController`