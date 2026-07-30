// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "forge-std/Script.sol";
import "../src/PaktolVaultV2.sol";

/// @dev Deploy PaktolVaultV2 on Ethereum Mainnet against a Byzantine EUR vault.
///
///      Required env vars:
///        DEPLOYER_PRIVATE_KEY   hex private key of the deployer
///        OWNER                  multisig / EOA that will own the vault
///        TREASURY               address that receives fee shares
///        GUARDIAN               address allowed to pause
///        HARVESTER              address allowed to call harvest()
///        CAP_BPS                yield cap in bps (e.g. 500 = 5%)
///        FEE_BPS                performance fee in bps (e.g. 50 = 0.5%)
///        VAULT_NAME             ERC-20 name  (e.g. "Paktol Standard EURC")
///        VAULT_SYMBOL           ERC-20 symbol (e.g. "pkEURC-S")
///        BYZANTINE_VAULT_ADDR   which Byzantine vault to use (see constants below)
///      Optional:
///        MAX_TVL                max TVL in EURC raw units (0 = unlimited)
///        REQUIRES_AUTH          true if vault requires grantPremiumAccess (default false)
///
///      Byzantine vault options (Ethereum Mainnet):
///        PROD standard: 0x2F99e35Ea811F3cC230B26dfF817604B5D4B6e38
///        PROD insured:  0xed7603df0d6d7387d42d05fac92cb42c4a275744
///
///      IMPORTANT: after deploy, ask Byzantine to whitelist your vault address on their
///      Ethereum gates (sendAssetsGate + receiveSharesGate — separate whitelist from Base).
///      Without whitelist, _depositToByzantine() will revert on every deposit.
///      Deployment and config wiring do NOT require whitelist — only the actual deposit
///      into Byzantine does. Verify wiring first (see test/PaktolVaultV2ForkEthereum.t.sol),
///      THEN request whitelist for this deployed address before going live.

// ── Immutable addresses on Ethereum Mainnet ──────────────────────────────────
address constant EURC_ETHEREUM = 0x1aBaEA1f7C830bD89Acc67eC4af516284b1bC33c;

// Byzantine EUR vault addresses — pick one via BYZANTINE_VAULT_ADDR env var
address constant BYZ_STANDARD = 0x2F99e35Ea811F3cC230B26dfF817604B5D4B6e38; // prod
address constant BYZ_INSURED  = 0xeD7603DF0d6D7387d42D05fAC92CB42C4a275744; // prod (insured)

contract DeployEthereumV2 is Script {
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
        bool    requiresAuth     = vm.envOr("REQUIRES_AUTH", false);

        string memory name   = vm.envString("VAULT_NAME");
        string memory symbol = vm.envString("VAULT_SYMBOL");

        address byzantineVault = vm.envAddress("BYZANTINE_VAULT_ADDR");

        // Sanity check: Byzantine vault must expose EURC as asset.
        require(
            IERC4626(byzantineVault).asset() == EURC_ETHEREUM,
            "Byzantine vault asset mismatch - wrong address?"
        );

        address deployer = vm.addr(deployerKey);

        vm.startBroadcast(deployerKey);

        // Deploy with deployer as initial owner so it can seed dead shares.
        // Ownership is transferred to the multisig right after.
        PaktolVaultV2 vault = new PaktolVaultV2(
            IERC20(EURC_ETHEREUM),
            name,
            symbol,
            deployer,
            treasury,
            capBps,
            feeBps,
            guardian,
            harvester,
            granter,
            byzantineVault,
            maxTvl,
            requiresAuth
        );

        // Initiate 2-step ownership transfer to the real owner (multisig).
        vault.transferOwnership(owner);

        vm.stopBroadcast();

        console.log("=== DEPLOYMENT COMPLETE ===");
        console.log("PaktolVaultV2  :", address(vault));
        console.log("EURC           :", EURC_ETHEREUM);
        console.log("Byzantine vault:", byzantineVault);
        console.log("Owner          :", owner);
        console.log("CAP_BPS        :", capBps);
        console.log("FEE_BPS        :", feeBps);
        console.log("REQUIRES_AUTH  :", requiresAuth);

        // Post-deploy invariant checks.
        require(vault.owner()           == deployer,                     "owner mismatch");
        require(vault.pendingOwner()    == owner,                        "pendingOwner mismatch");
        require(vault.TREASURY()        == treasury,                     "treasury mismatch");
        require(address(vault.asset())  == EURC_ETHEREUM,                "asset mismatch");
        require(vault.BYZANTINE_VAULT() == IERC4626(byzantineVault),     "byzantine mismatch");

        console.log("");
        console.log("IMPORTANT: Call acceptOwnership() from:", owner);

        console.log("");
        console.log("IMPORTANT: this address is NOT yet whitelisted on Byzantine's Ethereum");
        console.log("gates. Deposits will revert until Byzantine adds it to their whitelist.");
        console.log("Verify wiring first (fork test), THEN send them this address:", address(vault));

        console.log("");
        console.log("Next step (once whitelisted): seed dead shares.");
        console.log("Run: forge script script/DeployEthereumV2.s.sol:SeedV2Ethereum --broadcast --rpc-url mainnet");
        console.log("     with VAULT_ADDRESS=", address(vault));
    }
}

/// @dev Seed 1 MIN_DEPOSIT worth of shares to address(0xdEaD) to prevent inflation attacks.
///      Must be run by the owner (who holds EURC and approved the vault), AFTER whitelist
///      is granted — this call triggers a real deposit into Byzantine.
contract SeedV2Ethereum is Script {
    function run() external {
        uint256 ownerKey  = vm.envUint("OWNER_PRIVATE_KEY");
        address vaultAddr = vm.envAddress("VAULT_ADDRESS");

        PaktolVaultV2 vault = PaktolVaultV2(vaultAddr);
        uint256 seedAmount  = vault.minDeposit();
        address asset       = vault.asset();

        address seeder = vm.addr(ownerKey);
        console.log("Seeding", seedAmount, "EURC (raw) into vault...");

        vm.startBroadcast(ownerKey);
        // Si REQUIRES_AUTH, le receiver (0xdEaD) doit être granted avant le seed.
        if (vault.REQUIRES_AUTH()) {
            vault.grantPremiumAccess(address(0xdEaD), 1 days);
        }
        IERC20(asset).approve(vaultAddr, seedAmount);
        vault.deposit(seedAmount, address(0xdEaD));
        vm.stopBroadcast();

        require(vault.totalSupply() > 0, "Seed failed");
        console.log("Dead shares seeded. lastTotalAssets:", vault.lastTotalAssets());
        console.log("Vault is ready for deposits.");
    }
}
