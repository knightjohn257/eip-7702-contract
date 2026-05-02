// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "forge-std/Script.sol";
import "src/BatchCallAndSponsor.sol";
import "src/MockERC20.sol";

contract DeployScript is Script {
    function run() external {
        uint256 deployerPrivateKey = vm.envUint("PRIVATE_KEY");
        vm.startBroadcast(deployerPrivateKey);

        BatchCallAndSponsor impl = new BatchCallAndSponsor();
        MockERC20 token = new MockERC20(18);

        console2.log("Implementation deployed at:", address(impl));
        console2.log("MockERC20 deployed at:", address(token));

        vm.stopBroadcast();
    }
}
