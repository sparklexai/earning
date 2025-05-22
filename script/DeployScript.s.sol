// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.29;

import "forge-std/Script.sol";
import {SparkleXVault} from "../src/SparkleXVault.sol";
import {ETHEtherFiAAVEStrategy} from "../src/strategies/aave/ETHEtherFiAAVEStrategy.sol";
import {AAVEHelper} from "../src/strategies/aave/AAVEHelper.sol";
import {EtherFiHelper} from "../src/strategies/etherfi/EtherFiHelper.sol";
import {TokenSwapper} from "../src/utils/TokenSwapper.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";

//
// forge script DeployScript.s.sol:DeployScript --rpc-url $RPC --etherscan-api-key $TD_KEY --verify --verifier-url $VERIFY_URL --chain-id 1 -vvvv --broadcast
//
contract DeployScript is Script {
    address payable constant wETH = payable(0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2);
    address constant weETH = 0xCd5fE23C85820F7B72D0926FC9b05b43E359b7ee;
    address constant aWeETH = 0xBdfa7b7893081B35Fb54027489e2Bc7A38275129;

    function run() external {
        // Get private key from environment
        uint256 privateKey = vm.envUint("TESTNET_PRIVATE_KEY");

        vm.startBroadcast(privateKey);

        // Contract creation
        SparkleXVault stkVault = new SparkleXVault(ERC20(wETH), "SparkleX-ETH-Vault", "SPX-ETH-V");

        TokenSwapper tokenSwapper = new TokenSwapper();

        EtherFiHelper etherFiHelper = new EtherFiHelper();

        ETHEtherFiAAVEStrategy myStrategy = new ETHEtherFiAAVEStrategy(address(stkVault));

        AAVEHelper aaveHelper = new AAVEHelper(address(myStrategy), ERC20(weETH), ERC20(wETH), ERC20(aWeETH), 1);

        // Contract linking
        stkVault.addStrategy(address(myStrategy), 100);

        myStrategy.setSwapper(address(tokenSwapper));

        myStrategy.setEtherFiHelper(address(etherFiHelper));

        myStrategy.setAAVEHelper(address(aaveHelper));

        vm.stopBroadcast();
    }
}
