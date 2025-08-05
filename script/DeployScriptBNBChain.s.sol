// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.29;

import "forge-std/Script.sol";
import {SparkleXVault} from "../src/SparkleXVault.sol";
import {PendleStrategy} from "../src/strategies/pendle/PendleStrategy.sol";
import {PendleHelper} from "../src/strategies/pendle/PendleHelper.sol";
import {AAVEHelper} from "../src/strategies/aave/AAVEHelper.sol";
import {TokenSwapper} from "../src/utils/TokenSwapper.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";

//
// forge script DeployScriptBNBChain.s.sol:DeployScriptBNBChain --rpc-url $RPC --etherscan-api-key $TD_KEY --verify --verifier-url $VERIFY_URL --chain-id 1 -vvvv --broadcast
//
contract DeployScriptBNBChain is Script {
    address public constant pendleRouteV4 = 0x888888888889758F76e7103c6CbF23ABbF58F946;
    address public constant PT_sUSDe = 0x3b3fB9C57858EF816833dC91565EFcd85D96f634;
    address public constant MARKET_sUSDe = 0x4339Ffe2B7592Dc783ed13cCE310531aB366dEac;
    address public constant PT_USDS = 0xFfEc096c087C13Cc268497B89A613cACE4DF9A48;
    address public constant MARKET_USDS = 0xdacE1121e10500e9e29d071F01593fD76B000f08;

    function run() external {
        // Get private key from environment
        uint256 privateKey = vm.envUint("TESTNET_PRIVATE_KEY");
        address strategist = vm.envAddress("TESTNET_STRATEGIST");

        vm.startBroadcast(privateKey);
        TokenSwapper tokenSwapper = new TokenSwapper();
        tokenSwapper.setSlippage(9900);
        vm.stopBroadcast();

        // deploy USDC vault and related strategies
        _createUSDCVaultBundle(privateKey, address(tokenSwapper), strategist);
    }

    function _createUSDCVaultBundle(uint256 _privateKey, address _tokenSwapper, address _strategist) internal {
        address usdc = TokenSwapper(_tokenSwapper).USDC_BNB();
        address USDC_USD_Feed = TokenSwapper(_tokenSwapper).USDC_USD_Feed_BNB();
        vm.startBroadcast(_privateKey);

        // Contract creation
        SparkleXVault stkVault = new SparkleXVault(ERC20(usdc), "SparkleX USD Vault", "spUSD");
        PendleStrategy myStrategy = new PendleStrategy(ERC20(usdc), address(stkVault), USDC_USD_Feed, 900);
        PendleHelper pendleHelper = new PendleHelper(address(myStrategy), pendleRouteV4, _tokenSwapper);

        // Contract linking
        stkVault.addStrategy(address(myStrategy), 1e28);
        stkVault.setEarnRatio(10000);
        stkVault.setRedemptionClaimer(_strategist);

        myStrategy.setSwapper(address(_tokenSwapper));
        myStrategy.setPendleHelper(address(pendleHelper));
        _addPTJuly2025(myStrategy, TokenSwapper(_tokenSwapper));
        myStrategy.setStrategist(_strategist);
        TokenSwapper(_tokenSwapper).setWhitelist(address(pendleHelper), true);

        vm.stopBroadcast();
    }

    function _addPTJuly2025(PendleStrategy _pendleStrategy, TokenSwapper _tokenSwapper) internal {
        // https://app.redstone.finance/app/feeds/bnb-chain/usdx/
        address USDX_USD_Feed = TokenSwapper(_tokenSwapper).USDX_USD_Feed();
        address USDe_USD_Feed = TokenSwapper(_tokenSwapper).USDe_USD_Feed_BNB();
        address USR_USD_Feed = TokenSwapper(_tokenSwapper).USR_USD_Feed_BNB();
        address usde = TokenSwapper(_tokenSwapper).USDe_BNB();
        address usr = TokenSwapper(_tokenSwapper).USR_BNB();

        // sUSDX https://app.pendle.finance/trade/markets/0xe08fc3054450053cd341da695f72b18e6110fffc/swap?view=pt&chain=bnbchain
        _pendleStrategy.addPT(
            0xE08fC3054450053cd341da695f72b18E6110ffFC,
            0x7788A3538C5fc7F9c7C8A74EAC4c898fC8d87d92,
            0x7788A3538C5fc7F9c7C8A74EAC4c898fC8d87d92,
            USDX_USD_Feed,
            0, // 1800,
            0 // 21700
        );
        // USDe https://app.pendle.finance/trade/markets/0xb5b56637810e4d090894785993f4cdd6875d927e/swap?view=pt&chain=bnbchain
        _pendleStrategy.addPT(0xB5B56637810E4d090894785993F4CdD6875D927E, usde, USDe_USD_Feed, address(0), 0, 0); // 1800, 86400);
        // USR https://app.pendle.finance/trade/markets/0x1630d8228588d406767c2225f927154c05d2e2bb/swap?view=pt&chain=bnbchain
        _pendleStrategy.addPT(
            0x1630d8228588d406767C2225F927154c05d2E2bb,
            usr,
            USR_USD_Feed,
            address(0),
            0, // 1800,
            0 // 86400
        );
    }
}
