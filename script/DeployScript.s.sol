// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.29;

import "forge-std/Script.sol";
import {SparkleXVault} from "../src/SparkleXVault.sol";
import {ETHEtherFiAAVEStrategy} from "../src/strategies/aave/ETHEtherFiAAVEStrategy.sol";
import {PendleStrategy} from "../src/strategies/pendle/PendleStrategy.sol";
import {PendleHelper} from "../src/strategies/pendle/PendleHelper.sol";
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
    address constant pendleRouteV4 = 0x888888888889758F76e7103c6CbF23ABbF58F946;
    address constant USDC_USD_Feed = 0x8fFfFfd4AfB6115b954Bd326cbe7B4BA576818f6;
    address constant usdc = 0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48;

    function run() external {
        // Get private key from environment
        uint256 privateKey = vm.envUint("TESTNET_PRIVATE_KEY");

        vm.startBroadcast(privateKey);

        // Contract creation
        SparkleXVault stkVault = new SparkleXVault(ERC20(wETH), "SparkleX-ETH-Vault", "SPX-ETH-V");

        ETHEtherFiAAVEStrategy myStrategy = new ETHEtherFiAAVEStrategy(address(stkVault));

        TokenSwapper tokenSwapper = new TokenSwapper();

        EtherFiHelper etherFiHelper = new EtherFiHelper();

        AAVEHelper aaveHelper = new AAVEHelper(address(myStrategy), ERC20(weETH), ERC20(wETH), ERC20(aWeETH), 1);

        SparkleXVault stkVault2 = new SparkleXVault(ERC20(usdc), "SparkleX-USDC-Vault", "SPX-USDC-V");

        PendleStrategy myStrategy2 = new PendleStrategy(ERC20(usdc), address(stkVault2), USDC_USD_Feed);

        PendleHelper pendleHelper = new PendleHelper(address(myStrategy2), pendleRouteV4, address(tokenSwapper));

        // Contract linking
        stkVault.addStrategy(address(myStrategy), 100);

        myStrategy.setSwapper(address(tokenSwapper));

        myStrategy.setEtherFiHelper(address(etherFiHelper));

        myStrategy.setAAVEHelper(address(aaveHelper));

        stkVault2.addStrategy(address(myStrategy2), 100);

        myStrategy2.setSwapper(address(tokenSwapper));

        myStrategy2.setPendleHelper(address(pendleHelper));

        vm.stopBroadcast();
    }
}
