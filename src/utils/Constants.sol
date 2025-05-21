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
     * @dev used as dummy dead address.
     */
    address constant ZRO_ADDR = address(0);

    function convertDecimalToUnit(uint256 decimal) public view returns (uint256) {
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
}
