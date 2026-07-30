// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "./PaktolVaultV2Base.t.sol";

contract PaktolVaultV2HarvestTest is PaktolVaultV2Base {

    /* ───────────────── HARVEST — STANDARD (exact math) ─────────────── */

    function test_harvest_std_belowCap() public {
        // 20 EURC yield on 1000 = 2% gross, 1 year.
        // aumFee = 1000 × 0.5% = 5  | flooredFee = 20 × 50/200 = 5 → aumFee = 5
        // remaining = 15 | maxNetYield = 1000 × 3.5% = 35 → toUsers = 15, toTreasury = 5
        _deposit(vaultStd, user, DEPOSIT);
        _warp(365 days);
        mockStd.simulateYield(20e6);

        vm.prank(harvester);
        vaultStd.harvest();

        uint256 expectedFee = (DEPOSIT * FEE_STD) / 10_000; // 5 EURC
        assertApproxEqAbs(vaultStd.convertToAssets(vaultStd.balanceOf(treasury)), expectedFee, 1e3);
        assertApproxEqAbs(vaultStd.totalAssets(), DEPOSIT + 20e6, 1e3);
    }

    function test_harvest_std_atCap() public {
        // 40 EURC yield = 4% gross. aumFee = 5, remaining = 35 = maxNetYield → toTreasury = 5
        _deposit(vaultStd, user, DEPOSIT);
        _warp(365 days);
        mockStd.simulateYield(40e6);

        vm.prank(harvester);
        vaultStd.harvest();

        assertApproxEqAbs(vaultStd.convertToAssets(vaultStd.balanceOf(treasury)), 5e6, 1e3);
        assertApproxEqAbs(vaultStd.totalAssets(), DEPOSIT + 40e6, 1e3);
    }

    function test_harvest_std_aboveCap() public {
        // 60 EURC yield = 6% gross.
        // aumFee = 5, remaining = 55, maxNetYield = 35 → toUsers = 35, toTreasury = 25
        _deposit(vaultStd, user, DEPOSIT);
        _warp(365 days);
        mockStd.simulateYield(60e6);

        vm.prank(harvester);
        vaultStd.harvest();

        assertApproxEqAbs(vaultStd.convertToAssets(vaultStd.balanceOf(treasury)), 25e6, 1e3);
        assertApproxEqAbs(vaultStd.totalAssets(), DEPOSIT + 60e6, 1e3);
    }

    function test_harvest_std_noYield() public {
        _deposit(vaultStd, user, DEPOSIT);
        _warp(365 days);

        vm.prank(harvester);
        vaultStd.harvest();

        assertEq(eurc.balanceOf(treasury), 0);
        assertEq(vaultStd.totalAssets(), DEPOSIT);
    }

    function test_harvest_std_loss() public {
        _deposit(vaultStd, user, DEPOSIT);
        _warp(365 days);
        mockStd.simulateLoss(100e6);

        vm.prank(harvester);
        vaultStd.harvest(); // must not revert, no treasury payment

        assertEq(eurc.balanceOf(treasury), 0);
        assertApproxEqAbs(vaultStd.totalAssets(), DEPOSIT - 100e6, 1e3);
    }

    function test_harvest_std_emitsEvent() public {
        _deposit(vaultStd, user, DEPOSIT);
        _warp(365 days);
        mockStd.simulateYield(40e6);

        vm.expectEmit(false, false, false, false);
        emit PaktolVaultV2.Harvested(0, 0, 0, 0);

        vm.prank(harvester);
        vaultStd.harvest();
    }

    function test_harvest_std_belowFloor() public {
        // APY = 1.5% (below 2% floor) — fee is pro-rated down.
        // grossYield = 15 | flooredFee = 15 × 50/200 = 3.75 < maxAumFee 5 → aumFee = 3.75
        _deposit(vaultStd, user, DEPOSIT);
        _warp(365 days);
        mockStd.simulateYield(15e6);

        vm.prank(harvester);
        vaultStd.harvest();

        uint256 expectedFee = (15e6 * 50) / 200; // 3.75 EURC
        assertApproxEqAbs(vaultStd.convertToAssets(vaultStd.balanceOf(treasury)), expectedFee, 1e3);
        assertApproxEqAbs(vaultStd.totalAssets(), DEPOSIT + 15e6, 1e3);
    }

    function test_harvest_std_atFloor() public {
        // APY = 2% exactly — flooredFee == maxAumFee, seamless transition.
        _deposit(vaultStd, user, DEPOSIT);
        _warp(365 days);
        mockStd.simulateYield(20e6);

        vm.prank(harvester);
        vaultStd.harvest();

        uint256 expectedFee = (DEPOSIT * FEE_STD) / 10_000; // 5 EURC
        assertApproxEqAbs(vaultStd.convertToAssets(vaultStd.balanceOf(treasury)), expectedFee, 1e3);
    }

    /* ─────────────────── HARVEST — PREMIUM (FEE=0.5%) ──────────────── */

    function test_harvest_pkt_belowCap() public {
        // 40 EURC = 4% gross, AUM fee = 5e6, remaining = 35e6 < cap(50e6) → toUsers=35e6, toTreasury=5e6
        _depositPremium(user, DEPOSIT);
        _warp(365 days);
        mockPkt.simulateYield(40e6);

        vm.prank(harvester);
        vaultPkt.harvest();

        assertApproxEqAbs(vaultPkt.convertToAssets(vaultPkt.balanceOf(treasury)), 5e6, 1e3);
        assertApproxEqAbs(vaultPkt.totalAssets(), DEPOSIT + 40e6, 1e3);
    }

    function test_harvest_pkt_atCap() public {
        // 50 EURC = 5% gross, AUM fee = 5e6, remaining = 45e6 < cap(50e6) → toUsers=45e6, toTreasury=5e6
        _depositPremium(user, DEPOSIT);
        _warp(365 days);
        mockPkt.simulateYield(50e6);

        vm.prank(harvester);
        vaultPkt.harvest();

        assertApproxEqAbs(vaultPkt.convertToAssets(vaultPkt.balanceOf(treasury)), 5e6, 1e3);
        assertApproxEqAbs(vaultPkt.totalAssets(), DEPOSIT + 50e6, 1e3);
    }

    function test_harvest_pkt_aboveCap() public {
        // 70 EURC = 7% gross, AUM fee = 5e6, remaining = 65e6 > cap(50e6) → toUsers=50e6, toTreasury=20e6
        _depositPremium(user, DEPOSIT);
        _warp(365 days);
        mockPkt.simulateYield(70e6);

        vm.prank(harvester);
        vaultPkt.harvest();

        assertApproxEqAbs(vaultPkt.convertToAssets(vaultPkt.balanceOf(treasury)), 20e6, 1e3);
        assertApproxEqAbs(vaultPkt.totalAssets(), DEPOSIT + 70e6, 1e3);
    }

    /* ──────────────────────── HARVEST GUARDS ────────────────────────── */

    function test_harvest_revert_unauthorized() public {
        vm.expectRevert(PaktolVaultV2.NotHarvester.selector);
        vm.prank(user);
        vaultStd.harvest();
    }

    function test_harvest_owner_canHarvest() public {
        _deposit(vaultStd, user, DEPOSIT);
        _warp(365 days);
        mockStd.simulateYield(40e6);

        vm.prank(owner);
        vaultStd.harvest();

        assertGt(vaultStd.convertToAssets(vaultStd.balanceOf(treasury)), 0);
    }

    function test_harvest_revert_tooFrequent() public {
        _deposit(vaultStd, user, DEPOSIT);
        mockStd.simulateYield(40e6);
        _warp(vaultStd.minHarvestInterval() - 1);

        vm.expectRevert(abi.encodeWithSelector(
            PaktolVaultV2.HarvestTooFrequent.selector,
            vaultStd.minHarvestInterval() - 1,
            vaultStd.minHarvestInterval()
        ));
        vm.prank(harvester);
        vaultStd.harvest();
    }

    function test_harvest_updatesTimestamp() public {
        _deposit(vaultStd, user, DEPOSIT);
        _warp(7 days);
        mockStd.simulateYield(10e6);

        uint256 before = vaultStd.lastHarvestTimestamp();

        vm.prank(harvester);
        vaultStd.harvest();

        assertGt(vaultStd.lastHarvestTimestamp(), before);
    }

    /// @dev F-20: no-yield harvest must NOT advance lastHarvestTimestamp.
    function test_f20_noYield_harvest_preserves_timestamp() public {
        _deposit(vaultStd, user, DEPOSIT);
        _warp(7 days);

        uint256 tsBefore = vaultStd.lastHarvestTimestamp();

        vm.prank(harvester);
        vaultStd.harvest(); // no yield → early return

        assertEq(vaultStd.lastHarvestTimestamp(), tsBefore, "timestamp must not advance on no-yield harvest");

        // Real yield accrues later — full elapsed window is preserved.
        _warp(30 days);
        mockStd.simulateYield(35e6);

        vm.prank(harvester);
        vaultStd.harvest();

        uint256 elapsed = 37 days;
        uint256 maxNetYield = (DEPOSIT * 350 * elapsed) / (10_000 * 365 days);
        assertGe(vaultStd.totalAssets(), DEPOSIT + maxNetYield - 1e3, "full cap window must be applied");
    }

    /* ─────────── F-18: lastTotalAssets accounting invariant ────────── */

    function test_f18_deposit_does_not_absorb_pending_yield() public {
        _deposit(vaultStd, user, DEPOSIT);
        assertEq(vaultStd.lastTotalAssets(), DEPOSIT);

        uint256 yieldAmount = 50e6;
        mockStd.simulateYield(yieldAmount);

        uint256 deposit2 = 200e6;
        _deposit(vaultStd, user2, deposit2);

        assertEq(vaultStd.lastTotalAssets(), DEPOSIT + deposit2, "deposit must not absorb pending yield");

        _warp(365 days);
        vm.prank(harvester);
        vaultStd.harvest();

        assertGt(vaultStd.convertToAssets(vaultStd.balanceOf(treasury)), 0, "treasury must receive yield from pre-deposit accumulation");
    }

    function test_f18_withdraw_does_not_absorb_pending_yield() public {
        _deposit(vaultStd, user,  DEPOSIT);
        _deposit(vaultStd, user2, DEPOSIT);

        uint256 yieldAmount = 50e6;
        mockStd.simulateYield(yieldAmount);

        uint256 withdrawAmount = 200e6;
        _warp(vaultStd.WITHDRAWAL_COOLDOWN());
        vm.prank(user);
        vaultStd.withdraw(withdrawAmount, user, user);

        assertEq(vaultStd.lastTotalAssets(), 2 * DEPOSIT - withdrawAmount, "withdraw must not absorb pending yield");

        _warp(365 days);
        vm.prank(harvester);
        vaultStd.harvest();

        assertGt(vaultStd.convertToAssets(vaultStd.balanceOf(treasury)), 0, "treasury must receive yield from pre-withdrawal accumulation");
    }

    /* ──────────────────────────── FUZZ ─────────────────────────────── */

    function testFuzz_deposit_withdraw_roundtrip(uint256 amount) public {
        amount = bound(amount, vaultStd.minDeposit(), 1_000_000e6);

        uint256 shares = _deposit(vaultStd, user, amount);
        assertApproxEqAbs(vaultStd.totalAssets(), amount, 1e3);

        _warp(vaultStd.WITHDRAWAL_COOLDOWN());
        vm.prank(user);
        vaultStd.redeem(shares, user, user);

        assertApproxEqAbs(eurc.balanceOf(user), USER_BALANCE + amount, 1e3);
    }

    function testFuzz_harvest_std_userNeverExceedsCap(uint256 yieldBps) public {
        yieldBps = bound(yieldBps, 0, 1_000);
        uint256 yieldAmount = (DEPOSIT * yieldBps) / 10_000;

        _deposit(vaultStd, user, DEPOSIT);
        _warp(365 days);
        if (yieldAmount > 0) mockStd.simulateYield(yieldAmount);

        vm.prank(harvester);
        vaultStd.harvest();

        uint256 userAssets    = vaultStd.convertToAssets(vaultStd.balanceOf(user));
        uint256 maxUserAssets = DEPOSIT + (DEPOSIT * CAP_STD) / 10_000;
        assertLe(userAssets, maxUserAssets + 1e3);
    }

    function testFuzz_harvest_pkt_userNeverExceedsCap(uint256 yieldBps) public {
        yieldBps = bound(yieldBps, 0, 1_500);
        uint256 yieldAmount = (DEPOSIT * yieldBps) / 10_000;

        _depositPremium(user, DEPOSIT);
        _warp(365 days);
        if (yieldAmount > 0) mockPkt.simulateYield(yieldAmount);

        vm.prank(harvester);
        vaultPkt.harvest();

        uint256 userAssets    = vaultPkt.convertToAssets(vaultPkt.balanceOf(user));
        uint256 maxUserAssets = DEPOSIT + (DEPOSIT * CAP_PKT) / 10_000;
        assertLe(userAssets, maxUserAssets + 1e3);
    }

    /* ───────────────────── L-1: harvest blocked when paused ────────── */

    function test_l1_harvest_reverts_when_paused() public {
        _deposit(vaultStd, user, DEPOSIT);
        _warp(365 days);
        mockStd.simulateYield(20e6);

        vm.prank(guardian);
        vaultStd.pause();

        vm.prank(harvester);
        vm.expectRevert();
        vaultStd.harvest();
    }

    /* ─────────────── F-05: feeShares dilution backstop ──────────────── */

    // A large one-off yield (50% of capital in one harvest) already sends most
    // of it to treasury by design (CAP_BPS limits toUsers) — must stay well
    // under the 99% backstop and NOT revert.
    function test_f05_harvest_largeYield_belowBackstop_succeeds() public {
        _deposit(vaultStd, user, DEPOSIT);
        _warp(vaultStd.minHarvestInterval() + 1);
        mockStd.simulateYield(DEPOSIT / 2);

        vm.prank(harvester);
        vaultStd.harvest();

        assertGt(vaultStd.balanceOf(treasury), 0, "treasury still receives its fee shares");
    }

    // Yield far exceeding pre-existing capital in a single harvest pushes
    // toTreasury toward `current` (denom collapsing) — must revert instead of
    // minting a catastrophic number of shares.
    function test_f05_harvest_revert_feeSharesTooLarge() public {
        _deposit(vaultStd, user, DEPOSIT);
        _warp(vaultStd.minHarvestInterval() + 1);
        mockStd.simulateYield(DEPOSIT * 10);

        vm.expectPartialRevert(PaktolVaultV2.FeeSharesTooLarge.selector);
        vm.prank(harvester);
        vaultStd.harvest();

        // Failed harvest must not leave any partial state change.
        assertEq(vaultStd.lastTotalAssets(), DEPOSIT, "lastTotalAssets must be untouched on revert");
    }
}
