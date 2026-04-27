// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "forge-std/Script.sol";
import "../src/PaktolVault.sol";

/// @title Deploy
/// @notice Atomic deployment script for PaktolVault (AAVE v3 / Gnosis Chain).
///         Deploys the vault and immediately seeds dead shares in a single run
///         to prevent the ERC-4626 inflation attack window.
///
/// @dev Usage:
///      forge script script/Deploy.s.sol \
///        --rpc-url $RPC_URL \
///        --broadcast \
///        --verify \
///        -vvvv
///
///      Required env vars (set in .env):
///        DEPLOYER_PRIVATE_KEY  — deployer wallet (must hold MIN_DEPOSIT EURe)
///        ASSET                 — EURe token address (Monerium, Gnosis Chain)
///        OWNER                 — multisig address (receives ownership)
///        TREASURY              — treasury address
///        GUARDIAN              — guardian address
///        HARVESTER             — keeper bot address
///        AAVE_POOL             — AAVE v3 Pool address on Gnosis Chain
///        ATOKEN                — AAVE aEURe address on Gnosis Chain
///        CAP_BPS               — annual net yield cap (350 = Standard, 500 = Paktol)
///        FEE_BPS               — fixed fee on gross yield (50 = Standard, 0 = Paktol)
///        VAULT_NAME            — ERC20 name for shares
///        VAULT_SYMBOL          — ERC20 symbol for shares
contract Deploy is Script {
    function run() external {
        uint256 deployerKey = vm.envUint("DEPLOYER_PRIVATE_KEY");
        address deployer = vm.addr(deployerKey);

        address asset = vm.envAddress("ASSET");
        address owner = vm.envAddress("OWNER");
        address treasury = vm.envAddress("TREASURY");
        address guardian = vm.envAddress("GUARDIAN");
        address harvester = vm.envAddress("HARVESTER");
        address aavePool = vm.envAddress("AAVE_POOL");
        address aToken = vm.envAddress("ATOKEN");
        uint256 capBps = vm.envUint("CAP_BPS");
        uint256 feeBps = vm.envUint("FEE_BPS");
        string memory name = vm.envString("VAULT_NAME");
        string memory symbol = vm.envString("VAULT_SYMBOL");
        address signer = vm.envAddress("SIGNER");
        bool requiresAuth = vm.envBool("REQUIRES_AUTH");

        vm.startBroadcast(deployerKey);

        // ── Step 1: Deploy vault ──────────────────────────────────────────
        PaktolVault vault = new PaktolVault(
            IERC20(asset), name, symbol, owner,
            treasury, capBps, feeBps, guardian, harvester,
            aavePool, aToken, 0, signer, requiresAuth
        );

        console.log("PaktolVault deployed at:", address(vault));

        // ── Step 2: Seed dead shares ──────────────────────────────────────
        // Must happen before any real user deposit.
        // Locks MIN_DEPOSIT shares at the dead address, making inflation
        // attacks economically infeasible combined with _decimalsOffset=3.
        uint256 seedAmount = vault.MIN_DEPOSIT();

        IERC20(asset).approve(address(vault), seedAmount);
        vault.deposit(seedAmount, address(0x000000000000000000000000000000000000dEaD));

        console.log("Dead shares seeded. MIN_DEPOSIT:", seedAmount);
        console.log("lastTotalAssets:", vault.lastTotalAssets());

        vm.stopBroadcast();

        // ── Post-deploy verification ──────────────────────────────────────
        // AAVE rounds 1 wei on supply — allow tolerance of 1e9 (0.000000001 EURe).
        require(vault.lastTotalAssets() >= seedAmount - 1e9, "Seed failed");
        require(vault.totalSupply() > 0, "No shares minted");
        require(vault.owner() == owner, "Owner mismatch");
        require(vault.TREASURY() == treasury, "Treasury mismatch");
        require(vault.AAVE_POOL() == aavePool, "AavePool mismatch");
        require(vault.ATOKEN() == aToken, "AToken mismatch");

        console.log("Deployment verified. Vault ready.");

        // ── Ownership note ────────────────────────────────────────────────
        // If owner != deployer, multisig must call acceptOwnership() (Ownable2Step).
        if (owner != deployer) {
            console.log(
                "IMPORTANT: transferOwnership set in constructor. " "Multisig at", owner, "must call acceptOwnership()."
            );
        }
    }
}
