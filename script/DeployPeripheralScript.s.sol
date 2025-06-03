// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.29;

import "forge-std/Script.sol";
import {TimelockController} from "@openzeppelin/contracts/governance/TimelockController.sol";

//
// forge script DeployPeripheralScript.s.sol:DeployPeripheralScript --rpc-url $RPC --etherscan-api-key $TD_KEY --verify --verifier-url $VERIFY_URL --chain-id 1 -vvvv --broadcast --slow -- --num-of-optimizations 200
//
contract DeployPeripheralScript is Script {
    function run() external {
        // Get private key from environment
        uint256 privateKey = vm.envUint("TESTNET_PRIVATE_KEY");

        vm.startBroadcast(privateKey);

        // Contract creation
        address[] memory _proposers = new address[](1);
        _proposers[0] = vm.addr(privateKey);

        address[] memory _executors = new address[](1);
        _executors[0] = vm.addr(privateKey);

        uint256 _minDelaySeconds = 600;
        TimelockController timelocker = new TimelockController(_minDelaySeconds, _proposers, _executors, address(0));

        vm.stopBroadcast();
    }
}
