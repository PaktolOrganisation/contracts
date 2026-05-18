// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "./PaktolVaultV2Base.t.sol";

contract PaktolVaultV2MultiUserTest is PaktolVaultV2Base {

    /* ──────────────────────── MULTI-USER ───────────────────────────── */

    function test_multiUser_equalShares() public {
        uint256 shares1 = _deposit(vaultStd, user,  DEPOSIT);
        uint256 shares2 = _deposit(vaultStd, user2, DEPOSIT);
        assertEq(shares1, shares2);
    }

    function test_multiUser_proportionalYield() public {
        _deposit(vaultStd, user,  DEPOSIT);
        _deposit(vaultStd, user2, DEPOSIT);

        _warp(365 days);
        mockStd.simulateYield(70e6); // 3.5% for each user = 70 total

        vm.prank(harvester);
        vaultStd.harvest();

        uint256 assets1 = vaultStd.convertToAssets(vaultStd.balanceOf(user));
        uint256 assets2 = vaultStd.convertToAssets(vaultStd.balanceOf(user2));

        assertApproxEqAbs(assets1, assets2, 1e3);

        uint256 aumFee      = (2 * DEPOSIT * FEE_STD) / 10_000; // 10 EURC
        uint256 expectedNet = (70e6 - aumFee) / 2;
        assertApproxEqAbs(assets1, DEPOSIT + expectedNet, 1e3);
    }

    function test_multiUser_laterDepositor_noBackpay() public {
        _deposit(vaultStd, user, DEPOSIT);
        _warp(365 days);
        mockStd.simulateYield(35e6);

        vm.prank(harvester);
        vaultStd.harvest();

        uint256 expectedNet = 35e6 - (DEPOSIT * FEE_STD) / 10_000;
        assertApproxEqAbs(vaultStd.convertToAssets(vaultStd.balanceOf(user)), DEPOSIT + expectedNet, 1e3);

        uint256 shares2 = _deposit(vaultStd, user2, DEPOSIT);
        assertApproxEqAbs(vaultStd.convertToAssets(shares2), DEPOSIT, 1e3);
    }

    /* ─────────────── MAX WITHDRAW / REDEEM ─────────────────────────── */

    function test_maxWithdraw_fullLiquidity() public {
        _deposit(vaultStd, user, DEPOSIT);
        _warp(vaultStd.WITHDRAWAL_COOLDOWN());

        uint256 expected = vaultStd.convertToAssets(vaultStd.balanceOf(user));
        assertApproxEqAbs(vaultStd.maxWithdraw(user), expected, 1e3);
    }

    // _byzantineLiquid() uses convertToAssets(), not maxWithdraw() — Byzantine's
    // maxWithdraw liquidity cap does not restrict our vault's maxWithdraw.
    function test_maxWithdraw_limitedByByzantineLiquidity() public {
        _deposit(vaultStd, user, DEPOSIT);
        _warp(vaultStd.WITHDRAWAL_COOLDOWN());

        mockStd.setLiquidityCap(100e6);

        uint256 expected = vaultStd.convertToAssets(vaultStd.balanceOf(user));
        assertApproxEqAbs(vaultStd.maxWithdraw(user), expected, 1e3);
    }

    function test_maxWithdraw_zeroWhenNoPosition() public view {
        assertEq(vaultStd.maxWithdraw(user), 0);
    }

    // _byzantineLiquid() uses convertToAssets(), not maxWithdraw() — Byzantine's
    // maxWithdraw liquidity cap does not restrict our vault's maxRedeem.
    function test_maxRedeem_limitedByByzantineLiquidity() public {
        uint256 shares = _deposit(vaultStd, user, DEPOSIT);
        _warp(vaultStd.WITHDRAWAL_COOLDOWN());

        mockStd.setLiquidityCap(100e6);

        uint256 maxR = vaultStd.maxRedeem(user);
        assertApproxEqAbs(maxR, shares, 1e3);
    }

    function test_maxWithdraw_idleCountsTowardLiquidity() public {
        _deposit(vaultStd, user, DEPOSIT);

        vm.prank(guardian);
        vaultStd.pause();

        vm.prank(owner);
        vaultStd.emergencyExitByzantine();

        uint256 expected = vaultStd.convertToAssets(vaultStd.balanceOf(user));
        assertApproxEqAbs(vaultStd.maxWithdraw(user), expected, 1e3);
    }

    function test_maxDeposit_returnsZero_whenPaused() public {
        vm.prank(guardian);
        vaultStd.pause();
        assertEq(vaultStd.maxDeposit(user), 0);
    }
}
