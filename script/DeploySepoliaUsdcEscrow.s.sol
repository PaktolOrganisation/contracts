// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "forge-std/Script.sol";
import "../src/SepoliaUsdcEscrow.sol";

/// forge script script/DeploySepoliaUsdcEscrow.s.sol --rpc-url $SEPOLIA_RPC_URL --broadcast -vvvv
contract DeploySepoliaUsdcEscrow is Script {
    function run() external {
        uint256 key = vm.envUint("DEPLOYER_PRIVATE_KEY");
        vm.startBroadcast(key);
        SepoliaUsdcEscrow escrow = new SepoliaUsdcEscrow();
        console2.log("SepoliaUsdcEscrow", address(escrow));
        vm.stopBroadcast();
    }
}
