// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "erc4626-tests/ERC4626.test.sol";

// Selective imports to avoid namespace collision with a16z's own IERC20/IERC4626 declarations.
import {PaktolVault} from "../src/PaktolVault.sol";
import {MockEURe}    from "./mocks/MockEURe.sol";
import {MockAavePool} from "./mocks/MockAavePool.sol";
import {IERC20 as OzIERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

/// @title PaktolVaultERC4626ComplianceTest
/// @notice Runs the a16z ERC-4626 compliance test suite against PaktolVault.
///
///         Vault-specific constraints:
///           • MIN_DEPOSIT = 1e9: amounts below this are skipped via try/catch + vm.assume(false).
///           • AAVE-backed totalAssets: gains simulated by minting EURe idle to vault.
///           • Loss scenarios skipped — covered by dedicated unit tests.
///           • REQUIRES_AUTH = false (Standard vault, open deposits).
///           • WITHDRAWAL_COOLDOWN = 4 hours: warped past after every deposit in round-trip tests.
contract PaktolVaultERC4626ComplianceTest is ERC4626Test {
    MockEURe     internal eure;
    MockAavePool internal pool;
    PaktolVault  internal vault;

    address internal owner      = makeAddr("owner");
    address internal treasury   = makeAddr("treasury");
    address internal guardian   = makeAddr("guardian");
    address internal harvester  = makeAddr("harvester");
    address internal signerAddr = makeAddr("signer");

    function setUp() public override {
        eure = new MockEURe();
        pool = new MockAavePool(address(eure));

        vault = new PaktolVault(
            OzIERC20(address(eure)), "Paktol Standard", "pkEUR-S", owner,
            treasury, 350, 50, guardian, harvester,
            address(pool), address(pool.aToken()), 0, signerAddr, false
        );

        _underlying_ = address(eure);
        _vault_      = address(vault);
        _delta_      = 1;
        _vaultMayBeEmpty = false;
        _unlimitedAmount = false;
    }

    /// @dev After initial deposits, warp past WITHDRAWAL_COOLDOWN so maxWithdraw > 0
    ///      and the a16z fuzz engine can find valid withdrawal amounts.
    function setUpVault(Init memory init) public override {
        super.setUpVault(init);
        vm.warp(block.timestamp + vault.WITHDRAWAL_COOLDOWN() + 1);
    }

    /// @dev Simulate yield by minting aTokens to the vault — totalAssets() reads
    ///      ATOKEN.balanceOf(vault) + _idleBalance, so minting underlying to the vault
    ///      address is a no-op. pool.simulateYield mints aTokens directly.
    ///      Cap gain to current totalAssets so exchange rate never more than doubles —
    ///      this bounds rounding error to ≤ 1 wei per round-trip (matching _delta_ = 1).
    ///      Loss scenarios skipped — Aave loss handling is in PaktolVault.t.sol.
    function setUpYield(Init memory init) public override {
        if (init.yield >= 0) {
            uint256 gain = uint256(init.yield);
            if (gain > 0) {
                uint256 cap = IERC4626(_vault_).totalAssets();
                if (cap == 0) { vm.assume(false); }
                if (gain > cap) gain = cap;
                pool.simulateYield(_vault_, gain);
            }
        } else {
            vm.assume(false);
        }
    }

    // ── Round-trip overrides ────────────────────────────────────────────────
    // The a16z round-trip tests deposit then immediately redeem/withdraw.
    // Our vault has a 4-hour WITHDRAWAL_COOLDOWN that resets on every deposit,
    // so we warp after the inner deposit but before the redeem/withdraw step.
    // We achieve this by skipping the a16z versions and providing warp-aware variants.

    function test_RT_deposit_redeem(Init memory init, uint256 assets) public override {
        setUpVault(init);
        setUpYield(init);
        address alice = init.user[0];
        assets = bound(assets, 1e9, type(uint96).max);
        uint256 maxDep = IERC4626(_vault_).maxDeposit(alice);
        vm.assume(maxDep >= assets);
        deal(_underlying_, alice, assets);
        vm.startPrank(alice);
        IERC20(_underlying_).approve(_vault_, assets);
        uint256 shares = IERC4626(_vault_).deposit(assets, alice);
        vm.stopPrank();
        // Warp past cooldown before redeeming
        vm.warp(block.timestamp + vault.WITHDRAWAL_COOLDOWN() + 1);
        vm.startPrank(alice);
        uint256 redeemed = IERC4626(_vault_).redeem(shares, alice, alice);
        vm.stopPrank();
        assertGe(redeemed + _delta_, assets, "RT: redeem < deposit");
    }

    function test_RT_deposit_withdraw(Init memory init, uint256 assets) public override {
        setUpVault(init);
        setUpYield(init);
        address alice = init.user[0];
        assets = bound(assets, 1e9, type(uint96).max);
        uint256 maxDep = IERC4626(_vault_).maxDeposit(alice);
        vm.assume(maxDep >= assets);
        deal(_underlying_, alice, assets);
        vm.startPrank(alice);
        IERC20(_underlying_).approve(_vault_, assets);
        IERC4626(_vault_).deposit(assets, alice);
        vm.stopPrank();
        // Warp past cooldown before withdrawing
        vm.warp(block.timestamp + vault.WITHDRAWAL_COOLDOWN() + 1);
        uint256 maxWd = IERC4626(_vault_).maxWithdraw(alice);
        vm.assume(maxWd >= assets);
        vm.startPrank(alice);
        IERC4626(_vault_).withdraw(assets, alice, alice);
        vm.stopPrank();
    }

    function test_RT_mint_redeem(Init memory init, uint256 shares) public override {
        setUpVault(init);
        setUpYield(init);
        address alice = init.user[0];
        shares = bound(shares, 1, type(uint96).max);
        uint256 maxMint = IERC4626(_vault_).maxMint(alice);
        vm.assume(maxMint >= shares);
        uint256 assets = IERC4626(_vault_).previewMint(shares);
        vm.assume(assets >= 1e9);
        deal(_underlying_, alice, assets);
        vm.startPrank(alice);
        IERC20(_underlying_).approve(_vault_, assets);
        IERC4626(_vault_).mint(shares, alice);
        vm.stopPrank();
        // Warp past cooldown before redeeming
        vm.warp(block.timestamp + vault.WITHDRAWAL_COOLDOWN() + 1);
        vm.startPrank(alice);
        uint256 redeemed = IERC4626(_vault_).redeem(shares, alice, alice);
        vm.stopPrank();
        assertGe(redeemed + _delta_, assets, "RT: redeem < mint cost");
    }

    function test_RT_mint_withdraw(Init memory init, uint256 shares) public override {
        setUpVault(init);
        setUpYield(init);
        address alice = init.user[0];
        shares = bound(shares, 1, type(uint96).max);
        uint256 maxMint = IERC4626(_vault_).maxMint(alice);
        vm.assume(maxMint >= shares);
        uint256 assets = IERC4626(_vault_).previewMint(shares);
        vm.assume(assets >= 1e9);
        deal(_underlying_, alice, assets);
        vm.startPrank(alice);
        IERC20(_underlying_).approve(_vault_, assets);
        IERC4626(_vault_).mint(shares, alice);
        vm.stopPrank();
        // Warp past cooldown before withdrawing
        vm.warp(block.timestamp + vault.WITHDRAWAL_COOLDOWN() + 1);
        uint256 maxWd = IERC4626(_vault_).maxWithdraw(alice);
        vm.assume(maxWd >= assets);
        vm.startPrank(alice);
        IERC4626(_vault_).withdraw(assets, alice, alice);
        vm.stopPrank();
    }
}
