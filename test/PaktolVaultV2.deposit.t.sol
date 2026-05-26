// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "./PaktolVaultV2Base.t.sol";

contract PaktolVaultV2DepositTest is PaktolVaultV2Base {

    /* ─────────────────── DEPOSIT → BYZANTINE ROUTING ───────────────── */

    function test_deposit_basic() public {
        uint256 shares = _deposit(vaultStd, user, DEPOSIT);

        assertGt(shares, 0);
        assertEq(vaultStd.totalAssets(), DEPOSIT);
        assertEq(eurc.balanceOf(address(vaultStd)), 0, "no idle EURC");
        assertGt(mockStd.balanceOf(address(vaultStd)), 0, "vault holds Byzantine shares");
    }

    function test_deposit_updates_lastTotalAssets() public {
        _deposit(vaultStd, user, DEPOSIT);
        assertEq(vaultStd.lastTotalAssets(), DEPOSIT);
    }

    function test_deposit_revert_tooSmall() public {
        uint256 tiny = vaultStd.minDeposit() - 1;
        eurc.mint(user, tiny);
        vm.startPrank(user);
        eurc.approve(address(vaultStd), tiny);
        vm.expectRevert(abi.encodeWithSelector(PaktolVaultV2.DepositTooSmall.selector, tiny, vaultStd.minDeposit()));
        vaultStd.deposit(tiny, user);
        vm.stopPrank();
    }

    function test_deposit_revert_whenPaused() public {
        vm.prank(guardian);
        vaultStd.pause();

        vm.startPrank(user);
        eurc.approve(address(vaultStd), DEPOSIT);
        vm.expectRevert();
        vaultStd.deposit(DEPOSIT, user);
        vm.stopPrank();
    }

    // F-19: depositUpToCap.
    function test_f19_depositUpToCap_full_when_under_cap() public {
        PaktolVaultV2 capped = new PaktolVaultV2(
            IERC20(address(eurc)), "x", "x", owner, treasury, CAP_STD, FEE_STD,
            guardian, harvester, address(0), address(mockStd), 2_000e6, 0, false
        );
        eurc.mint(user, 1_000e6);
        vm.startPrank(user);
        eurc.approve(address(capped), 1_000e6);
        (uint256 accepted, uint256 shares) = capped.depositUpToCap(1_000e6, user);
        vm.stopPrank();

        assertEq(accepted, 1_000e6, "full amount accepted");
        assertGt(shares, 0);
    }

    function test_f19_depositUpToCap_truncates_at_cap() public {
        uint256 cap = 1_500e6;
        PaktolVaultV2 capped = new PaktolVaultV2(
            IERC20(address(eurc)), "x", "x", owner, treasury, CAP_STD, FEE_STD,
            guardian, harvester, address(0), address(mockStd), cap, 0, false
        );
        eurc.mint(user, 1_000e6);
        vm.startPrank(user);
        eurc.approve(address(capped), 1_000e6);
        capped.deposit(1_000e6, user);
        vm.stopPrank();

        _warp(capped.WITHDRAWAL_COOLDOWN());

        eurc.mint(user2, 1_000e6);
        vm.startPrank(user2);
        eurc.approve(address(capped), 1_000e6);
        (uint256 accepted, uint256 shares) = capped.depositUpToCap(1_000e6, user2);
        vm.stopPrank();

        assertApproxEqAbs(accepted, 500e6, 1e3, "truncated to remaining capacity");
        assertGt(shares, 0);
        assertApproxEqAbs(capped.totalAssets(), cap, 1e3, "vault at cap");
    }

    function test_f19_depositUpToCap_returns_zero_when_full() public {
        uint256 cap = 1_000e6;
        PaktolVaultV2 capped = new PaktolVaultV2(
            IERC20(address(eurc)), "x", "x", owner, treasury, CAP_STD, FEE_STD,
            guardian, harvester, address(0), address(mockStd), cap, 0, false
        );
        eurc.mint(user, cap);
        vm.startPrank(user);
        eurc.approve(address(capped), cap);
        capped.deposit(cap, user);
        vm.stopPrank();

        _warp(capped.WITHDRAWAL_COOLDOWN());

        eurc.mint(user2, 500e6);
        vm.startPrank(user2);
        eurc.approve(address(capped), 500e6);
        (uint256 accepted, uint256 shares) = capped.depositUpToCap(500e6, user2);
        vm.stopPrank();

        assertEq(accepted, 0, "nothing accepted when cap full");
        assertEq(shares, 0);
    }

    function test_f19_deposit_still_reverts_at_cap() public {
        uint256 cap = 1_000e6;
        PaktolVaultV2 capped = new PaktolVaultV2(
            IERC20(address(eurc)), "x", "x", owner, treasury, CAP_STD, FEE_STD,
            guardian, harvester, address(0), address(mockStd), cap, 0, false
        );
        eurc.mint(user, cap + 1e6);
        vm.startPrank(user);
        eurc.approve(address(capped), cap + 1e6);
        capped.deposit(cap, user);
        _warp(capped.WITHDRAWAL_COOLDOWN());
        vm.expectRevert(abi.encodeWithSelector(PaktolVaultV2.TvlCapExceeded.selector, capped.totalAssets(), cap));
        capped.deposit(1e6, user);
        vm.stopPrank();
    }

    /* ──────────────────────────── MINT ─────────────────────────────── */

    function test_mint_basic() public {
        uint256 sharesToMint = 500e9;
        vm.startPrank(user);
        eurc.approve(address(vaultStd), DEPOSIT);
        uint256 assetsUsed = vaultStd.mint(sharesToMint, user);
        vm.stopPrank();

        assertGt(assetsUsed, 0);
        assertEq(vaultStd.balanceOf(user), sharesToMint);
        assertEq(eurc.balanceOf(address(vaultStd)), 0, "no idle EURC after mint");
    }

    /* ─────────────────────── WITHDRAW / REDEEM ─────────────────────── */

    function test_withdraw_basic() public {
        _deposit(vaultStd, user, DEPOSIT);
        _warp(vaultStd.WITHDRAWAL_COOLDOWN());
        uint256 balBefore = eurc.balanceOf(user);

        vm.prank(user);
        vaultStd.withdraw(DEPOSIT, user, user);

        assertEq(eurc.balanceOf(user), balBefore + DEPOSIT);
        assertEq(vaultStd.totalAssets(), 0);
    }

    function test_withdraw_works_when_paused() public {
        _deposit(vaultStd, user, DEPOSIT);

        vm.prank(guardian);
        vaultStd.pause();

        uint256 balBefore = eurc.balanceOf(user);
        vm.prank(user);
        vaultStd.withdraw(DEPOSIT, user, user);

        assertApproxEqAbs(eurc.balanceOf(user), balBefore + DEPOSIT, 1e3);
    }

    function test_redeem_basic() public {
        uint256 shares = _deposit(vaultStd, user, DEPOSIT);
        _warp(vaultStd.WITHDRAWAL_COOLDOWN());
        uint256 balBefore = eurc.balanceOf(user);

        vm.prank(user);
        vaultStd.redeem(shares, user, user);

        assertApproxEqAbs(eurc.balanceOf(user), balBefore + DEPOSIT, 1e3);
        assertApproxEqAbs(vaultStd.totalAssets(), 0, 1e3);
    }

    function test_withdraw_updates_lastTotalAssets() public {
        _deposit(vaultStd, user, DEPOSIT);
        _warp(vaultStd.WITHDRAWAL_COOLDOWN());

        vm.prank(user);
        vaultStd.withdraw(DEPOSIT / 2, user, user);

        assertApproxEqAbs(vaultStd.lastTotalAssets(), DEPOSIT / 2, 1e3);
    }

    /* ──────────── totalAssets reflects Byzantine yield ─────────────── */

    function test_totalAssets_reflectsYield() public {
        _deposit(vaultStd, user, DEPOSIT);
        uint256 before = vaultStd.totalAssets();

        mockStd.simulateYield(500e6);

        assertGt(vaultStd.totalAssets(), before);
    }
}
