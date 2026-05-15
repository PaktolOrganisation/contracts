// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "./PaktolVaultV2Base.t.sol";

contract PaktolVaultV2TreasuryTest is PaktolVaultV2Base {

    /* ──────────── Treasury shares compound between harvests ─────────── */

    function test_treasury_shares_compound_between_harvests() public {
        // Harvest 1 — treasury receives shares worth ~5 EURC fee.
        _deposit(vaultStd, user, DEPOSIT);
        _warp(365 days);
        mockStd.simulateYield(20e6);

        vm.prank(harvester);
        vaultStd.harvest();

        uint256 treasuryValueAfterHarvest1 = vaultStd.convertToAssets(vaultStd.balanceOf(treasury));
        assertGt(treasuryValueAfterHarvest1, 0, "treasury must hold shares after harvest 1");

        // Morpho generates more yield — treasury shares appreciate without any action.
        _warp(365 days);
        mockStd.simulateYield(20e6);

        uint256 treasuryValueMidway = vaultStd.convertToAssets(vaultStd.balanceOf(treasury));
        assertGt(
            treasuryValueMidway,
            treasuryValueAfterHarvest1,
            "treasury shares must grow with Morpho yield between harvests"
        );

        // Harvest 2 — treasury receives additional shares on top of already-grown position.
        vm.prank(harvester);
        vaultStd.harvest();

        uint256 treasuryValueAfterHarvest2 = vaultStd.convertToAssets(vaultStd.balanceOf(treasury));
        assertGt(
            treasuryValueAfterHarvest2,
            treasuryValueMidway,
            "harvest 2 must add more shares to treasury"
        );

        // Treasury can redeem all its shares for real EURC at any time.
        uint256 treasuryShares = vaultStd.balanceOf(treasury);
        _warp(vaultStd.WITHDRAWAL_COOLDOWN());
        vm.prank(treasury);
        vaultStd.redeem(treasuryShares, treasury, treasury);

        assertApproxEqAbs(
            eurc.balanceOf(treasury),
            treasuryValueAfterHarvest2,
            1e3,
            "treasury must receive EURC equal to compounded share value"
        );
        assertEq(vaultStd.balanceOf(treasury), 0, "treasury shares fully redeemed");
    }

    /* ──────────── lastTreasuryAssets snapshot — timing fix ─────────── */

    function test_lastTreasuryAssets_updated_after_harvest() public {
        assertEq(vaultStd.lastTreasuryAssets(), 0);

        _deposit(vaultStd, user, DEPOSIT);
        _warp(365 days);
        mockStd.simulateYield(20e6);

        vm.prank(harvester);
        vaultStd.harvest();

        uint256 treasuryValue = vaultStd.convertToAssets(vaultStd.balanceOf(treasury));
        assertEq(
            vaultStd.lastTreasuryAssets(),
            treasuryValue,
            "lastTreasuryAssets must equal treasury share value post-harvest"
        );
    }

    function test_userAssets_uses_snapshot_not_current_value() public {
        // Harvest 1 — treasury gets shares, lastTreasuryAssets snapshot set.
        _deposit(vaultStd, user, DEPOSIT);
        _warp(365 days);
        mockStd.simulateYield(20e6);

        vm.prank(harvester);
        vaultStd.harvest();

        uint256 snapshotAfterH1 = vaultStd.lastTreasuryAssets();
        assertGt(snapshotAfterH1, 0);

        // Morpho generates more yield — treasury shares appreciate.
        _warp(365 days);
        mockStd.simulateYield(20e6);

        uint256 currentTreasuryValue = vaultStd.convertToAssets(vaultStd.balanceOf(treasury));
        assertGt(currentTreasuryValue, snapshotAfterH1, "treasury must have grown");

        // Harvest 2 — userAssets computed from lastTreasuryAssets (snapshot), not current.
        uint256 userAssetsExpected = vaultStd.lastTotalAssets() - snapshotAfterH1;

        vm.prank(harvester);
        vaultStd.harvest();

        assertGt(
            vaultStd.lastTreasuryAssets(),
            snapshotAfterH1,
            "snapshot must advance to current treasury value after harvest 2"
        );

        // User was not over-penalised — cap based on correct userAssets.
        uint256 userValue = vaultStd.convertToAssets(vaultStd.balanceOf(user));
        assertGt(userValue, DEPOSIT, "user must have received yield");
        uint256 maxAllowed = DEPOSIT + (userAssetsExpected * CAP_STD * 365 days) / (10_000 * 365 days) + 1e3;
        assertLe(userValue, maxAllowed + 1e3, "user must not exceed cap");
    }

    function test_flooredFee_uses_user_yield_not_gross() public {
        // Harvest 1 — seed treasury with shares (at-cap scenario).
        _deposit(vaultStd, user, DEPOSIT);
        _warp(365 days);
        mockStd.simulateYield(40e6);

        vm.prank(harvester);
        vaultStd.harvest();

        uint256 treasurySharesH1 = vaultStd.balanceOf(treasury);
        assertGt(treasurySharesH1, 0, "treasury must have shares after H1");

        uint256 userAssets_ = vaultStd.lastTotalAssets() - vaultStd.lastTreasuryAssets();
        uint256 totalPool_  = vaultStd.lastTotalAssets();

        // Harvest 2 — below-floor yield (1% APY).
        _warp(365 days);
        uint256 belowFloorYield = 10e6;
        mockStd.simulateYield(belowFloorYield);

        // Expected fee using userYield (correct implementation).
        uint256 userYield_  = belowFloorYield * userAssets_ / totalPool_;
        uint256 expectedFee = userYield_ * FEE_STD / 200;

        // What fee would be using grossYield (wrong implementation).
        uint256 wrongFee = belowFloorYield * FEE_STD / 200;

        assertLt(userYield_, belowFloorYield, "userYield must be less than grossYield");
        assertLt(expectedFee, wrongFee,       "correct fee must be less than grossYield-based fee");

        vm.prank(harvester);
        vaultStd.harvest();

        uint256 newShares     = vaultStd.balanceOf(treasury) - treasurySharesH1;
        uint256 newShareValue = vaultStd.convertToAssets(newShares);

        assertApproxEqAbs(newShareValue, expectedFee, 1e4, "H2 fee must be based on userYield");
        assertGt(wrongFee - newShareValue, 0,               "H2 fee must be less than grossYield-based fee");
    }

    /* ──────── H-1: lastTreasuryAssets synced on loss harvest ───────── */

    /// @dev After a Morpho loss, lastTreasuryAssets must scale down with lastTotalAssets
    ///      so that userAssets is not zero on recovery and user yield is not stolen.
    function test_h1_loss_harvest_syncs_lastTreasuryAssets() public {
        // Harvest 1 — treasury gets shares worth ~5 EURC.
        _deposit(vaultStd, user, DEPOSIT);
        _warp(365 days);
        mockStd.simulateYield(20e6);
        vm.prank(harvester);
        vaultStd.harvest();

        uint256 treasuryValueAfterH1 = vaultStd.lastTreasuryAssets();
        assertGt(treasuryValueAfterH1, 0);

        // Morpho suffers a loss — TVL drops below lastTotalAssets.
        _warp(7 days);
        mockStd.simulateLoss(500e6); // vault now underwater

        vm.prank(harvester);
        vaultStd.harvest(); // no-yield branch

        // lastTreasuryAssets must be re-synced to current treasury share value.
        uint256 currentTreasuryValue = vaultStd.convertToAssets(vaultStd.balanceOf(treasury));
        assertEq(
            vaultStd.lastTreasuryAssets(),
            currentTreasuryValue,
            "lastTreasuryAssets must be synced after loss harvest"
        );

        // userAssets must be positive — not zeroed by stale snapshot.
        uint256 userAssets = vaultStd.lastTotalAssets() > vaultStd.lastTreasuryAssets()
            ? vaultStd.lastTotalAssets() - vaultStd.lastTreasuryAssets()
            : 0;
        assertGt(userAssets, 0, "userAssets must remain positive after loss, not zeroed by stale snapshot");
    }

    /// @dev On recovery after loss, user yield must not go entirely to treasury.
    function test_h1_recovery_yield_goes_to_users() public {
        // Harvest 1 — seed treasury shares.
        _deposit(vaultStd, user, DEPOSIT);
        _warp(365 days);
        mockStd.simulateYield(20e6);
        vm.prank(harvester);
        vaultStd.harvest();

        // Loss — then loss-harvest to sync snapshot.
        _warp(7 days);
        mockStd.simulateLoss(200e6);
        vm.prank(harvester);
        vaultStd.harvest(); // no-yield branch, syncs lastTreasuryAssets

        uint256 userValueBeforeRecovery = vaultStd.convertToAssets(vaultStd.balanceOf(user));

        // Recovery yield.
        _warp(365 days);
        mockStd.simulateYield(30e6);
        vm.prank(harvester);
        vaultStd.harvest();

        uint256 userValueAfterRecovery = vaultStd.convertToAssets(vaultStd.balanceOf(user));

        assertGt(
            userValueAfterRecovery,
            userValueBeforeRecovery,
            "user must receive recovery yield, not stolen by treasury due to stale snapshot"
        );
    }

    /* ───────────────── L-2: treasury cooldown exemption ────────────── */

    /// @dev Treasury receives shares via harvest (no depositTimestamp set).
    ///      It must be able to redeem immediately — no 4h cooldown.
    function test_l2_treasury_redeem_immediate_after_harvest() public {
        _deposit(vaultStd, user, DEPOSIT);
        _warp(365 days);
        mockStd.simulateYield(20e6);

        vm.prank(harvester);
        vaultStd.harvest();

        uint256 treasuryShares = vaultStd.balanceOf(treasury);
        assertGt(treasuryShares, 0, "treasury must hold shares");

        // No time warp — treasury should be able to redeem at t=0 after harvest.
        assertGt(vaultStd.maxRedeem(treasury), 0, "treasury maxRedeem must be > 0 immediately");

        uint256 balBefore = eurc.balanceOf(treasury);
        vm.prank(treasury);
        vaultStd.redeem(treasuryShares, treasury, treasury);

        assertGt(eurc.balanceOf(treasury), balBefore, "treasury must receive EURC immediately");
    }

    /// @dev Regular user is still subject to the 4h cooldown.
    function test_l2_user_cooldown_still_enforced() public {
        _deposit(vaultStd, user, DEPOSIT);

        // Immediately after deposit — maxRedeem must be 0.
        assertEq(vaultStd.maxRedeem(user), 0, "user must be locked within 4h cooldown");
    }
}
