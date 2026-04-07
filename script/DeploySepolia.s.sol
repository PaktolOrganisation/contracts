// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "forge-std/Script.sol";
import "../src/PaktolVault.sol";
import "../test/mocks/MockAavePool.sol";

/// @title DeploySepolia
/// @notice Deploys MockAavePool + PaktolVault on Ethereum Sepolia for integration testing.
///         Uses real Monerium EURe sandbox token as the underlying asset.
///         MockAavePool replaces real AAVE v3 (not deployed on Sepolia).
///
/// @dev Usage:
///      forge script script/DeploySepolia.s.sol \
///        --rpc-url $SEPOLIA_RPC_URL \
///        --broadcast \
///        --verify \
///        -vvvv
///
///      Required env vars (set in .env.sepolia):
///        DEPLOYER_PRIVATE_KEY  — deployer wallet (must hold ETH Sepolia for gas)
///        ASSET                 — EURe Monerium sandbox on Sepolia
///        OWNER                 — address that will own the vault (your Privy wallet)
///        TREASURY              — receives fees + yield surplus
///        GUARDIAN              — can pause deposits
///        HARVESTER             — can call harvest()
///        CAP_BPS               — annual net yield cap (350 = Standard)
///        FEE_BPS               — AUM fee in bps (50 = Standard, 0 = Paktol)
///        VAULT_NAME            — ERC20 name for shares
///        VAULT_SYMBOL          — ERC20 symbol for shares
///
///      Seed step (separate — requires OWNER to hold MIN_DEPOSIT EURe):
///        forge script script/DeploySepolia.s.sol:Seed \
///          --rpc-url $SEPOLIA_RPC_URL \
///          --broadcast -vvvv
contract DeploySepolia is Script {
    function run() external {
        uint256 deployerKey = vm.envUint("DEPLOYER_PRIVATE_KEY");

        address asset     = vm.envAddress("ASSET");
        address owner     = vm.envAddress("OWNER");
        address treasury  = vm.envAddress("TREASURY");
        address guardian  = vm.envAddress("GUARDIAN");
        address harvester = vm.envAddress("HARVESTER");
        uint256 capBps    = vm.envUint("CAP_BPS");
        uint256 feeBps    = vm.envUint("FEE_BPS");
        string memory name   = vm.envString("VAULT_NAME");
        string memory symbol = vm.envString("VAULT_SYMBOL");
        address signer = vm.envAddress("SIGNER");
        bool requiresAuth = vm.envBool("REQUIRES_AUTH");

        vm.startBroadcast(deployerKey);

        // ── Step 1: Deploy MockAavePool ───────────────────────────────────
        // Replaces real AAVE v3 (not available on Sepolia).
        // supply() / withdraw() behaviour is identical from the vault's perspective.
        MockAavePool mockPool = new MockAavePool(asset);
        address aToken = address(mockPool.aToken());

        console.log("MockAavePool deployed at:", address(mockPool));
        console.log("MockAToken   deployed at:", aToken);

        // ── Step 2: Deploy PaktolVault ────────────────────────────────────
        PaktolVault vault = new PaktolVault(PaktolVault.VaultParams({
            asset:        IERC20(asset),
            name:         name,
            symbol:       symbol,
            owner:        owner,
            treasury:     treasury,
            capBps:       capBps,
            feeBps:       feeBps,
            guardian:     guardian,
            harvester:    harvester,
            aavePool:     address(mockPool),
            aToken:       aToken,
            signer:       signer,
            requiresAuth: requiresAuth
        }));

        console.log("PaktolVault  deployed at:", address(vault));
        console.log("Asset (EURe)            :", asset);
        console.log("Owner                   :", owner);
        console.log("CAP_BPS                 :", capBps);
        console.log("FEE_BPS                 :", feeBps);

        vm.stopBroadcast();

        // ── Post-deploy checks ────────────────────────────────────────────
        require(vault.owner() == owner,              "Owner mismatch");
        require(vault.TREASURY() == treasury,         "Treasury mismatch");
        require(vault.AAVE_POOL() == address(mockPool), "AavePool mismatch");
        require(vault.ATOKEN() == aToken,             "AToken mismatch");

        console.log("");
        console.log("=== DEPLOYMENT COMPLETE ===");
        console.log("Next step: seed dead shares.");
        console.log("Run: forge script script/DeploySepolia.s.sol:Seed");
        console.log("     with OWNER key + VAULT_ADDRESS env var.");
        if (owner != vm.addr(deployerKey)) {
            console.log("IMPORTANT: owner != deployer - call acceptOwnership() from:", owner);
        }
    }
}

/// @notice Seeds dead shares after deployment.
///         Must be run by OWNER who holds at least MIN_DEPOSIT EURe.
///         Prevents the ERC-4626 inflation attack window.
contract Seed is Script {
    function run() external {
        uint256 ownerKey   = vm.envUint("OWNER_PRIVATE_KEY");
        address vaultAddr  = vm.envAddress("VAULT_ADDRESS");

        PaktolVault vault = PaktolVault(vaultAddr);
        uint256 seedAmount = vault.MIN_DEPOSIT();
        address asset = vault.asset();

        vm.startBroadcast(ownerKey);

        IERC20(asset).approve(vaultAddr, seedAmount);
        vault.deposit(seedAmount, address(0x000000000000000000000000000000000000dEaD));

        vm.stopBroadcast();

        require(vault.totalSupply() > 0, "Seed failed: no shares minted");
        console.log("Dead shares seeded. Vault ready.");
        console.log("lastTotalAssets:", vault.lastTotalAssets());
    }
}
