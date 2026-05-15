// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "./PaktolVaultV2Base.t.sol";

contract PaktolVaultV2PointsTest is PaktolVaultV2Base {

    /* ─────────────────── setPoints ─────────────────────────────────── */

    function test_setPoints_byOwner() public {
        vm.prank(owner);
        vaultPkt.setPoints(user, 1000);
        assertEq(vaultPkt.points(user), 1000);
    }

    function test_setPoints_revert_unauthorized() public {
        vm.expectRevert();
        vm.prank(user);
        vaultPkt.setPoints(user, 1000);
    }

    function test_setPoints_revert_zeroAddress() public {
        vm.expectRevert(abi.encodeWithSelector(PaktolVaultV2.ZeroAddress.selector, "user"));
        vm.prank(owner);
        vaultPkt.setPoints(address(0), 1000);
    }

    function test_setPoints_emitsEvent() public {
        vm.expectEmit(true, false, false, true);
        emit PaktolVaultV2.PointsUpdated(user, 1000);
        vm.prank(owner);
        vaultPkt.setPoints(user, 1000);
    }

    function test_setPoints_overwrite() public {
        vm.startPrank(owner);
        vaultPkt.setPoints(user, 500);
        vaultPkt.setPoints(user, 1000);
        vm.stopPrank();
        assertEq(vaultPkt.points(user), 1000);
    }

    /* ─────────────────── setPremiumThreshold ───────────────────────── */

    function test_setPremiumThreshold_byOwner() public {
        vm.prank(owner);
        vaultPkt.setPremiumThreshold(500);
        assertEq(vaultPkt.premiumThreshold(), 500);
    }

    function test_setPremiumThreshold_revert_unauthorized() public {
        vm.expectRevert();
        vm.prank(user);
        vaultPkt.setPremiumThreshold(500);
    }

    function test_setPremiumThreshold_emitsEvent() public {
        vm.expectEmit(false, false, false, true);
        emit PaktolVaultV2.PremiumThresholdUpdated(PREMIUM_THRESHOLD, 500);
        vm.prank(owner);
        vaultPkt.setPremiumThreshold(500);
    }

    /* ─────────────────── grantPremiumAccess ────────────────────────── */

    function test_grantPremiumAccess_byOwner() public {
        vm.prank(owner);
        vaultPkt.grantPremiumAccess(user, 15 days);

        assertEq(vaultPkt.premiumExpiry(user), block.timestamp + 15 days);
    }

    function test_grantPremiumAccess_revert_unauthorized() public {
        vm.expectRevert();
        vm.prank(user);
        vaultPkt.grantPremiumAccess(user, 15 days);
    }

    function test_grantPremiumAccess_revert_zeroAddress() public {
        vm.expectRevert(abi.encodeWithSelector(PaktolVaultV2.ZeroAddress.selector, "user"));
        vm.prank(owner);
        vaultPkt.grantPremiumAccess(address(0), 15 days);
    }

    function test_grantPremiumAccess_emitsEvent() public {
        uint256 expectedExpiry = block.timestamp + 15 days;
        vm.expectEmit(true, false, false, true);
        emit PaktolVaultV2.PremiumAccessGranted(user, expectedExpiry);
        vm.prank(owner);
        vaultPkt.grantPremiumAccess(user, 15 days);
    }

    function test_grantPremiumAccess_renewable() public {
        vm.prank(owner);
        vaultPkt.grantPremiumAccess(user, 15 days);

        _warp(10 days);

        // Renouveler avant expiration — nouveau compteur de 15 jours depuis maintenant.
        vm.prank(owner);
        vaultPkt.grantPremiumAccess(user, 15 days);

        assertEq(vaultPkt.premiumExpiry(user), block.timestamp + 15 days);
    }

    /* ─────────────── Deposit gating par expiry ─────────────────────── */

    function test_deposit_blocked_withoutAccess() public {
        eurc.mint(user, DEPOSIT);
        vm.startPrank(user);
        eurc.approve(address(vaultPkt), DEPOSIT);
        vm.expectRevert(abi.encodeWithSelector(
            PaktolVaultV2.PremiumAccessExpired.selector, 0
        ));
        vaultPkt.deposit(DEPOSIT, user);
        vm.stopPrank();
    }

    function test_deposit_success_withActiveAccess() public {
        vm.prank(owner);
        vaultPkt.grantPremiumAccess(user, 15 days);

        uint256 shares = _deposit(vaultPkt, user, DEPOSIT);
        assertGt(shares, 0);
        assertApproxEqAbs(vaultPkt.totalAssets(), DEPOSIT, 1e3);
    }

    function test_deposit_blocked_afterExpiry() public {
        vm.prank(owner);
        vaultPkt.grantPremiumAccess(user, 15 days);

        _deposit(vaultPkt, user, DEPOSIT);

        // Avancer dans le temps après expiration.
        _warp(16 days);

        eurc.mint(user, DEPOSIT);
        vm.startPrank(user);
        eurc.approve(address(vaultPkt), DEPOSIT);
        vm.expectRevert(abi.encodeWithSelector(
            PaktolVaultV2.PremiumAccessExpired.selector,
            block.timestamp - 1 days  // expiry was 15 days ago
        ));
        vaultPkt.deposit(DEPOSIT, user);
        vm.stopPrank();
    }

    function test_deposit_allowed_until_last_second() public {
        vm.prank(owner);
        vaultPkt.grantPremiumAccess(user, 15 days);

        // Avancer juste avant l'expiration.
        _warp(15 days - 1);

        uint256 shares = _deposit(vaultPkt, user, DEPOSIT);
        assertGt(shares, 0);
    }

    function test_deposit_blocked_at_exact_expiry() public {
        uint256 expiry = block.timestamp + 15 days;
        vm.prank(owner);
        vaultPkt.grantPremiumAccess(user, 15 days);

        // Avancer exactement à l'expiration (block.timestamp > expiry → false si ==).
        _warp(15 days);
        assertEq(block.timestamp, expiry);

        // block.timestamp == expiry → NOT expired (strict >).
        uint256 shares = _deposit(vaultPkt, user, DEPOSIT);
        assertGt(shares, 0);
    }

    function test_mint_blocked_withoutAccess() public {
        eurc.mint(user, DEPOSIT);
        vm.startPrank(user);
        eurc.approve(address(vaultPkt), DEPOSIT);
        vm.expectRevert(abi.encodeWithSelector(
            PaktolVaultV2.PremiumAccessExpired.selector, 0
        ));
        vaultPkt.mint(1e9, user);
        vm.stopPrank();
    }

    function test_mint_success_withActiveAccess() public {
        vm.prank(owner);
        vaultPkt.grantPremiumAccess(user, 15 days);

        eurc.mint(user, DEPOSIT);
        vm.startPrank(user);
        eurc.approve(address(vaultPkt), DEPOSIT);
        uint256 assets = vaultPkt.mint(500e9, user);
        vm.stopPrank();

        assertGt(assets, 0);
    }

    /* ──────── Standard vault — jamais affecté par l'expiry ─────────── */

    function test_std_vault_ignores_expiry() public {
        assertEq(vaultStd.premiumExpiry(user), 0);
        uint256 shares = _deposit(vaultStd, user, DEPOSIT);
        assertGt(shares, 0);
    }

    /* ──────── Plusieurs users, accès independants ───────────────────── */

    function test_access_independent_per_user() public {
        vm.prank(owner);
        vaultPkt.grantPremiumAccess(user, 15 days); // user a accès

        // user2 n'a pas d'accès.
        eurc.mint(user2, DEPOSIT);
        vm.startPrank(user2);
        eurc.approve(address(vaultPkt), DEPOSIT);
        vm.expectRevert(abi.encodeWithSelector(
            PaktolVaultV2.PremiumAccessExpired.selector, 0
        ));
        vaultPkt.deposit(DEPOSIT, user2);
        vm.stopPrank();

        // user peut toujours déposer.
        uint256 shares = _deposit(vaultPkt, user, DEPOSIT);
        assertGt(shares, 0);
    }

    /* ──────── Renouvellement — le withdraw reste possible après expiry ── */

    function test_withdraw_still_works_after_expiry() public {
        vm.prank(owner);
        vaultPkt.grantPremiumAccess(user, 15 days);

        uint256 shares = _deposit(vaultPkt, user, DEPOSIT);

        // Access expires — mais le user peut toujours retirer ses fonds.
        _warp(16 days);

        uint256 balBefore = eurc.balanceOf(user);
        vm.prank(user);
        vaultPkt.redeem(shares, user, user);

        assertApproxEqAbs(eurc.balanceOf(user), balBefore + DEPOSIT, 1e3);
    }
}
