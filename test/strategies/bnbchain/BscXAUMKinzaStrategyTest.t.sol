// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.29;

import {Test, console} from "forge-std/Test.sol";
import {SparkleXVault} from "../../../src/SparkleXVault.sol";
import {CollYieldAAVEStrategy} from "../../../src/strategies/aave/CollYieldAAVEStrategy.sol";
import {AAVEHelper} from "../../../src/strategies/aave/AAVEHelper.sol";
import {TokenSwapper} from "../../../src/utils/TokenSwapper.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {Vm} from "forge-std/Vm.sol";
import {IPool} from "../../../interfaces/aave/IPool.sol";
import {IAaveOracle} from "../../../interfaces/aave/IAaveOracle.sol";
import {IPriceOracleGetter} from "../../../interfaces/aave/IPriceOracleGetter.sol";
import {TestUtils} from "../../TestUtils.sol";
import {Constants} from "../../../src/utils/Constants.sol";
import {DummyDEXRouter} from "../../mock/DummyDEXRouter.sol";

// run this test with mainnet fork
// forge test --fork-url <rpc_url> --match-path BscXAUMKinzaStrategyTest -vvv
contract BscXAUMKinzaStrategyTest is TestUtils {
    SparkleXVault public stkVault;
    SparkleXVault public spUSDVault;
    CollYieldAAVEStrategy public myStrategy;
    TokenSwapper public swapper;
    AAVEHelper public aaveHelper;
    address public stkVOwner;
    address public strategist;
    address public aaveHelperOwner;
    address public strategyOwner;
    DummyDEXRouter public mockRouter;

    address XAUM = 0x23AE4fd8E7844cdBc97775496eBd0E8248656028;
    IAaveOracle aaveOracle = IAaveOracle(0xec203E7676C45455BF8cb43D28F9556F014Ab461);
    IPool aavePool = IPool(0xcB0620b181140e57D1C0D8b724cde623cA963c8C);
    ERC20 kXAUM = ERC20(0xC390614e71512B2Aa9D91AfA7E183cb00EB92518);
    address USDC_BNB = 0x8AC76a51cc950d9822D68b83fE1Ad97B32Cd580d;
    address USDC_USD_Feed_BNB = 0x51597f405303C4377E36123cBc172b13269EA163;
    address XAUM_Whale = 0xD5D2cAbE2ab21D531e5f96f1AeeF26D79f4b6583;
    uint256 public xaumPerBNB = 25e16; // 1 BNB worth one quarter of 1 XAUM

    // events to check

    function setUp() public {
        _createForkBNBChain(uint256(vm.envInt("TESTNET_FORK_BSC_HEIGHT")));

        wETH = payable(0xbb4CdB9CBd36B01bD1cBaEBF2De08d9173bc095c);

        swapper = new TokenSwapper();
        mockRouter = new DummyDEXRouter();

        stkVault = new SparkleXVault(ERC20(XAUM), "Sparkle XAU Vault", "spXAU");
        spUSDVault = new SparkleXVault(ERC20(USDC_BNB), "Sparkle USD Vault", "spUSD");
        stkVOwner = stkVault.owner();
        _changeWithdrawFee(stkVOwner, address(stkVault), 0);
        _changeWithdrawFee(stkVOwner, address(spUSDVault), 0);

        myStrategy = new CollYieldAAVEStrategy(address(stkVault), USDC_USD_Feed_BNB, address(spUSDVault), 901);
        strategist = myStrategy.strategist();
        assertEq(address(stkVault), myStrategy.vault());
        assertEq(stkVault.asset(), myStrategy.asset());
        strategyOwner = myStrategy.owner();

        aaveHelper = new AAVEHelper(address(myStrategy), ERC20(XAUM), ERC20(USDC_BNB), kXAUM, 0);
        aaveHelperOwner = aaveHelper.owner();

        vm.startPrank(stkVOwner);
        stkVault.addStrategy(address(myStrategy), MAX_ETH_ALLOWED);
        vm.stopPrank();

        vm.startPrank(strategyOwner);
        myStrategy.setSwapper(address(swapper));
        myStrategy.setAAVEHelper(address(aaveHelper));
        vm.stopPrank();
    }

    function test_XAUM_GetMaxLTV() public {
        uint256 _ltv = aaveHelper.getMaxLTV();
        // https://app.kinza.finance/#/details/XAUM
        assertEq(_ltv, 8000);
    }

    function test_XAUM_Invest_Redeem_Repay(uint256 _testVal) public {
        _prepareSwapForMockRouter(mockRouter, wETH, XAUM, XAUM_Whale, xaumPerBNB);
        _fundFirstDepositGenerouslyWithERC20(mockRouter, address(stkVault), xaumPerBNB);
        address _user = TestUtils._getSugarUser();

        (uint256 _deposited, uint256 _share) = TestUtils._makeVaultDepositWithMockRouter(
            mockRouter, address(stkVault), _user, xaumPerBNB, _testVal, 4 ether, 20 ether
        );
    }
}
