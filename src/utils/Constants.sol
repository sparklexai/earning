// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.29;

library Constants {
    /**
     * @dev used as base unit for most ERC20 token.
     */
    uint256 constant ONE_ETHER = 1e18;

    /**
     * @dev used as base unit for GWEI.
     */
    uint256 constant ONE_GWEI = 1e9;

    /**
     * @dev used as ratio denominator.
     */
    uint256 constant TOTAL_BPS = 10000;

    /**
     * @dev used as denominator for annual calculation.
     */
    uint256 constant ONE_YEAR = 365 days;

    /**
     * @dev used as dummy dead address.
     */
    address constant ZRO_ADDR = address(0);

    function convertDecimalToUnit(uint256 decimal) public pure returns (uint256) {
        if (decimal == 18) {
            return ONE_ETHER;
        } else if (decimal == 9) {
            return ONE_GWEI;
        } else if (decimal > 0) {
            return 10 ** decimal;
        } else {
            return 0;
        }
    }

    // errors in vault & common to strategies
    error STRATEGY_COLLECTION_IN_PROCESS();
    error SWAP_OUT_TOO_SMALL();
    error INVALID_BPS_TO_SET();
    error WRONG_STRATEGY_TO_ADD();
    error WRONG_STRATEGY_TO_REMOVE();
    error WRONG_STRATEGY_ALLOC_UPDATE();
    error ZERO_SHARE_TO_MINT();
    error TOO_SMALL_FIRST_SHARE();
    error WRONG_PRICE_FROM_ORACLE();
    error INVALID_ADDRESS_TO_SET();
    error ONLY_FOR_CLAIMER();
    error ONLY_FOR_CLAIMER_OR_OWNER();
    error ONLY_FOR_STRATEGIST();
    error ONLY_FOR_STRATEGIST_OR_VAULT();
    error ZERO_ASSET_TO_USER();
    error USER_REDEMPTION_NOT_CLAIMED();
    error LESS_REDEMPTION_TO_USER();
    error WRONG_SWAP_RECEIVER();
    error ONLY_FOR_STRATEGIST_OR_OWNER();
    error TOO_MANY_STRATEGIES();
    error INVALID_HELPER_CALLER();
    error ONLY_FOR_PAUSE_COMMANDER();
    error VAULT_ALREADY_PAUSED();
    error INVALID_TOKEN_INDEX_IN_CURVE();
    error ONLY_FOR_WHITELISTED_CALLER();

    // errors in AAVE related strategy
    error FAIL_TO_REPAY_FLASHLOAN_LEVERAGE();
    error FAIL_TO_REPAY_FLASHLOAN_DELEVERAGE();
    error WRONG_AAVE_FLASHLOAN_CALLER();
    error WRONG_AAVE_FLASHLOAN_INITIATOR();
    error WRONG_AAVE_FLASHLOAN_ASSET();
    error WRONG_AAVE_FLASHLOAN_PREMIUM();
    error WRONG_AAVE_FLASHLOAN_AMOUNT();
    error ZERO_SUPPLY_FOR_AAVE_LEVERAGE();
    error FAIL_TO_SAFE_LEVERAGE();
    error TOO_MUCH_SUPPLY_TO_REDEEM();
    error TOO_MUCH_TO_BORROW();
    error DIFFERENT_TOKEN_IN_AAVE_HELPER();
    error POSITION_STILL_IN_USE();
    error ONLY_FOR_STRATEGIST_OR_OWNER_OR_FL();

    // errors in EtherFi related strategy
    error TOO_MANY_WITHDRAW_FOR_ETHERFI();

    // errors in Pendle related strategy
    error INVALID_MARKET_TO_ADD();
    error PT_NOT_FOUND();
    error PT_ALREADY_EXISTS();
    error PT_NOT_MATURED();
    error PT_ALREADY_MATURED();
    error INVALID_SWAP_CALLDATA();
    error MAX_PT_EXCEEDED();
    error PT_STILL_IN_USE();
    error ZERO_TO_SWAP_IN_PENDLE();
    error PT_NOT_MATCH_MARKET();
}
