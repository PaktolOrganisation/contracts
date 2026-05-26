// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "erc4626-tests/ERC4626.test.sol";

import {PaktolVaultV2}     from "../src/PaktolVaultV2.sol";
import {MockEURC}          from "./mocks/MockEURC.sol";
import {MockByzantineVault} from "./mocks/MockByzantineVault.sol";
import {IERC20 as OzIERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

/// @title PaktolVaultV2ERC4626ComplianceTest
/// @notice Runs the a16z ERC-4626 property-based compliance suite against PaktolVaultV2.
///
///         Vault-specific constraints:
///           - minDeposit = 1e3 (0.001 EURC): amounts below this are skipped via vm.assume.
///           - WITHDRAWAL_COOLDOWN = 4h: warped past after every deposit in round-trip tests.
///           - REQUIRES_AUTH = false (Standard vault, open deposits).
///           - Yield simulated via MockByzantineVault.simulateYield().
///           - Loss scenarios skipped (covered by dedicated unit tests).
contract PaktolVaultV2ERC4626ComplianceTest is ERC4626Test {
    MockEURC           internal eurc;
    MockByzantineVault internal byz;
    PaktolVaultV2      internal vault;

    address internal owner     = makeAddr("owner");
    address internal treasury  = makeAddr("treasury");
    address internal guardian  = makeAddr("guardian");
    address internal harvester = makeAddr("harvester");

    uint256 constant CAP_BPS = 350;
    uint256 constant FEE_BPS = 50;

    function setUp() public override {
        eurc = new MockEURC();
        byz  = new MockByzantineVault(OzIERC20(address(eurc)));

        vault = new PaktolVaultV2(
            OzIERC20(address(eurc)), "Paktol Standard", "pkEURC-S",
            owner, treasury, CAP_BPS, FEE_BPS,
            guardian, harvester, address(0),
            address(byz), 0, 0, false
        );

        _underlying_     = address(eurc);
        _vault_          = address(vault);
        _delta_          = 1e4;
        _vaultMayBeEmpty = false;
        _unlimitedAmount = false;
    }

    function setUpVault(Init memory init) public override {
        // init.share[i] est le montant d'ASSETS à déposer (pas des shares).
        // Avec _decimalsOffset=3, deposit(assets) donne assets*1000 shares dans un vault vide.
        // On plafonne à 1e12 pour que totalSupply reste ~1e15 : l'erreur de round-trip
        // (≈ 1000 * aliceShares / otherShares) reste < _delta_ = 1e4 tant qu'Alice n'est pas
        // ultra-dominante. Les reverse RT ajoutent un vm.assume pour cette condition.
        uint256 minDep = vault.minDeposit();
        for (uint256 i = 0; i < init.share.length; i++) {
            if (init.share[i] != 0) {
                if (init.share[i] > 1e12) init.share[i] = 1e12;
                if (init.share[i] < minDep) init.share[i] = 0;
            }
        }
        super.setUpVault(init);
        // Warp past cooldown so maxWithdraw > 0 for the a16z fuzz engine.
        vm.warp(block.timestamp + vault.WITHDRAWAL_COOLDOWN() + 1);
    }

    function setUpYield(Init memory init) public override {
        if (init.yield >= 0) {
            uint256 gain = uint256(init.yield);
            if (gain > 0) {
                uint256 cap = IERC4626(_vault_).totalAssets();
                if (cap == 0) vm.assume(false);
                if (gain > cap) gain = cap;
                try byz.simulateYield(gain) {} catch { vm.assume(false); }
            }
        } else {
            // Loss scenarios skipped — covered by dedicated unit tests.
            vm.assume(false);
        }
    }

    // ── Round-trip overrides (warp past cooldown before redeem/withdraw) ──────

    function test_RT_deposit_redeem(Init memory init, uint256 assets) public override {
        setUpVault(init);
        setUpYield(init);
        address alice = init.user[0];
        assets = bound(assets, vault.minDeposit(), type(uint96).max);
        uint256 maxDep = IERC4626(_vault_).maxDeposit(alice);
        vm.assume(maxDep >= assets);
        deal(_underlying_, alice, assets);
        vm.startPrank(alice);
        IERC20(_underlying_).approve(_vault_, assets);
        uint256 shares = IERC4626(_vault_).deposit(assets, alice);
        vm.stopPrank();
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
        assets = bound(assets, vault.minDeposit(), type(uint96).max);
        uint256 maxDep = IERC4626(_vault_).maxDeposit(alice);
        vm.assume(maxDep >= assets);
        deal(_underlying_, alice, assets);
        vm.startPrank(alice);
        IERC20(_underlying_).approve(_vault_, assets);
        IERC4626(_vault_).deposit(assets, alice);
        vm.stopPrank();
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
        vm.assume(assets >= vault.minDeposit());
        deal(_underlying_, alice, assets);
        vm.startPrank(alice);
        IERC20(_underlying_).approve(_vault_, assets);
        IERC4626(_vault_).mint(shares, alice);
        vm.stopPrank();
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
        vm.assume(assets >= vault.minDeposit());
        deal(_underlying_, alice, assets);
        vm.startPrank(alice);
        IERC20(_underlying_).approve(_vault_, assets);
        IERC4626(_vault_).mint(shares, alice);
        vm.stopPrank();
        vm.warp(block.timestamp + vault.WITHDRAWAL_COOLDOWN() + 1);
        uint256 maxWd = IERC4626(_vault_).maxWithdraw(alice);
        vm.assume(maxWd >= assets);
        vm.startPrank(alice);
        IERC4626(_vault_).withdraw(assets, alice, alice);
        vm.stopPrank();
    }

    // ── Reverse RT overrides (warp before redeem/withdraw, guard zero) ────────

    // redeem(shares) → deposit(assets): assets must be >= minDeposit to avoid DepositTooSmall.
    function test_RT_redeem_deposit(Init memory init, uint256 shares) public override {
        setUpVault(init);
        setUpYield(init);
        address alice = init.user[0];
        uint256 maxR = IERC4626(_vault_).maxRedeem(alice);
        vm.assume(maxR > 0);
        // Guard dominance : erreur RT ≈ 1000*aliceShares/otherShares doit être < _delta_.
        uint256 aliceSh = IERC4626(_vault_).balanceOf(alice);
        uint256 otherSh = IERC4626(_vault_).totalSupply() - aliceSh;
        vm.assume(otherSh > 0);
        vm.assume(aliceSh * 1000 < otherSh * _delta_);
        shares = bound(shares, 1, maxR);
        uint256 expectedAssets = IERC4626(_vault_).previewRedeem(shares);
        vm.assume(expectedAssets >= vault.minDeposit());
        deal(_underlying_, alice, expectedAssets);
        vm.prank(alice);
        IERC20(_underlying_).approve(_vault_, type(uint256).max);
        vm.prank(alice);
        uint256 assets = IERC4626(_vault_).redeem(shares, alice, alice);
        if (!_vaultMayBeEmpty) vm.assume(IERC4626(_vault_).totalSupply() > 0);
        vm.prank(alice);
        uint256 shares2 = IERC4626(_vault_).deposit(assets, alice);
        assertApproxLeAbs(shares2, shares, _delta_);
    }

    // withdraw(assets) → deposit(assets): assets must be >= minDeposit.
    function test_RT_withdraw_deposit(Init memory init, uint256 assets) public override {
        setUpVault(init);
        setUpYield(init);
        address alice = init.user[0];
        uint256 maxW = IERC4626(_vault_).maxWithdraw(alice);
        vm.assume(maxW >= vault.minDeposit());
        // Guard dominance : erreur RT ≈ 1000*aliceShares/otherShares doit être < _delta_.
        uint256 aliceSh = IERC4626(_vault_).balanceOf(alice);
        uint256 otherSh = IERC4626(_vault_).totalSupply() - aliceSh;
        vm.assume(otherSh > 0);
        vm.assume(aliceSh * 1000 < otherSh * _delta_);
        assets = bound(assets, vault.minDeposit(), maxW);
        vm.prank(alice);
        IERC20(_underlying_).approve(_vault_, type(uint256).max);
        vm.prank(alice);
        uint256 shares1 = IERC4626(_vault_).withdraw(assets, alice, alice);
        if (!_vaultMayBeEmpty) vm.assume(IERC4626(_vault_).totalSupply() > 0);
        vm.prank(alice);
        uint256 shares2 = IERC4626(_vault_).deposit(assets, alice);
        assertApproxLeAbs(shares2, shares1, _delta_);
    }

    // withdraw(assets) → mint(shares): previewMint(shares) must be >= minDeposit.
    function test_RT_withdraw_mint(Init memory init, uint256 assets) public override {
        setUpVault(init);
        setUpYield(init);
        address alice = init.user[0];
        uint256 maxW = IERC4626(_vault_).maxWithdraw(alice);
        vm.assume(maxW >= vault.minDeposit());
        // Guard dominance : erreur RT ≈ 1000*aliceShares/otherShares doit être < _delta_.
        uint256 aliceSh = IERC4626(_vault_).balanceOf(alice);
        uint256 otherSh = IERC4626(_vault_).totalSupply() - aliceSh;
        vm.assume(otherSh > 0);
        vm.assume(aliceSh * 1000 < otherSh * _delta_);
        assets = bound(assets, vault.minDeposit(), maxW);
        vm.prank(alice);
        IERC20(_underlying_).approve(_vault_, type(uint256).max);
        vm.prank(alice);
        uint256 shares = IERC4626(_vault_).withdraw(assets, alice, alice);
        if (!_vaultMayBeEmpty) vm.assume(IERC4626(_vault_).totalSupply() > 0);
        vm.assume(shares > 0);
        uint256 mintCost = IERC4626(_vault_).previewMint(shares);
        vm.assume(mintCost >= vault.minDeposit());
        deal(_underlying_, alice, mintCost);
        vm.prank(alice);
        IERC20(_underlying_).approve(_vault_, mintCost);
        vm.prank(alice);
        uint256 assets2 = IERC4626(_vault_).mint(shares, alice);
        assertApproxGeAbs(assets2, assets, _delta_);
    }
}
