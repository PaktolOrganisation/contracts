// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "forge-std/Script.sol";
import "../src/PaktolVaultV2.sol";
import "../test/mocks/MockEURC.sol";
import "../test/mocks/MockByzantineVault.sol";

contract DeploySepoliaV2 is Script {
    function run() external {
        uint256 deployerKey = vm.envUint("DEPLOYER_PRIVATE_KEY");

        address owner     = vm.envAddress("OWNER");
        address treasury  = vm.envAddress("TREASURY");
        address guardian  = vm.envAddress("GUARDIAN");
        address harvester = vm.envAddress("HARVESTER");
        address granter   = vm.envOr("GRANTER", address(0));
        uint256 capBps           = vm.envUint("CAP_BPS");
        uint256 feeBps           = vm.envUint("FEE_BPS");
        uint256 maxTvl           = vm.envOr("MAX_TVL", uint256(0));
        bool requiresAuth        = vm.envOr("REQUIRES_AUTH", false);
        string memory name   = vm.envString("VAULT_NAME");
        string memory symbol = vm.envString("VAULT_SYMBOL");

        vm.startBroadcast(deployerKey);

        MockEURC eurc = new MockEURC();
        MockByzantineVault byzantineVault = new MockByzantineVault(IERC20(address(eurc)));

        console.log("MockEURC          deployed at:", address(eurc));
        console.log("MockByzantineVault deployed at:", address(byzantineVault));

        PaktolVaultV2 vault = new PaktolVaultV2(
            IERC20(address(eurc)),
            name,
            symbol,
            owner,
            treasury,
            capBps,
            feeBps,
            guardian,
            harvester,
            granter,
            address(byzantineVault),
            maxTvl,
            requiresAuth
        );

        console.log("PaktolVaultV2     deployed at:", address(vault));
        console.log("Owner                        :", owner);
        console.log("CAP_BPS                      :", capBps);
        console.log("FEE_BPS                      :", feeBps);
        console.log("REQUIRES_AUTH                :", requiresAuth);

        vm.stopBroadcast();

        require(vault.owner()          == owner,                  "Owner mismatch");
        require(vault.TREASURY()       == treasury,               "Treasury mismatch");
        require(vault.BYZANTINE_VAULT() == IERC4626(address(byzantineVault)), "ByzantineVault mismatch");

        console.log("");
        console.log("=== DEPLOYMENT COMPLETE ===");
        console.log("Next: seed dead shares via SeedV2 contract.");
        if (owner != vm.addr(deployerKey)) {
            console.log("IMPORTANT: owner != deployer - call acceptOwnership() from:", owner);
        }
    }
}

contract SeedV2 is Script {
    function run() external {
        uint256 ownerKey  = vm.envUint("OWNER_PRIVATE_KEY");
        address vaultAddr = vm.envAddress("VAULT_ADDRESS");

        PaktolVaultV2 vault = PaktolVaultV2(vaultAddr);
        uint256 seedAmount  = vault.minDeposit();
        address asset       = vault.asset();

        vm.startBroadcast(ownerKey);

        IERC20(asset).approve(vaultAddr, seedAmount);
        vault.deposit(seedAmount, address(0xdEaD));

        vm.stopBroadcast();

        require(vault.totalSupply() > 0, "Seed failed: no shares minted");
        console.log("Dead shares seeded. Vault ready.");
        console.log("lastTotalAssets:", vault.lastTotalAssets());
    }
}
