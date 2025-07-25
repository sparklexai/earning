// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.29;

import "forge-std/Script.sol";
import {SparkleXVault} from "../src/SparkleXVault.sol";
import {ETHEtherFiAAVEStrategy} from "../src/strategies/aave/ETHEtherFiAAVEStrategy.sol";
import {PendleAAVEStrategy} from "../src/strategies/aave/PendleAAVEStrategy.sol";
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
    address public constant pendleRouteV4 = 0x888888888889758F76e7103c6CbF23ABbF58F946;
    address public constant USDC_USD_Feed = 0x8fFfFfd4AfB6115b954Bd326cbe7B4BA576818f6;
    address public constant USDe_USD_FEED = 0xa569d910839Ae8865Da8F8e70FfFb0cBA869F961;
    address public constant USDS_USD_Feed = 0xfF30586cD0F29eD462364C7e81375FC0C71219b1;
    address public constant usdc = 0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48;
    address public constant sUSDe = 0x9D39A5DE30e57443BfF2A8307A4256c8797A3497;
    address public constant usds = 0xdC035D45d973E3EC169d2276DDab16f1e407384F;
    address public constant PT_sUSDe = 0x3b3fB9C57858EF816833dC91565EFcd85D96f634;
    address public constant PT_ATOKEN_sUSDe = 0xDE6eF6CB4aBd3A473ffC2942eEf5D84536F8E864;
    address public constant MARKET_sUSDe = 0x4339Ffe2B7592Dc783ed13cCE310531aB366dEac;
    address public constant PT_USDS = 0xFfEc096c087C13Cc268497B89A613cACE4DF9A48;
    address public constant MARKET_USDS = 0xdacE1121e10500e9e29d071F01593fD76B000f08;

    function run() external {
        // Get private key from environment
        uint256 privateKey = vm.envUint("TESTNET_PRIVATE_KEY");
        address strategist = vm.envAddress("TESTNET_STRATEGIST");

        // deploy wETH vault and related strategies
        address _tokenSwapperAddr = _createETHVaultBundle(privateKey, strategist);

        // deploy USDC vault and related strategies
        _createUSDCVaultBundle(privateKey, _tokenSwapperAddr, strategist);
    }

    function _createETHVaultBundle(uint256 _privateKey, address _strategist) internal returns (address) {
        vm.startBroadcast(_privateKey);

        // Contract creation
        SparkleXVault stkVault = new SparkleXVault(ERC20(wETH), "SparkleX-ETH-Vault", "spETH");
        ETHEtherFiAAVEStrategy myStrategy = new ETHEtherFiAAVEStrategy(address(stkVault));
        TokenSwapper tokenSwapper = new TokenSwapper();
        tokenSwapper.setSlippage(9900);
        EtherFiHelper etherFiHelper = new EtherFiHelper();
        AAVEHelper aaveHelper = new AAVEHelper(address(myStrategy), ERC20(weETH), ERC20(wETH), ERC20(aWeETH), 1);

        // Contract linking
        stkVault.addStrategy(address(myStrategy), 1000000e18);
        stkVault.setEarnRatio(10000);
        stkVault.setRedemptionClaimer(_strategist);

        myStrategy.setSwapper(address(tokenSwapper));
        myStrategy.setEtherFiHelper(address(etherFiHelper));
        myStrategy.setAAVEHelper(address(aaveHelper));
        myStrategy.setStrategist(_strategist);
        tokenSwapper.setWhitelist(address(myStrategy), true);

        vm.stopBroadcast();

        return address(tokenSwapper);
    }

    function _createUSDCVaultBundle(uint256 _privateKey, address _tokenSwapper, address _strategist) internal {
        vm.startBroadcast(_privateKey);

        // Contract creation
        SparkleXVault stkVault = new SparkleXVault(ERC20(usdc), "SparkleX-USDC-Vault", "spUSDC");
        PendleStrategy myStrategy = new PendleStrategy(ERC20(usdc), address(stkVault), USDC_USD_Feed, 86400);
        PendleHelper pendleHelper = new PendleHelper(address(myStrategy), pendleRouteV4, _tokenSwapper);
        PendleAAVEStrategy myStrategy2 = new PendleAAVEStrategy(usdc, address(stkVault));
        PendleHelper pendleHelper2 = new PendleHelper(address(myStrategy2), pendleRouteV4, _tokenSwapper);
        AAVEHelper aaveHelper =
            new AAVEHelper(address(myStrategy2), ERC20(PT_sUSDe), ERC20(usdc), ERC20(PT_ATOKEN_sUSDe), 8);

        // Contract linking
        stkVault.addStrategy(address(myStrategy), 1e18);
        stkVault.addStrategy(address(myStrategy2), 1e18);
        stkVault.setEarnRatio(10000);
        stkVault.setRedemptionClaimer(_strategist);

        myStrategy.setSwapper(address(_tokenSwapper));
        myStrategy.setPendleHelper(address(pendleHelper));
        _addPTJuly2025(myStrategy, TokenSwapper(_tokenSwapper));
        myStrategy.setStrategist(_strategist);
        TokenSwapper(_tokenSwapper).setWhitelist(address(pendleHelper), true);

        myStrategy2.setSwapper(address(_tokenSwapper));
        myStrategy2.setPendleHelper(address(pendleHelper2));
        myStrategy2.setAAVEHelper(address(aaveHelper));
        myStrategy2.setPendleMarket(MARKET_sUSDe);
        myStrategy2.setStrategist(_strategist);
        TokenSwapper(_tokenSwapper).setWhitelist(address(pendleHelper2), true);

        vm.stopBroadcast();
    }

    function _addPTJuly2025(PendleStrategy _pendleStrategy, TokenSwapper _tokenSwapper) internal {
        // sUSDe https://app.pendle.finance/trade/markets/0xA36b60A14A1A5247912584768C6e53E1a269a9F7/swap?view=pt&chain=ethereum
        _pendleStrategy.addPT(0xA36b60A14A1A5247912584768C6e53E1a269a9F7, sUSDe, sUSDe, USDe_USD_FEED, 900, 86400);
        // USDe https://app.pendle.finance/trade/markets/0x6d98a2b6CDbF44939362a3E99793339Ba2016aF4/swap?view=pt&chain=ethereum
        _pendleStrategy.addPT(
            0x6d98a2b6CDbF44939362a3E99793339Ba2016aF4, _tokenSwapper.usde(), USDe_USD_FEED, address(0), 900, 86400
        );
        // eUSDe https://app.pendle.finance/trade/markets/0xE93B4A93e80BD3065B290394264af5d82422ee70/swap?view=pt&chain=ethereum
        _pendleStrategy.addPT(
            0xE93B4A93e80BD3065B290394264af5d82422ee70,
            0x90D2af7d622ca3141efA4d8f1F24d86E5974Cc8F,
            0x90D2af7d622ca3141efA4d8f1F24d86E5974Cc8F,
            USDe_USD_FEED,
            900,
            86400
        );
        // USR https://app.pendle.finance/trade/markets/0x33BdA865c6815c906e63878357335B28f063936c/swap?view=pt&chain=ethereum
        _pendleStrategy.addPT(
            0x33BdA865c6815c906e63878357335B28f063936c,
            _tokenSwapper.USR(),
            _tokenSwapper.USR_USD_FEED(),
            address(0),
            1800,
            86400
        );
        // wstUSR https://app.pendle.finance/trade/markets/0x09fA04Aac9c6d1c6131352EE950CD67ecC6d4fB9/swap?view=pt&chain=ethereum
        _pendleStrategy.addPT(
            0x09fA04Aac9c6d1c6131352EE950CD67ecC6d4fB9,
            0x1202F5C7b4B9E47a1A484E8B270be34dbbC75055,
            0x1202F5C7b4B9E47a1A484E8B270be34dbbC75055,
            _tokenSwapper.USR_USD_FEED(),
            1800,
            86400
        );
        // syrupUSDC https://app.pendle.finance/trade/markets/0x9A63FA80b5DDFd3Cab23803fdB93ad2c18F3d5aa/swap?view=pt&chain=ethereum
        _pendleStrategy.addPT(
            0x9A63FA80b5DDFd3Cab23803fdB93ad2c18F3d5aa,
            0x80ac24aA929eaF5013f6436cdA2a7ba190f5Cc0b,
            0x80ac24aA929eaF5013f6436cdA2a7ba190f5Cc0b,
            _tokenSwapper.USDC_USD_Feed(),
            1800,
            86400
        );
        // USDS https://app.pendle.finance/trade/markets/0xdacE1121e10500e9e29d071F01593fD76B000f08/swap?view=pt&chain=ethereum
        _pendleStrategy.addPT(0xdacE1121e10500e9e29d071F01593fD76B000f08, usds, USDS_USD_Feed, address(0), 900, 86400);
        // sUSDf https://app.pendle.finance/trade/markets/0x45F163E583D34b8E276445dd3Da9aE077D137d72/swap?view=pt&chain=ethereum
        _pendleStrategy.addPT(
            0x45F163E583D34b8E276445dd3Da9aE077D137d72,
            0xc8CF6D7991f15525488b2A83Df53468D682Ba4B0,
            0xc8CF6D7991f15525488b2A83Df53468D682Ba4B0,
            _tokenSwapper.USDf_USD_FEED(),
            1800,
            86400
        );
    }
}
