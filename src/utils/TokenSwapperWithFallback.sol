// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.29;

import {TokenSwapper} from "./TokenSwapper.sol";

contract TokenSwapperWithFallback is TokenSwapper {
    ///////////////////////////////
    // member storage
    ///////////////////////////////

    ///////////////////////////////
    // events
    ///////////////////////////////
    event ReceiveETH(address indexed _msgSender, uint256 _msgValue);

    constructor() TokenSwapper() {}

    receive() external payable {
        emit ReceiveETH(msg.sender, msg.value);
    }
}
