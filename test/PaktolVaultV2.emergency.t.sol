// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "./PaktolVaultV2Base.t.sol";

contract PaktolVaultV2EmergencyTest is PaktolVaultV2Base {

    /* ────────────────────── EMERGENCY EXIT ─────────────────────────── */

    function test_emergencyExit_pullsAllFromByzantine() public {
        _deposit(vaultStd, user, DEPOSIT);

        assertGt(mockStd.balanceOf(address(vaultStd)), 0);
        assertEq(eurc.balanceOf(address(vaultStd)), 0);

        vm.prank(owner);
        vaultStd.emergencyExitByzantine();

        assertEq(mockStd.balanceOf(address(vaultStd)), 0, "no Byzantine shares after exit");
        assertApproxEqAbs(eurc.balanceOf(address(vaultStd)), DEPOSIT, 1e3, "idle EURC after exit");
    }

    function test_emergencyExit_usersCanWithdraw() public {
        uint256 shares = _deposit(vaultStd, user, DEPOSIT);

        vm.prank(guardian);
        vaultStd.pause();

        vm.prank(owner);
        vaultStd.emergencyExitByzantine();

        uint256 balBefore = eurc.balanceOf(user);
        vm.prank(user);
        vaultStd.redeem(shares, user, user);

        assertApproxEqAbs(eurc.balanceOf(user), balBefore + DEPOSIT, 1e3);
    }

    function test_emergencyExit_emitsEvent() public {
        _deposit(vaultStd, user, DEPOSIT);

        vm.expectEmit(false, false, false, false);
        emit PaktolVaultV2.EmergencyExitV2(0, 0);

        vm.prank(owner);
        vaultStd.emergencyExitByzantine();
    }

    function test_emergencyExit_noOp_whenNoBalance() public {
        // No deposit — Byzantine shares = 0. Should not revert.
        vm.prank(owner);
        vaultStd.emergencyExitByzantine();
    }

    function test_emergencyExit_revert_unauthorized() public {
        _deposit(vaultStd, user, DEPOSIT);

        vm.expectRevert();
        vm.prank(user);
        vaultStd.emergencyExitByzantine();

        vm.expectRevert();
        vm.prank(guardian);
        vaultStd.emergencyExitByzantine();
    }

    /// @dev F-11: emergencyExitByzantine() must pause atomically.
    function test_f11_emergencyExit_autopause() public {
        _deposit(vaultStd, user, DEPOSIT);
        assertFalse(vaultStd.paused());

        vm.prank(owner);
        vaultStd.emergencyExitByzantine();

        assertTrue(vaultStd.paused(), "vault must be paused after emergency exit");

        vm.startPrank(user);
        eurc.approve(address(vaultStd), DEPOSIT);
        vm.expectRevert();
        vaultStd.deposit(DEPOSIT, user);
        vm.stopPrank();
    }

    /// @dev F-11: emergencyExitByzantine() on an already-paused vault must not revert.
    function test_f11_emergencyExit_alreadyPaused_noRevert() public {
        _deposit(vaultStd, user, DEPOSIT);

        vm.prank(guardian);
        vaultStd.pause();

        vm.prank(owner);
        vaultStd.emergencyExitByzantine();

        assertTrue(vaultStd.paused());
        assertEq(mockStd.balanceOf(address(vaultStd)), 0);
    }

    /// @dev F-11: accounting snapshot after emergency exit is clean.
    function test_f11_emergencyExit_updatesAccounting() public {
        _deposit(vaultStd, user, DEPOSIT);
        mockStd.simulateYield(20e6);
        _warp(7 days);

        uint256 tsBefore = vaultStd.lastHarvestTimestamp();

        vm.prank(owner);
        vaultStd.emergencyExitByzantine();

        assertEq(vaultStd.lastTotalAssets(),    vaultStd.totalAssets(),   "lastTotalAssets must reflect post-exit state");
        assertGt(vaultStd.lastHarvestTimestamp(), tsBefore,               "lastHarvestTimestamp must be reset");
        assertEq(vaultStd.lastTreasuryAssets(),
            vaultStd.convertToAssets(vaultStd.balanceOf(treasury)),       "lastTreasuryAssets must be synced on exit");
    }

    /// @dev F-11: lastTreasuryAssets stays consistent after exit so next harvest userAssets is correct.
    function test_f11_emergencyExit_treasury_snapshot_consistent() public {
        // Harvest 1 — treasury accumulates shares.
        _deposit(vaultStd, user, DEPOSIT);
        _warp(365 days);
        mockStd.simulateYield(40e6);
        vm.prank(harvester);
        vaultStd.harvest();

        uint256 treasurySnapshotAfterH1 = vaultStd.lastTreasuryAssets();
        assertGt(treasurySnapshotAfterH1, 0, "treasury must have shares after H1");

        // Emergency exit — all Byzantine shares redeemed, vault paused.
        _warp(1 days);
        mockStd.simulateYield(5e6);
        vm.prank(owner);
        vaultStd.emergencyExitByzantine();

        uint256 currentTreasuryValue = vaultStd.convertToAssets(vaultStd.balanceOf(treasury));
        assertEq(
            vaultStd.lastTreasuryAssets(),
            currentTreasuryValue,
            "lastTreasuryAssets must be synced with lastTotalAssets after exit"
        );

        // Unpause and harvest — userAssets must be computed from consistent snapshots.
        vm.prank(owner);
        vaultStd.unpause();
        _warp(365 days);

        eurc.mint(address(vaultStd), 10e6);

        vm.prank(harvester);
        vaultStd.harvest();

        assertEq(
            vaultStd.lastTreasuryAssets(),
            vaultStd.convertToAssets(vaultStd.balanceOf(treasury)),
            "lastTreasuryAssets must remain consistent after post-exit harvest"
        );
    }

    /* ─────────────────── F-09: WITHDRAWAL COOLDOWN ─────────────────── */

    function test_f09_cooldown_blocks_immediate_withdraw() public {
        _deposit(vaultStd, user, DEPOSIT);

        vm.expectRevert(abi.encodeWithSelector(
            PaktolVaultV2.WithdrawalCooldown.selector,
            block.timestamp + vaultStd.WITHDRAWAL_COOLDOWN()
        ));
        vm.prank(user);
        vaultStd.withdraw(DEPOSIT, user, user);
    }

    function test_f09_cooldown_blocks_immediate_redeem() public {
        uint256 shares = _deposit(vaultStd, user, DEPOSIT);

        vm.expectRevert(abi.encodeWithSelector(
            PaktolVaultV2.WithdrawalCooldown.selector,
            block.timestamp + vaultStd.WITHDRAWAL_COOLDOWN()
        ));
        vm.prank(user);
        vaultStd.redeem(shares, user, user);
    }

    function test_f09_cooldown_allows_withdraw_after_delay() public {
        _deposit(vaultStd, user, DEPOSIT);
        _warp(vaultStd.WITHDRAWAL_COOLDOWN());

        uint256 balBefore = eurc.balanceOf(user);
        vm.prank(user);
        vaultStd.withdraw(DEPOSIT, user, user);

        assertApproxEqAbs(eurc.balanceOf(user), balBefore + DEPOSIT, 1e3);
    }

    function test_f09_sandwich_blocked_by_cooldown() public {
        _deposit(vaultStd, user, DEPOSIT);
        _warp(365 days);
        mockStd.simulateYield(35e6);

        address attacker = address(this);
        eurc.mint(attacker, DEPOSIT);
        vm.startPrank(attacker);
        eurc.approve(address(vaultStd), DEPOSIT);
        uint256 attackShares = vaultStd.deposit(DEPOSIT, attacker);
        vm.stopPrank();

        vm.prank(harvester);
        vaultStd.harvest();

        vm.expectRevert();
        vm.prank(attacker);
        vaultStd.redeem(attackShares, attacker, attacker);
    }

    function test_f09_cooldown_independent_per_user() public {
        _deposit(vaultStd, user, DEPOSIT);
        _warp(vaultStd.WITHDRAWAL_COOLDOWN());
        _deposit(vaultStd, user2, DEPOSIT);

        vm.prank(user);
        vaultStd.withdraw(DEPOSIT, user, user);

        vm.expectRevert();
        vm.prank(user2);
        vaultStd.withdraw(DEPOSIT, user2, user2);
    }

    function test_f09_cooldown_propagated_on_transfer() public {
        uint256 shares = _deposit(vaultStd, user, DEPOSIT);

        address attacker2 = makeAddr("attacker2");

        vm.prank(user);
        vaultStd.transfer(attacker2, shares);

        assertEq(vaultStd.depositTimestamp(attacker2), vaultStd.depositTimestamp(user));

        vm.expectRevert();
        vm.prank(attacker2);
        vaultStd.redeem(shares, attacker2, attacker2);
    }

    /* ─────────────── F-01: dust-transfer cooldown griefing ───────────── */

    // A victim with an existing, already-expired cooldown must not have it
    // forcibly extended by an unsolicited dust transfer from an attacker.
    function test_f01_dust_transfer_does_not_extend_existing_victim_cooldown() public {
        uint256 victimShares = _deposit(vaultStd, user, DEPOSIT);
        _warp(vaultStd.WITHDRAWAL_COOLDOWN()); // victim's cooldown has expired

        address attacker = makeAddr("attacker");
        eurc.mint(attacker, 1e3);
        vm.startPrank(attacker);
        eurc.approve(address(vaultStd), 1e3);
        uint256 attackerShares = vaultStd.deposit(1e3, attacker); // fresh, un-expired cooldown
        vaultStd.transfer(user, 1); // dust griefing attempt
        vm.stopPrank();

        // Victim's cooldown must be untouched by the unsolicited dust transfer.
        assertEq(vaultStd.depositTimestamp(user), block.timestamp - vaultStd.WITHDRAWAL_COOLDOWN());
        assertGt(vaultStd.maxRedeem(user), 0, "victim must still be able to redeem immediately");

        uint256 balBefore = eurc.balanceOf(user);
        vm.prank(user);
        vaultStd.redeem(victimShares, user, user);
        assertApproxEqAbs(eurc.balanceOf(user), balBefore + DEPOSIT, 1e3);

        // Sanity: attacker's own fresh position is still on cooldown.
        vm.expectRevert();
        vm.prank(attacker);
        vaultStd.redeem(attackerShares - 1, attacker, attacker);
    }

    // A user moving their own shares to a fresh wallet (self-custody, hardware
    // wallet, etc.) right after depositing must NOT be blocked — the transfer
    // succeeds, the new wallet just inherits the remaining cooldown (F-09 intact).
    function test_f01_selfTransfer_to_freshWallet_succeeds_but_inherits_cooldown() public {
        uint256 shares = _deposit(vaultStd, user, DEPOSIT);
        address personalWallet = makeAddr("personalWallet");

        // Still within cooldown — transfer itself must not revert.
        vm.prank(user);
        vaultStd.transfer(personalWallet, shares);

        assertEq(vaultStd.depositTimestamp(personalWallet), vaultStd.depositTimestamp(user));

        // Inherited cooldown still blocks immediate withdrawal (F-09 preserved).
        vm.expectRevert();
        vm.prank(personalWallet);
        vaultStd.redeem(shares, personalWallet, personalWallet);

        // After the (inherited) cooldown elapses, the personal wallet can redeem.
        _warp(vaultStd.WITHDRAWAL_COOLDOWN());
        uint256 balBefore = eurc.balanceOf(personalWallet);
        vm.prank(personalWallet);
        vaultStd.redeem(shares, personalWallet, personalWallet);
        assertApproxEqAbs(eurc.balanceOf(personalWallet), balBefore + DEPOSIT, 1e3);
    }

    function test_f09_cooldown_bypassed_when_paused() public {
        uint256 shares = _deposit(vaultStd, user, DEPOSIT);

        vm.prank(guardian);
        vaultStd.pause();

        uint256 balBefore = eurc.balanceOf(user);
        vm.prank(user);
        vaultStd.redeem(shares, user, user);

        assertApproxEqAbs(eurc.balanceOf(user), balBefore + DEPOSIT, 1e3);
    }

    /* ─────────────────── F-08: redeployToByzantine ──────────────────── */

    function test_f08_redeploy_pushesIdleBackToByzantine() public {
        _deposit(vaultStd, user, DEPOSIT);

        vm.prank(owner);
        vaultStd.emergencyExitByzantine();
        assertApproxEqAbs(eurc.balanceOf(address(vaultStd)), DEPOSIT, 1e3, "idle after exit");

        vm.prank(owner);
        vaultStd.unpause();

        vm.prank(owner);
        vaultStd.redeployToByzantine();

        assertEq(eurc.balanceOf(address(vaultStd)), 0, "no idle EURC after redeploy");
        assertGt(mockStd.balanceOf(address(vaultStd)), 0, "Byzantine shares restored");
    }

    function test_f08_redeploy_revert_unauthorized() public {
        _deposit(vaultStd, user, DEPOSIT);
        vm.prank(owner);
        vaultStd.emergencyExitByzantine();
        vm.prank(owner);
        vaultStd.unpause();

        vm.expectRevert();
        vm.prank(user);
        vaultStd.redeployToByzantine();
    }

    function test_f08_redeploy_revert_whenPaused() public {
        _deposit(vaultStd, user, DEPOSIT);
        vm.prank(owner);
        vaultStd.emergencyExitByzantine();

        // Still paused — must not be able to redeploy mid-emergency.
        vm.expectRevert();
        vm.prank(owner);
        vaultStd.redeployToByzantine();
    }

    function test_f08_redeploy_noOp_whenNoIdle() public {
        vm.prank(owner);
        vaultStd.redeployToByzantine();
        assertEq(eurc.balanceOf(address(vaultStd)), 0);
    }

    function test_f08_redeploy_emitsEvent() public {
        _deposit(vaultStd, user, DEPOSIT);
        vm.prank(owner);
        vaultStd.emergencyExitByzantine();
        vm.prank(owner);
        vaultStd.unpause();

        vm.expectEmit(false, false, false, true);
        emit PaktolVaultV2.RedeployedToByzantine(DEPOSIT, block.timestamp);
        vm.prank(owner);
        vaultStd.redeployToByzantine();
    }

    function test_f09_maxWithdraw_zero_during_cooldown() public {
        _deposit(vaultStd, user, DEPOSIT);

        assertEq(vaultStd.maxWithdraw(user), 0, "maxWithdraw must be 0 during cooldown");
        assertEq(vaultStd.maxRedeem(user),   0, "maxRedeem must be 0 during cooldown");

        _warp(vaultStd.WITHDRAWAL_COOLDOWN());

        assertGt(vaultStd.maxWithdraw(user), 0);
        assertGt(vaultStd.maxRedeem(user),   0);
    }
}
