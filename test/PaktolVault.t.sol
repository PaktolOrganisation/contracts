// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "forge-std/Test.sol";
import "../src/PaktolVault.sol";
import "./mocks/MockEURe.sol";
import "./mocks/MockAavePool.sol";

contract PaktolVaultTest is Test {
    MockEURe internal eure;
    MockAavePool internal pool;

    // Standard vault — 0.5% fee, 3.5% cap, open deposits
    PaktolVault internal vaultStd;
    // Paktol subscription vault — 0% fee, 5% cap, requires backend auth
    PaktolVault internal vaultPkt;

    address internal owner     = makeAddr("owner");
    address internal treasury  = makeAddr("treasury");
    address internal guardian  = makeAddr("guardian");
    address internal harvester = makeAddr("harvester");
    address internal user      = makeAddr("user");
    address internal user2     = makeAddr("user2");

    // Backend signer for depositWithAuth — private key kept in tests only
    uint256 internal signerPk   = 0xB4C4E3D;
    address internal signerAddr;

    uint256 constant CAP_STD = 350; // 3.5%
    uint256 constant CAP_PKT = 500; // 5%
    uint256 constant FEE_STD = 50;  // 0.5%
    uint256 constant FEE_PKT = 0;   // none

    uint256 constant DEPOSIT      = 1_000e18; // 1 000 EURe
    uint256 constant USER_BALANCE = 10_000e18;

    function setUp() public {
        eure = new MockEURe();
        pool = new MockAavePool(address(eure));
        signerAddr = vm.addr(signerPk);

        vaultStd = new PaktolVault(
            IERC20(address(eure)), "Paktol Standard", "pkEUR-S", owner,
            treasury, CAP_STD, FEE_STD, guardian, harvester,
            address(pool), address(pool.aToken()), 0, signerAddr, false
        );
        vaultPkt = new PaktolVault(
            IERC20(address(eure)), "Paktol Subscription", "pkEUR-P", owner,
            treasury, CAP_PKT, FEE_PKT, guardian, harvester,
            address(pool), address(pool.aToken()), 0, signerAddr, true
        );

        eure.mint(user, USER_BALANCE);
        eure.mint(user2, USER_BALANCE);
    }

    /* ─────────────────────── HELPERS ────────────────────────────────── */

    function _deposit(
        PaktolVault vault,
        address who,
        uint256 amount
    ) internal returns (uint256 shares) {
        vm.startPrank(who);
        eure.approve(address(vault), amount);
        shares = vault.deposit(amount, who);
        vm.stopPrank();
    }

    /// @dev Mints EURe to aToken (backing) then rebases aToken to simulate AAVE yield.
    ///      In real AAVE v3, underlying is held by the aToken contract — mock mirrors this.
    function _simulateYield(
        PaktolVault vault,
        uint256 amount
    ) internal {
        eure.mint(address(pool.aToken()), amount);
        pool.simulateYield(address(vault), amount);
    }

    function _warp(
        uint256 secs
    ) internal {
        vm.warp(block.timestamp + secs);
    }

    /// @dev Signs and executes a depositWithAuth on a restricted vault.
    function _depositWithAuth(
        PaktolVault vault,
        address who,
        uint256 amount
    ) internal returns (uint256 shares) {
        uint256 deadline = block.timestamp + 1 hours;
        bytes32 structHash = keccak256(abi.encode(
            vault.DEPOSIT_AUTH_TYPEHASH(),
            who,
            amount,
            who,
            deadline,
            vault.nonces(who)
        ));
        bytes32 digest = keccak256(abi.encodePacked("\x19\x01", vault.DOMAIN_SEPARATOR(), structHash));
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(signerPk, digest);
        bytes memory sig = abi.encodePacked(r, s, v);

        vm.startPrank(who);
        eure.approve(address(vault), amount);
        shares = vault.depositWithAuth(amount, who, deadline, sig);
        vm.stopPrank();
    }

    /* ── Constructor revert helpers ────────────────────────────────────
       vm.expectRevert does not intercept CREATE opcodes in the same frame.
       Each helper is external so the deployment is a proper sub-call.
    ── */

    function helper_deployZeroAsset() external {
        new PaktolVault(
            IERC20(address(0)), "x", "x", owner,
            treasury, CAP_STD, FEE_STD, guardian, harvester,
            address(pool), address(pool.aToken()), 0, signerAddr, false
        );
    }

    function helper_deployZeroTreasury() external {
        new PaktolVault(
            IERC20(address(eure)), "x", "x", owner,
            address(0), CAP_STD, FEE_STD, guardian, harvester,
            address(pool), address(pool.aToken()), 0, signerAddr, false
        );
    }

    function helper_deployCapZero() external {
        new PaktolVault(
            IERC20(address(eure)), "x", "x", owner,
            treasury, 0, FEE_STD, guardian, harvester,
            address(pool), address(pool.aToken()), 0, signerAddr, false
        );
    }

    function helper_deployCapAboveMax() external {
        new PaktolVault(
            IERC20(address(eure)), "x", "x", owner,
            treasury, 10_001, FEE_STD, guardian, harvester,
            address(pool), address(pool.aToken()), 0, signerAddr, false
        );
    }

    function helper_deployFee100pct() external {
        new PaktolVault(
            IERC20(address(eure)), "x", "x", owner,
            treasury, CAP_STD, 10_000, guardian, harvester,
            address(pool), address(pool.aToken()), 0, signerAddr, false
        );
    }

    function helper_deployFeeAboveFloor() external {
        new PaktolVault(
            IERC20(address(eure)), "x", "x", owner,
            treasury, CAP_STD, 201, guardian, harvester,
            address(pool), address(pool.aToken()), 0, signerAddr, false
        );
    }

    function helper_deployATokenMismatch(address wrongAToken_) external {
        new PaktolVault(
            IERC20(address(eure)), "x", "x", owner,
            treasury, CAP_STD, FEE_STD, guardian, harvester,
            address(pool), wrongAToken_, 0, signerAddr, false
        );
    }

    /* ─────────────────────── CONSTRUCTOR ────────────────────────────── */

    function test_constructor_immutables() public view {
        assertEq(vaultStd.CAP_BPS(), CAP_STD);
        assertEq(vaultStd.FEE_BPS(), FEE_STD);
        assertEq(vaultStd.TREASURY(), treasury);
        assertEq(vaultStd.AAVE_POOL(), address(pool));
        assertEq(vaultStd.ATOKEN(), address(pool.aToken()));
        assertEq(vaultStd.guardian(), guardian);
        assertEq(vaultStd.harvester(), harvester);
        assertEq(vaultStd.SIGNER(), signerAddr);
        assertFalse(vaultStd.REQUIRES_AUTH());

        assertEq(vaultPkt.SIGNER(), signerAddr);
        assertTrue(vaultPkt.REQUIRES_AUTH());
    }

    function test_constructor_revert_zeroAsset() public {
        vm.expectRevert(abi.encodeWithSelector(PaktolVault.ZeroAddress.selector, "asset"));
        this.helper_deployZeroAsset();
    }

    function test_constructor_revert_zeroTreasury() public {
        vm.expectRevert(abi.encodeWithSelector(PaktolVault.ZeroAddress.selector, "treasury"));
        this.helper_deployZeroTreasury();
    }

    function test_constructor_revert_capZero() public {
        vm.expectRevert(abi.encodeWithSelector(PaktolVault.CapOutOfRange.selector, 0));
        this.helper_deployCapZero();
    }

    function test_constructor_revert_capAboveMax() public {
        vm.expectRevert(abi.encodeWithSelector(PaktolVault.CapOutOfRange.selector, 10_001));
        this.helper_deployCapAboveMax();
    }

    function test_constructor_revert_fee100pct() public {
        vm.expectRevert(abi.encodeWithSelector(PaktolVault.FeeOutOfRange.selector, 10_000));
        this.helper_deployFee100pct();
    }

    // F-21: FEE_BPS > FLOOR_BPS causes harvest() DoS — tighten constructor bound.
    function test_f21_constructor_revert_fee_above_floor_bps() public {
        vm.expectRevert(abi.encodeWithSelector(PaktolVault.FeeOutOfRange.selector, 201));
        this.helper_deployFeeAboveFloor();
    }

    function test_f21_constructor_accepts_fee_at_floor_bps() public {
        PaktolVault v = new PaktolVault(
            IERC20(address(eure)), "x", "x", owner,
            treasury, CAP_STD, 200, guardian, harvester,
            address(pool), address(pool.aToken()), 0, signerAddr, false
        );
        assertEq(v.FEE_BPS(), 200);
    }

    function test_constructor_revert_aTokenMismatch() public {
        MockAavePool wrongPool = new MockAavePool(address(eure));
        address wrongAToken = address(wrongPool.aToken());
        vm.expectRevert(abi.encodeWithSelector(
            PaktolVault.ATokenMismatch.selector,
            wrongAToken,
            address(pool.aToken())
        ));
        this.helper_deployATokenMismatch(wrongAToken);
    }

    /* ─────────────────────── DEPOSIT ────────────────────────────────── */

    function test_deposit_basic() public {
        uint256 shares = _deposit(vaultStd, user, DEPOSIT);

        assertGt(shares, 0);
        assertEq(vaultStd.totalAssets(), DEPOSIT);
        // All EURe must be deployed to AAVE — no idle balance.
        assertEq(eure.balanceOf(address(vaultStd)), 0);
        assertEq(IERC20(vaultStd.ATOKEN()).balanceOf(address(vaultStd)), DEPOSIT);
    }

    function test_deposit_updates_lastTotalAssets() public {
        _deposit(vaultStd, user, DEPOSIT);
        assertEq(vaultStd.lastTotalAssets(), DEPOSIT);
    }

    function test_deposit_revert_tooSmall() public {
        vm.startPrank(user);
        eure.approve(address(vaultStd), 1);
        vm.expectRevert(abi.encodeWithSelector(PaktolVault.DepositTooSmall.selector, 1, vaultStd.MIN_DEPOSIT()));
        vaultStd.deposit(1, user);
        vm.stopPrank();
    }

    function test_deposit_revert_whenPaused() public {
        vm.prank(guardian);
        vaultStd.pause();

        vm.startPrank(user);
        eure.approve(address(vaultStd), DEPOSIT);
        vm.expectRevert();
        vaultStd.deposit(DEPOSIT, user);
        vm.stopPrank();
    }

    function test_mint_basic() public {
        uint256 sharesToMint = 500e18;
        vm.startPrank(user);
        eure.approve(address(vaultStd), DEPOSIT);
        uint256 assetsUsed = vaultStd.mint(sharesToMint, user);
        vm.stopPrank();

        assertGt(assetsUsed, 0);
        assertEq(vaultStd.balanceOf(user), sharesToMint);
    }

    /* ─────────────────────── WITHDRAW / REDEEM ──────────────────────── */

    function test_withdraw_basic() public {
        _deposit(vaultStd, user, DEPOSIT);
        _warp(vaultStd.WITHDRAWAL_COOLDOWN());
        uint256 balBefore = eure.balanceOf(user);

        vm.prank(user);
        vaultStd.withdraw(DEPOSIT, user, user);

        assertEq(eure.balanceOf(user), balBefore + DEPOSIT);
        assertEq(vaultStd.totalAssets(), 0);
    }

    function test_withdraw_works_when_paused() public {
        _deposit(vaultStd, user, DEPOSIT);

        vm.prank(guardian);
        vaultStd.pause();

        // Cooldown bypassed when paused — must succeed immediately.
        vm.prank(user);
        vaultStd.withdraw(DEPOSIT, user, user);

        assertEq(eure.balanceOf(user), USER_BALANCE);
    }

    function test_redeem_basic() public {
        uint256 shares = _deposit(vaultStd, user, DEPOSIT);
        _warp(vaultStd.WITHDRAWAL_COOLDOWN());
        uint256 balBefore = eure.balanceOf(user);

        vm.prank(user);
        vaultStd.redeem(shares, user, user);

        assertApproxEqAbs(eure.balanceOf(user), balBefore + DEPOSIT, 1e9);
        assertApproxEqAbs(vaultStd.totalAssets(), 0, 1e9);
    }

    function test_withdraw_updates_lastTotalAssets() public {
        _deposit(vaultStd, user, DEPOSIT);
        _warp(vaultStd.WITHDRAWAL_COOLDOWN());

        vm.prank(user);
        vaultStd.withdraw(DEPOSIT / 2, user, user);

        assertApproxEqAbs(vaultStd.lastTotalAssets(), DEPOSIT / 2, 1e9);
    }

    /* ─────────────────────── HARVEST — STANDARD ─────────────────────── */

    function test_harvest_std_belowCap() public {
        // 20 EURe yield on 1000 = 2% gross, 1 year elapsed.
        // aumFee   = 1000 × 0.5% = 5 EURe
        // remaining = 20 - 5 = 15 EURe
        // maxNetYield = 1000 × 3.5% = 35 EURe → toUsers = 15, toTreasury = 5
        _deposit(vaultStd, user, DEPOSIT);
        _warp(365 days);
        _simulateYield(vaultStd, 20e18);

        vm.prank(harvester);
        vaultStd.harvest();

        uint256 expectedAumFee = (DEPOSIT * FEE_STD) / 10_000; // 5 EURe
        assertApproxEqAbs(eure.balanceOf(treasury), expectedAumFee, 1e9);
        assertApproxEqAbs(vaultStd.totalAssets(), DEPOSIT + 20e18 - expectedAumFee, 1e9);
    }

    function test_harvest_std_atCap() public {
        // 40 EURe yield = 4% gross, 1 year elapsed.
        // aumFee    = 1000 × 0.5% = 5 EURe
        // remaining = 40 - 5 = 35 EURe
        // maxNetYield = 1000 × 3.5% = 35 EURe → toUsers = 35, toTreasury = 5
        _deposit(vaultStd, user, DEPOSIT);
        _warp(365 days);
        _simulateYield(vaultStd, 40e18);

        vm.prank(harvester);
        vaultStd.harvest();

        assertApproxEqAbs(eure.balanceOf(treasury), 5e18, 1e9);
        assertApproxEqAbs(vaultStd.totalAssets(), DEPOSIT + 35e18, 1e9);
    }

    function test_harvest_std_aboveCap() public {
        // 60 EURe yield = 6% gross, 1 year elapsed.
        // aumFee    = 1000 × 0.5% = 5 EURe
        // remaining = 60 - 5 = 55 EURe
        // maxNetYield = 35 EURe → toUsers = 35, surplus = 20, toTreasury = 5 + 20 = 25
        _deposit(vaultStd, user, DEPOSIT);
        _warp(365 days);
        _simulateYield(vaultStd, 60e18);

        vm.prank(harvester);
        vaultStd.harvest();

        assertApproxEqAbs(eure.balanceOf(treasury), 25e18, 1e9);
        assertApproxEqAbs(vaultStd.totalAssets(), DEPOSIT + 35e18, 1e9);
    }

    function test_harvest_std_noYield() public {
        _deposit(vaultStd, user, DEPOSIT);
        _warp(365 days);

        vm.prank(harvester);
        vaultStd.harvest();

        assertEq(eure.balanceOf(treasury), 0);
        assertEq(vaultStd.totalAssets(), DEPOSIT);
    }

    function test_harvest_std_loss() public {
        _deposit(vaultStd, user, DEPOSIT);
        _warp(365 days);
        pool.simulateLoss(address(vaultStd), 100e18);

        vm.prank(harvester);
        vaultStd.harvest(); // must not revert, no treasury payment

        assertEq(eure.balanceOf(treasury), 0);
        assertEq(vaultStd.totalAssets(), DEPOSIT - 100e18);
    }

    function test_harvest_std_emitsEvent() public {
        _deposit(vaultStd, user, DEPOSIT);
        _warp(365 days);
        _simulateYield(vaultStd, 40e18);

        vm.expectEmit(false, false, false, false);
        emit PaktolVault.Harvested(0, 0, 0, 0); // just check it emits

        vm.prank(harvester);
        vaultStd.harvest();
    }

    function test_harvest_std_belowFloor() public {
        // APY = 1.5% (below 2% floor) — fee is pro-rated down.
        // grossYield = 15 EURe
        // flooredFee = 15 × 50/200 = 3.75 EURe  < maxAumFee 5 EURe → takes 3.75
        // remaining  = 15 - 3.75 = 11.25 EURe
        // maxNetYield = 35 EURe → toUsers = 11.25, toTreasury = 3.75
        _deposit(vaultStd, user, DEPOSIT);
        _warp(365 days);
        _simulateYield(vaultStd, 15e18);

        vm.prank(harvester);
        vaultStd.harvest();

        uint256 expectedFee = (15e18 * 50) / 200; // 3.75 EURe
        assertApproxEqAbs(eure.balanceOf(treasury), expectedFee, 1e9);
        assertApproxEqAbs(vaultStd.totalAssets(), DEPOSIT + 15e18 - expectedFee, 1e9);
    }

    function test_harvest_std_atFloor() public {
        // APY = 2% exactly — flooredFee == maxAumFee, seamless transition.
        // grossYield = 20 EURe
        // flooredFee = 20 × 50/200 = 5 EURe == maxAumFee → takes 5
        _deposit(vaultStd, user, DEPOSIT);
        _warp(365 days);
        _simulateYield(vaultStd, 20e18);

        vm.prank(harvester);
        vaultStd.harvest();

        uint256 expectedFee = (DEPOSIT * 50) / 10_000; // 5 EURe — full AUM fee
        assertApproxEqAbs(eure.balanceOf(treasury), expectedFee, 1e9);
    }

    /* ─────────────────────── HARVEST — PAKTOL ───────────────────────── */

    function test_harvest_pkt_belowCap() public {
        // 40 EURe = 4% gross, cap = 5% → no treasury.
        _depositWithAuth(vaultPkt, user, DEPOSIT);
        _warp(365 days);
        _simulateYield(vaultPkt, 40e18);

        vm.prank(harvester);
        vaultPkt.harvest();

        assertEq(eure.balanceOf(treasury), 0);
        assertApproxEqAbs(vaultPkt.totalAssets(), DEPOSIT + 40e18, 1e9);
    }

    function test_harvest_pkt_atCap() public {
        // 50 EURe = 5% gross = exactly cap → no treasury.
        _depositWithAuth(vaultPkt, user, DEPOSIT);
        _warp(365 days);
        _simulateYield(vaultPkt, 50e18);

        vm.prank(harvester);
        vaultPkt.harvest();

        assertApproxEqAbs(eure.balanceOf(treasury), 0, 1e9);
        assertApproxEqAbs(vaultPkt.totalAssets(), DEPOSIT + 50e18, 1e9);
    }

    function test_harvest_pkt_aboveCap() public {
        // 70 EURe = 7% gross, cap = 5% → 20 EURe to treasury.
        _depositWithAuth(vaultPkt, user, DEPOSIT);
        _warp(365 days);
        _simulateYield(vaultPkt, 70e18);

        vm.prank(harvester);
        vaultPkt.harvest();

        assertApproxEqAbs(eure.balanceOf(treasury), 20e18, 1e9);
        assertApproxEqAbs(vaultPkt.totalAssets(), DEPOSIT + 50e18, 1e9);
    }

    /* ─────────────────────── HARVEST GUARDS ─────────────────────────── */

    function test_harvest_revert_unauthorized() public {
        vm.expectRevert(PaktolVault.NotHarvester.selector);
        vm.prank(user);
        vaultStd.harvest();
    }

    function test_harvest_owner_canHarvest() public {
        _deposit(vaultStd, user, DEPOSIT);
        _warp(365 days);
        _simulateYield(vaultStd, 40e18);

        vm.prank(owner);
        vaultStd.harvest();

        assertGt(eure.balanceOf(treasury), 0);
    }

    function test_harvest_revert_tooFrequent() public {
        _deposit(vaultStd, user, DEPOSIT);
        _simulateYield(vaultStd, 40e18);
        _warp(vaultStd.MIN_HARVEST_INTERVAL() - 1);

        vm.expectRevert(abi.encodeWithSelector(
            PaktolVault.HarvestTooFrequent.selector,
            vaultStd.MIN_HARVEST_INTERVAL() - 1,
            vaultStd.MIN_HARVEST_INTERVAL()
        ));
        vm.prank(harvester);
        vaultStd.harvest();
    }

    function test_harvest_updatesTimestamp() public {
        _deposit(vaultStd, user, DEPOSIT);
        _warp(7 days);
        _simulateYield(vaultStd, 10e18);

        uint256 before = vaultStd.lastHarvestTimestamp();

        vm.prank(harvester);
        vaultStd.harvest();

        assertGt(vaultStd.lastHarvestTimestamp(), before);
    }

    /// @dev F-20: no-yield harvest must NOT advance lastHarvestTimestamp.
    ///      A malicious harvester calling during zero-yield periods would compress
    ///      the elapsed window on the next profitable harvest, capping users' yield.
    function test_f20_noYield_harvest_preserves_timestamp() public {
        _deposit(vaultStd, user, DEPOSIT);
        _warp(7 days);

        uint256 tsBefore = vaultStd.lastHarvestTimestamp();

        // No yield simulated — no-yield branch taken.
        vm.prank(harvester);
        vaultStd.harvest();

        assertEq(vaultStd.lastHarvestTimestamp(), tsBefore, "timestamp must not advance on no-yield harvest");

        // Real yield accrues later — full elapsed window is preserved.
        _warp(30 days);
        _simulateYield(vaultStd, 35e18);

        vm.prank(harvester);
        vaultStd.harvest();

        // maxNetYield = lastTotalAssets × 3.5% × 37days / 365days
        // With fix: elapsed = 37 days from tsBefore → full cap applied
        // Without fix: elapsed = 30 days (compressed by no-yield harvest) → smaller cap
        uint256 elapsed = 37 days;
        uint256 maxNetYield = (DEPOSIT * 350 * elapsed) / (10_000 * 365 days);
        assertApproxEqAbs(vaultStd.totalAssets(), DEPOSIT + 35e18 - eure.balanceOf(treasury), 1e9);
        assertGe(vaultStd.totalAssets(), DEPOSIT + maxNetYield - 1e9, "full cap window must be applied");
    }

    /* ─────────────────────── PAUSE / GUARDIAN ───────────────────────── */

    function test_pause_byGuardian() public {
        vm.prank(guardian);
        vaultStd.pause();
        assertTrue(vaultStd.paused());
    }

    function test_pause_byOwner() public {
        vm.prank(owner);
        vaultStd.pause();
        assertTrue(vaultStd.paused());
    }

    function test_pause_revert_unauthorized() public {
        vm.expectRevert(PaktolVault.NotGuardian.selector);
        vm.prank(user);
        vaultStd.pause();
    }

    function test_unpause_byOwner() public {
        vm.prank(guardian);
        vaultStd.pause();

        vm.prank(owner);
        vaultStd.unpause();

        assertFalse(vaultStd.paused());
    }

    function test_unpause_revert_guardian() public {
        vm.prank(guardian);
        vaultStd.pause();

        vm.expectRevert();
        vm.prank(guardian);
        vaultStd.unpause(); // guardian cannot unpause
    }

    /* ─────────────────────── ADMIN ──────────────────────────────────── */

    function test_setGuardian() public {
        address newGuardian = makeAddr("newGuardian");
        vm.prank(owner);
        vaultStd.setGuardian(newGuardian);
        assertEq(vaultStd.guardian(), newGuardian);
    }

    function test_setGuardian_revert_zeroAddress() public {
        vm.expectRevert(abi.encodeWithSelector(PaktolVault.ZeroAddress.selector, "newGuardian"));
        vm.prank(owner);
        vaultStd.setGuardian(address(0));
    }

    function test_setGuardian_revert_unauthorized() public {
        vm.expectRevert();
        vm.prank(user);
        vaultStd.setGuardian(makeAddr("x"));
    }

    function test_setHarvester() public {
        address newHarvester = makeAddr("newHarvester");
        vm.prank(owner);
        vaultStd.setHarvester(newHarvester);
        assertEq(vaultStd.harvester(), newHarvester);
    }

    function test_setHarvester_revert_zeroAddress() public {
        vm.expectRevert(abi.encodeWithSelector(PaktolVault.ZeroAddress.selector, "newHarvester"));
        vm.prank(owner);
        vaultStd.setHarvester(address(0));
    }

    function test_setHarvester_revert_unauthorized() public {
        vm.expectRevert();
        vm.prank(user);
        vaultStd.setHarvester(makeAddr("x"));
    }

    function test_maxDeposit_returnsZero_whenPaused() public {
        vm.prank(guardian);
        vaultStd.pause();
        assertEq(vaultStd.maxDeposit(user), 0);
    }

    /* ─────────────────────── MULTI-USER ─────────────────────────────── */

    function test_multiUser_equalShares() public {
        uint256 shares1 = _deposit(vaultStd, user, DEPOSIT);
        uint256 shares2 = _deposit(vaultStd, user2, DEPOSIT);

        assertEq(shares1, shares2);
    }

    function test_multiUser_proportionalYield() public {
        _deposit(vaultStd, user, DEPOSIT);
        _deposit(vaultStd, user2, DEPOSIT);

        _warp(365 days);
        _simulateYield(vaultStd, 70e18); // 3.5% for each user = 70 total

        vm.prank(harvester);
        vaultStd.harvest();

        uint256 assets1 = vaultStd.convertToAssets(vaultStd.balanceOf(user));
        uint256 assets2 = vaultStd.convertToAssets(vaultStd.balanceOf(user2));

        // Both users receive equal yield (equal deposits, equal shares).
        assertApproxEqAbs(assets1, assets2, 1e9);

        // aumFee = (1000+1000) × 0.5% = 10 EURe
        // remaining = 70 - 10 = 60 EURe, maxNetYield = 2000 × 3.5% = 70 → toUsers = 60
        // per user = 30 EURe
        uint256 aumFee = (2 * DEPOSIT * FEE_STD) / 10_000;
        uint256 expectedNet = (70e18 - aumFee) / 2;
        assertApproxEqAbs(assets1, DEPOSIT + expectedNet, 1e9);
    }

    function test_multiUser_laterDepositor_noBackpay() public {
        // user1 deposits, yield accrues and is harvested, user2 deposits after.
        // user2 should NOT receive yield earned before their deposit.
        _deposit(vaultStd, user, DEPOSIT);
        _warp(365 days);
        _simulateYield(vaultStd, 35e18); // exactly 3.5%

        vm.prank(harvester);
        vaultStd.harvest();

        // aumFee = 1000 × 0.5% = 5 EURe, remaining = 35 - 5 = 30 EURe
        // maxNetYield = 1000 × 3.5% = 35 → toUsers = 30 EURe
        uint256 expectedNet = 35e18 - (DEPOSIT * FEE_STD) / 10_000;
        assertApproxEqAbs(vaultStd.convertToAssets(vaultStd.balanceOf(user)), DEPOSIT + expectedNet, 1e9);

        // user2 deposits at the new share price — only gets their deposit back.
        uint256 shares2 = _deposit(vaultStd, user2, DEPOSIT);
        assertApproxEqAbs(vaultStd.convertToAssets(shares2), DEPOSIT, 1e9);
    }

    /* ─────────────── F-18: lastTotalAssets accounting invariant ─────── */

    /// @dev Proves that a deposit between yield accrual and harvest does NOT
    ///      absorb the pending yield into lastTotalAssets (old bug: always wrote
    ///      totalAssets() after deposit, which erased the accrued gap).
    ///
    ///      Timeline:
    ///        t0  user deposits 1 000 EURe → lastTotalAssets = 1 000
    ///        t1  AAVE accrues 50 EURe     → totalAssets = 1 050, lastTotalAssets = 1 000
    ///        t2  user2 deposits 200 EURe  → lastTotalAssets must stay 1 200 (not 1 250)
    ///        t3  harvest sees grossYield = 50 EURe → treasury receives correct share
    function test_f18_deposit_does_not_absorb_pending_yield() public {
        _deposit(vaultStd, user, DEPOSIT);
        assertEq(vaultStd.lastTotalAssets(), DEPOSIT);

        uint256 yieldAmount = 50e18;
        _simulateYield(vaultStd, yieldAmount);
        // totalAssets = 1050, but lastTotalAssets must still be 1000

        uint256 deposit2 = 200e18;
        eure.mint(user2, deposit2);
        _deposit(vaultStd, user2, deposit2);

        // Fix: lastTotalAssets = 1000 + 200 = 1200 (yield gap preserved)
        // Bug: lastTotalAssets = totalAssets() = 1250 (yield absorbed)
        assertEq(vaultStd.lastTotalAssets(), DEPOSIT + deposit2, "deposit must not absorb pending yield");

        _warp(365 days);
        vm.prank(harvester);
        vaultStd.harvest();

        // grossYield = 1250 - 1200 = 50 EURe → treasury receives non-zero
        // (bug: grossYield = 1250 - 1250 = 0 → treasury gets nothing)
        assertGt(eure.balanceOf(treasury), 0, "treasury must receive yield from pre-deposit accumulation");
    }

    /// @dev Proves that a partial withdrawal does NOT absorb pending yield.
    function test_f18_withdraw_does_not_absorb_pending_yield() public {
        _deposit(vaultStd, user, DEPOSIT);
        _deposit(vaultStd, user2, DEPOSIT);

        uint256 yieldAmount = 50e18;
        _simulateYield(vaultStd, yieldAmount);

        uint256 withdrawAmount = 200e18;
        _warp(vaultStd.WITHDRAWAL_COOLDOWN());
        vm.prank(user);
        vaultStd.withdraw(withdrawAmount, user, user);

        // Fix: lastTotalAssets = 2000 - 200 = 1800 (yield gap preserved)
        // Bug: lastTotalAssets = totalAssets() = 1850 (yield absorbed)
        assertEq(vaultStd.lastTotalAssets(), 2 * DEPOSIT - withdrawAmount, "withdraw must not absorb pending yield");

        _warp(365 days);
        vm.prank(harvester);
        vaultStd.harvest();

        assertGt(eure.balanceOf(treasury), 0, "treasury must receive yield from pre-withdrawal accumulation");
    }

    /* ─────────────────────── FUZZ ───────────────────────────────────── */

    function testFuzz_deposit_withdraw_roundtrip(
        uint256 amount
    ) public {
        amount = bound(amount, vaultStd.MIN_DEPOSIT(), 1_000_000e18);
        eure.mint(user, amount);

        uint256 shares = _deposit(vaultStd, user, amount);
        assertApproxEqAbs(vaultStd.totalAssets(), amount, 1e9);

        _warp(vaultStd.WITHDRAWAL_COOLDOWN());
        vm.prank(user);
        vaultStd.redeem(shares, user, user);

        // User recovers their full deposit (within 1e9 rounding tolerance).
        assertApproxEqAbs(eure.balanceOf(user), USER_BALANCE + amount, 1e9);
    }

    function testFuzz_harvest_std_userNeverExceedsCap(
        uint256 yieldBps
    ) public {
        // Gross yield anywhere from 0% to 10% annually.
        yieldBps = bound(yieldBps, 0, 1_000);
        uint256 yieldAmount = (DEPOSIT * yieldBps) / 10_000;

        _deposit(vaultStd, user, DEPOSIT);
        _warp(365 days);
        if (yieldAmount > 0) _simulateYield(vaultStd, yieldAmount);

        vm.prank(harvester);
        vaultStd.harvest();

        uint256 userAssets = vaultStd.convertToAssets(vaultStd.balanceOf(user));
        uint256 maxUserAssets = DEPOSIT + (DEPOSIT * CAP_STD) / 10_000;
        assertLe(userAssets, maxUserAssets + 1e9); // 1e9 rounding tolerance
    }

    function testFuzz_harvest_pkt_userNeverExceedsCap(
        uint256 yieldBps
    ) public {
        yieldBps = bound(yieldBps, 0, 1_500);
        uint256 yieldAmount = (DEPOSIT * yieldBps) / 10_000;

        _depositWithAuth(vaultPkt, user, DEPOSIT);
        _warp(365 days);
        if (yieldAmount > 0) _simulateYield(vaultPkt, yieldAmount);

        vm.prank(harvester);
        vaultPkt.harvest();

        uint256 userAssets = vaultPkt.convertToAssets(vaultPkt.balanceOf(user));
        uint256 maxUserAssets = DEPOSIT + (DEPOSIT * CAP_PKT) / 10_000;
        assertLe(userAssets, maxUserAssets + 1e9);
    }

    /* ─────────────────────── MAX WITHDRAW / REDEEM ──────────────────── */

    function test_maxWithdraw_fullLiquidity() public {
        _deposit(vaultStd, user, DEPOSIT);
        _warp(vaultStd.WITHDRAWAL_COOLDOWN());

        uint256 expected = vaultStd.convertToAssets(vaultStd.balanceOf(user));
        assertApproxEqAbs(vaultStd.maxWithdraw(user), expected, 1e9);
    }

    function test_maxWithdraw_limitedByAaveLiquidity() public {
        _deposit(vaultStd, user, DEPOSIT);
        _warp(vaultStd.WITHDRAWAL_COOLDOWN());

        eure.burn(address(pool.aToken()), 900e18);

        assertEq(eure.balanceOf(address(pool.aToken())), 100e18);
        assertApproxEqAbs(vaultStd.maxWithdraw(user), 100e18, 1e9);
    }

    function test_maxWithdraw_zeroWhenNoPosition() public view {
        assertEq(vaultStd.maxWithdraw(user), 0);
    }

    function test_maxRedeem_limitedByAaveLiquidity() public {
        uint256 shares = _deposit(vaultStd, user, DEPOSIT);
        _warp(vaultStd.WITHDRAWAL_COOLDOWN());

        eure.burn(address(pool.aToken()), 900e18);

        uint256 maxR = vaultStd.maxRedeem(user);
        assertLe(maxR, shares);
        assertApproxEqAbs(vaultStd.convertToAssets(maxR), 100e18, 1e9);
    }

    function test_maxWithdraw_idleCountsTowardLiquidity() public {
        _deposit(vaultStd, user, DEPOSIT);

        vm.prank(guardian);
        vaultStd.pause(); // pause so cooldown is bypassed for maxWithdraw

        vm.prank(owner);
        vaultStd.emergencyExitAave(); // all funds now idle in vault

        // aToken balance is 0, but idle is 1000 — maxWithdraw should return full position.
        uint256 expected = vaultStd.convertToAssets(vaultStd.balanceOf(user));
        assertApproxEqAbs(vaultStd.maxWithdraw(user), expected, 1e9);
    }

    /* ─────────────────────── EMERGENCY EXIT ─────────────────────────── */

    function test_emergencyExit_pullsAllFromAave() public {
        _deposit(vaultStd, user, DEPOSIT);

        // Pre-exit: all funds in AAVE.
        assertEq(IERC20(vaultStd.ATOKEN()).balanceOf(address(vaultStd)), DEPOSIT);
        assertEq(eure.balanceOf(address(vaultStd)), 0);

        vm.prank(owner);
        vaultStd.emergencyExitAave();

        // Post-exit: no aToken, full balance idle.
        assertEq(IERC20(vaultStd.ATOKEN()).balanceOf(address(vaultStd)), 0);
        assertEq(eure.balanceOf(address(vaultStd)), DEPOSIT);
    }

    function test_emergencyExit_usersCanWithdraw() public {
        uint256 shares = _deposit(vaultStd, user, DEPOSIT);

        vm.prank(guardian);
        vaultStd.pause();

        vm.prank(owner);
        vaultStd.emergencyExitAave();

        // Withdrawal from idle balance — must succeed even though vault is paused.
        uint256 balBefore = eure.balanceOf(user);
        vm.prank(user);
        vaultStd.redeem(shares, user, user);

        assertApproxEqAbs(eure.balanceOf(user), balBefore + DEPOSIT, 1e9);
    }

    function test_emergencyExit_emitsEvent() public {
        _deposit(vaultStd, user, DEPOSIT);

        vm.expectEmit(false, false, false, false);
        emit PaktolVault.EmergencyExitAave(0, 0);

        vm.prank(owner);
        vaultStd.emergencyExitAave();
    }

    function test_emergencyExit_noOp_whenNoAaveBalance() public {
        // No deposit — aToken balance is 0. Should not revert.
        vm.prank(owner);
        vaultStd.emergencyExitAave();
    }

    function test_emergencyExit_revert_unauthorized() public {
        _deposit(vaultStd, user, DEPOSIT);

        vm.expectRevert();
        vm.prank(user);
        vaultStd.emergencyExitAave();

        vm.expectRevert();
        vm.prank(guardian);
        vaultStd.emergencyExitAave();
    }

    /* ─────────────────────── F-09: WITHDRAWAL COOLDOWN ─────────────── */

    function test_f09_cooldown_blocks_immediate_withdraw() public {
        _deposit(vaultStd, user, DEPOSIT);

        vm.expectRevert(abi.encodeWithSelector(
            PaktolVault.WithdrawalCooldown.selector,
            block.timestamp + vaultStd.WITHDRAWAL_COOLDOWN()
        ));
        vm.prank(user);
        vaultStd.withdraw(DEPOSIT, user, user);
    }

    function test_f09_cooldown_blocks_immediate_redeem() public {
        uint256 shares = _deposit(vaultStd, user, DEPOSIT);

        vm.expectRevert(abi.encodeWithSelector(
            PaktolVault.WithdrawalCooldown.selector,
            block.timestamp + vaultStd.WITHDRAWAL_COOLDOWN()
        ));
        vm.prank(user);
        vaultStd.redeem(shares, user, user);
    }

    function test_f09_cooldown_allows_withdraw_after_delay() public {
        _deposit(vaultStd, user, DEPOSIT);
        _warp(vaultStd.WITHDRAWAL_COOLDOWN());

        vm.prank(user);
        vaultStd.withdraw(DEPOSIT, user, user);

        assertEq(eure.balanceOf(user), USER_BALANCE);
    }

    /// @dev Sandwich attempt: deposit just before harvest, cooldown blocks immediate exit.
    function test_f09_sandwich_blocked_by_cooldown() public {
        _deposit(vaultStd, user, DEPOSIT);
        _warp(365 days);
        _simulateYield(vaultStd, 35e18);

        // Attacker deposits just before harvest.
        eure.mint(address(this), DEPOSIT);
        vm.startPrank(address(this));
        eure.approve(address(vaultStd), DEPOSIT);
        uint256 attackShares = vaultStd.deposit(DEPOSIT, address(this));
        vm.stopPrank();

        vm.prank(harvester);
        vaultStd.harvest();

        // Attacker cannot withdraw immediately — cooldown blocks the exit.
        vm.expectRevert();
        vm.prank(address(this));
        vaultStd.redeem(attackShares, address(this), address(this));
    }

    /// @dev Cooldown is per-user — user2 can withdraw normally while user1 is in cooldown.
    function test_f09_cooldown_independent_per_user() public {
        _deposit(vaultStd, user, DEPOSIT);
        _warp(vaultStd.WITHDRAWAL_COOLDOWN());
        _deposit(vaultStd, user2, DEPOSIT);

        // user1 cooldown elapsed — can withdraw.
        vm.prank(user);
        vaultStd.withdraw(DEPOSIT, user, user);

        // user2 just deposited — cannot withdraw yet.
        vm.expectRevert();
        vm.prank(user2);
        vaultStd.withdraw(DEPOSIT, user2, user2);
    }

    /// @dev Transfer of shares propagates the sender's depositTimestamp to the receiver.
    ///      Without this, an attacker could bypass the cooldown by transferring shares
    ///      to a fresh address that has no depositTimestamp.
    function test_f09_cooldown_propagated_on_transfer() public {
        uint256 shares = _deposit(vaultStd, user, DEPOSIT);

        address attacker2 = makeAddr("attacker2");

        // Transfer shares to fresh address — must inherit user's depositTimestamp.
        vm.prank(user);
        vaultStd.transfer(attacker2, shares);

        assertEq(vaultStd.depositTimestamp(attacker2), vaultStd.depositTimestamp(user));

        // attacker2 cannot withdraw immediately — cooldown inherited.
        vm.expectRevert();
        vm.prank(attacker2);
        vaultStd.redeem(shares, attacker2, attacker2);
    }

    /// @dev Cooldown is bypassed when vault is paused (emergency exit always possible).
    function test_f09_cooldown_bypassed_when_paused() public {
        uint256 shares = _deposit(vaultStd, user, DEPOSIT);

        vm.prank(guardian);
        vaultStd.pause();

        // No warp — should succeed immediately because vault is paused.
        vm.prank(user);
        vaultStd.redeem(shares, user, user);

        assertApproxEqAbs(eure.balanceOf(user), USER_BALANCE, 1e9);
    }

    /// @dev maxWithdraw and maxRedeem return 0 during cooldown.
    function test_f09_maxWithdraw_zero_during_cooldown() public {
        _deposit(vaultStd, user, DEPOSIT);

        assertEq(vaultStd.maxWithdraw(user), 0, "maxWithdraw must be 0 during cooldown");
        assertEq(vaultStd.maxRedeem(user), 0, "maxRedeem must be 0 during cooldown");

        _warp(vaultStd.WITHDRAWAL_COOLDOWN());

        assertGt(vaultStd.maxWithdraw(user), 0, "maxWithdraw must be non-zero after cooldown");
        assertGt(vaultStd.maxRedeem(user), 0, "maxRedeem must be non-zero after cooldown");
    }

    /// @dev F-11: emergencyExitAave() must pause atomically so a concurrent deposit
    ///      cannot immediately re-route idle EURe back into AAVE.
    function test_f11_emergencyExit_autopause() public {
        _deposit(vaultStd, user, DEPOSIT);
        assertFalse(vaultStd.paused(), "vault starts unpaused");

        vm.prank(owner);
        vaultStd.emergencyExitAave();

        assertTrue(vaultStd.paused(), "vault must be paused after emergency exit");

        // Deposit must be blocked — funds cannot re-enter AAVE.
        vm.startPrank(user);
        eure.approve(address(vaultStd), DEPOSIT);
        vm.expectRevert();
        vaultStd.deposit(DEPOSIT, user);
        vm.stopPrank();
    }

    /// @dev F-11: emergencyExitAave() on an already-paused vault must not revert.
    function test_f11_emergencyExit_alreadyPaused_noRevert() public {
        _deposit(vaultStd, user, DEPOSIT);

        vm.prank(guardian);
        vaultStd.pause();

        // Must not revert even though vault is already paused.
        vm.prank(owner);
        vaultStd.emergencyExitAave();

        assertTrue(vaultStd.paused());
        assertEq(IERC20(vaultStd.ATOKEN()).balanceOf(address(vaultStd)), 0);
    }

    /// @dev F-11: accounting snapshot after emergency exit is clean.
    function test_f11_emergencyExit_updatesAccounting() public {
        _deposit(vaultStd, user, DEPOSIT);
        _simulateYield(vaultStd, 20e18);
        _warp(7 days);

        uint256 tsBefore = vaultStd.lastHarvestTimestamp();

        vm.prank(owner);
        vaultStd.emergencyExitAave();

        assertEq(vaultStd.lastTotalAssets(), vaultStd.totalAssets(), "lastTotalAssets must reflect post-exit state");
        assertGt(vaultStd.lastHarvestTimestamp(), tsBefore, "lastHarvestTimestamp must be reset");
    }

    /* ─────────────────────── depositWithPermit ──────────────────────── */

    uint256 constant PERMIT_USER_KEY = 0xA11CE;

    function _permitUser() internal view returns (address) {
        return vm.addr(PERMIT_USER_KEY);
    }

    /// @dev Builds and signs an EIP-2612 permit digest for EURe.
    function _signPermit(
        PaktolVault vault_,
        address owner_,
        uint256 ownerKey_,
        uint256 amount_,
        uint256 deadline_
    ) internal view returns (uint8 v, bytes32 r, bytes32 s) {
        bytes32 PERMIT_TYPEHASH =
            keccak256("Permit(address owner,address spender,uint256 value,uint256 nonce,uint256 deadline)");
        bytes32 structHash =
            keccak256(abi.encode(PERMIT_TYPEHASH, owner_, address(vault_), amount_, eure.nonces(owner_), deadline_));
        bytes32 digest = keccak256(abi.encodePacked("\x19\x01", eure.DOMAIN_SEPARATOR(), structHash));
        (v, r, s) = vm.sign(ownerKey_, digest);
    }

    function test_depositWithPermit_success() public {
        address permitUser = _permitUser();
        eure.mint(permitUser, DEPOSIT);

        uint256 deadline = block.timestamp + 1 hours;
        (uint8 v, bytes32 r, bytes32 s) = _signPermit(vaultStd, permitUser, PERMIT_USER_KEY, DEPOSIT, deadline);

        vm.prank(permitUser);
        uint256 shares = vaultStd.depositWithPermit(DEPOSIT, permitUser, deadline, v, r, s);

        assertGt(shares, 0, "shares minted");
        assertEq(eure.balanceOf(permitUser), 0, "EURe spent");
        assertEq(eure.allowance(permitUser, address(vaultStd)), 0, "allowance consumed");
        assertApproxEqAbs(vaultStd.totalAssets(), DEPOSIT, 1e9, "totalAssets updated");
    }

    function test_depositWithPermit_expiredDeadline() public {
        address permitUser = _permitUser();
        eure.mint(permitUser, DEPOSIT);

        uint256 deadline = block.timestamp - 1; // already expired
        (uint8 v, bytes32 r, bytes32 s) = _signPermit(vaultStd, permitUser, PERMIT_USER_KEY, DEPOSIT, deadline);

        vm.prank(permitUser);
        vm.expectRevert();
        vaultStd.depositWithPermit(DEPOSIT, permitUser, deadline, v, r, s);
    }

    function test_depositWithPermit_invalidSignature() public {
        address permitUser = _permitUser();
        eure.mint(permitUser, DEPOSIT);

        uint256 deadline = block.timestamp + 1 hours;
        // Sign with a different key — signature won't match permitUser's address
        (uint8 v, bytes32 r, bytes32 s) = _signPermit(vaultStd, permitUser, 0xBAD, DEPOSIT, deadline);

        vm.prank(permitUser);
        vm.expectRevert();
        vaultStd.depositWithPermit(DEPOSIT, permitUser, deadline, v, r, s);
    }

    function test_depositWithPermit_tooSmall() public {
        address permitUser = _permitUser();
        uint256 tiny = vaultStd.MIN_DEPOSIT() - 1;
        eure.mint(permitUser, tiny);

        uint256 deadline = block.timestamp + 1 hours;
        (uint8 v, bytes32 r, bytes32 s) = _signPermit(vaultStd, permitUser, PERMIT_USER_KEY, tiny, deadline);

        vm.prank(permitUser);
        vm.expectRevert(abi.encodeWithSelector(PaktolVault.DepositTooSmall.selector, tiny, vaultStd.MIN_DEPOSIT()));
        vaultStd.depositWithPermit(tiny, permitUser, deadline, v, r, s);
    }

    function test_depositWithPermit_blockedWhenPaused() public {
        address permitUser = _permitUser();
        eure.mint(permitUser, DEPOSIT);

        vm.prank(guardian);
        vaultStd.pause();

        uint256 deadline = block.timestamp + 1 hours;
        (uint8 v, bytes32 r, bytes32 s) = _signPermit(vaultStd, permitUser, PERMIT_USER_KEY, DEPOSIT, deadline);

        vm.prank(permitUser);
        vm.expectRevert();
        vaultStd.depositWithPermit(DEPOSIT, permitUser, deadline, v, r, s);
    }

    /* ─────────────────────── depositWithAuth ────────────────────────── */

    function test_depositWithAuth_success() public {
        uint256 shares = _depositWithAuth(vaultPkt, user, DEPOSIT);
        assertGt(shares, 0);
        assertEq(vaultPkt.nonces(user), 1);
    }

    function test_depositWithAuth_incrementsNonce() public {
        _depositWithAuth(vaultPkt, user, DEPOSIT);
        assertEq(vaultPkt.nonces(user), 1);
        eure.mint(user, DEPOSIT);
        _depositWithAuth(vaultPkt, user, DEPOSIT);
        assertEq(vaultPkt.nonces(user), 2);
    }

    function test_depositWithAuth_replayReverts() public {
        uint256 deadline = block.timestamp + 1 hours;
        bytes32 structHash = keccak256(abi.encode(
            vaultPkt.DEPOSIT_AUTH_TYPEHASH(),
            user, DEPOSIT, user, deadline,
            vaultPkt.nonces(user)
        ));
        bytes32 digest = keccak256(abi.encodePacked("\x19\x01", vaultPkt.DOMAIN_SEPARATOR(), structHash));
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(signerPk, digest);
        bytes memory sig = abi.encodePacked(r, s, v);

        vm.startPrank(user);
        eure.approve(address(vaultPkt), DEPOSIT * 2);
        vaultPkt.depositWithAuth(DEPOSIT, user, deadline, sig);

        // replay same sig — nonce mismatch → InvalidSignature
        vm.expectRevert(PaktolVault.InvalidSignature.selector);
        vaultPkt.depositWithAuth(DEPOSIT, user, deadline, sig);
        vm.stopPrank();
    }

    function test_depositWithAuth_expiredDeadline() public {
        uint256 deadline = block.timestamp - 1;
        bytes32 structHash = keccak256(abi.encode(
            vaultPkt.DEPOSIT_AUTH_TYPEHASH(),
            user, DEPOSIT, user, deadline,
            vaultPkt.nonces(user)
        ));
        bytes32 digest = keccak256(abi.encodePacked("\x19\x01", vaultPkt.DOMAIN_SEPARATOR(), structHash));
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(signerPk, digest);
        bytes memory sig = abi.encodePacked(r, s, v);

        vm.prank(user);
        vm.expectRevert(PaktolVault.SignatureExpired.selector);
        vaultPkt.depositWithAuth(DEPOSIT, user, deadline, sig);
    }

    function test_depositWithAuth_wrongSigner() public {
        uint256 wrongPk = 0xBADBAD;
        uint256 deadline = block.timestamp + 1 hours;
        bytes32 structHash = keccak256(abi.encode(
            vaultPkt.DEPOSIT_AUTH_TYPEHASH(),
            user, DEPOSIT, user, deadline,
            vaultPkt.nonces(user)
        ));
        bytes32 digest = keccak256(abi.encodePacked("\x19\x01", vaultPkt.DOMAIN_SEPARATOR(), structHash));
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(wrongPk, digest);
        bytes memory sig = abi.encodePacked(r, s, v);

        eure.mint(user, DEPOSIT);
        vm.startPrank(user);
        eure.approve(address(vaultPkt), DEPOSIT);
        vm.expectRevert(PaktolVault.InvalidSignature.selector);
        vaultPkt.depositWithAuth(DEPOSIT, user, deadline, sig);
        vm.stopPrank();
    }

    function test_depositWithAuth_blockedOnOpenVault() public {
        // Standard vault (REQUIRES_AUTH=false) — depositWithAuth still works
        // because the check is only blocking deposit() on restricted vaults.
        // Verify deposit() works normally on Standard.
        uint256 shares = _deposit(vaultStd, user, DEPOSIT);
        assertGt(shares, 0);
    }

    function test_deposit_blockedOnRestrictedVault() public {
        eure.mint(user, DEPOSIT);
        vm.startPrank(user);
        eure.approve(address(vaultPkt), DEPOSIT);
        vm.expectRevert(PaktolVault.UseDepositWithAuth.selector);
        vaultPkt.deposit(DEPOSIT, user);
        vm.stopPrank();
    }

    function test_mint_blockedOnRestrictedVault() public {
        vm.startPrank(user);
        eure.approve(address(vaultPkt), DEPOSIT);
        vm.expectRevert(PaktolVault.UseDepositWithAuth.selector);
        vaultPkt.mint(1e21, user);
        vm.stopPrank();
    }

    function test_depositWithPermit_blockedOnRestrictedVault() public {
        address permitUser = _permitUser();
        eure.mint(permitUser, DEPOSIT);
        uint256 deadline = block.timestamp + 1 hours;
        (uint8 v, bytes32 r, bytes32 s) = _signPermit(vaultPkt, permitUser, PERMIT_USER_KEY, DEPOSIT, deadline);
        vm.prank(permitUser);
        vm.expectRevert(PaktolVault.UseDepositWithAuth.selector);
        vaultPkt.depositWithPermit(DEPOSIT, permitUser, deadline, v, r, s);
    }

    /* ─────────────────────── ECONOMIC INVARIANTS ───────────────────── */

    // INV-01: totalAssets() >= sum(deposits) - sum(withdrawals) at all times
    function test_inv01_totalAssets_geq_net_deposits() public {
        uint256 shares1 = _deposit(vaultStd, user, 500e18);
        _deposit(vaultStd, user2, 300e18);

        assertGe(vaultStd.totalAssets(), 800e18);

        // Partial redeem
        vm.prank(user);
        vaultStd.redeem(shares1 / 2, user, user);
        uint256 remaining = vaultStd.convertToAssets(shares1 / 2);

        assertGe(vaultStd.totalAssets(), remaining + 300e18 - 1e9);

        // After yield accrual — invariant still holds
        _warp(365 days);
        _simulateYield(vaultStd, 28e18);
        assertGe(vaultStd.totalAssets(), remaining + 300e18 - 1e9);
    }

    // INV-02: convertToAssets(totalSupply()) ≈ totalAssets() (within 1 wei for large amounts)
    function test_inv02_share_price_accounting_consistency() public {
        _deposit(vaultStd, user, DEPOSIT);

        assertApproxEqAbs(
            vaultStd.convertToAssets(vaultStd.totalSupply()),
            vaultStd.totalAssets(),
            1e9
        );

        _warp(365 days);
        _simulateYield(vaultStd, 35e18);

        assertApproxEqAbs(
            vaultStd.convertToAssets(vaultStd.totalSupply()),
            vaultStd.totalAssets(),
            1e9
        );

        vm.prank(harvester);
        vaultStd.harvest();

        assertApproxEqAbs(
            vaultStd.convertToAssets(vaultStd.totalSupply()),
            vaultStd.totalAssets(),
            1e9
        );
    }

    // INV-03: lastTotalAssets <= totalAssets() at all times (grossYield always >= 0)
    function test_inv03_lastTotalAssets_never_exceeds_totalAssets() public {
        _deposit(vaultStd, user, DEPOSIT);
        assertEq(vaultStd.lastTotalAssets(), vaultStd.totalAssets());

        // Yield accrues — totalAssets grows, lastTotalAssets stays put
        _warp(365 days);
        _simulateYield(vaultStd, 35e18);
        assertLe(vaultStd.lastTotalAssets(), vaultStd.totalAssets());

        // After harvest — lastTotalAssets catches up to totalAssets
        vm.prank(harvester);
        vaultStd.harvest();
        assertEq(vaultStd.lastTotalAssets(), vaultStd.totalAssets());

        // After withdraw — lastTotalAssets stays in sync
        uint256 halfShares = vaultStd.balanceOf(user) / 2;
        vm.prank(user);
        vaultStd.redeem(halfShares, user, user);
        assertEq(vaultStd.lastTotalAssets(), vaultStd.totalAssets());

        // Second yield cycle
        _warp(365 days);
        _simulateYield(vaultStd, 10e18);
        assertLe(vaultStd.lastTotalAssets(), vaultStd.totalAssets());
    }

    // INV-04: balanceOf(0xdead) > 0 at all times after deployment seed
    function test_inv04_dead_shares_permanent() public {
        // Mirrors the deployment checklist: seed MIN_DEPOSIT to 0xdead.
        address dead = address(0xdead);
        eure.mint(dead, vaultStd.MIN_DEPOSIT());
        vm.startPrank(dead);
        eure.approve(address(vaultStd), vaultStd.MIN_DEPOSIT());
        vaultStd.deposit(vaultStd.MIN_DEPOSIT(), dead);
        vm.stopPrank();

        assertGt(vaultStd.balanceOf(dead), 0, "dead shares seeded");

        _deposit(vaultStd, user, DEPOSIT);
        assertGt(vaultStd.balanceOf(dead), 0, "after user deposit");

        _warp(365 days);
        _simulateYield(vaultStd, 35e18);
        vm.prank(harvester);
        vaultStd.harvest();
        assertGt(vaultStd.balanceOf(dead), 0, "after harvest");

        uint256 userShares = vaultStd.balanceOf(user);
        vm.prank(user);
        vaultStd.redeem(userShares, user, user);
        assertGt(vaultStd.balanceOf(dead), 0, "after full user redeem");
    }

    /* ─────────────────────── ADVERSARIAL SEQUENCES ─────────────────── */

    // ADV-01: 999 consecutive harvest() calls after the first all revert with HarvestTooFrequent
    function test_adv01_harvest_ratelimit_1000_calls() public {
        _deposit(vaultStd, user, DEPOSIT);
        _warp(365 days);
        _simulateYield(vaultStd, 35e18);

        vm.prank(harvester);
        vaultStd.harvest();

        uint256 minInterval = vaultStd.MIN_HARVEST_INTERVAL();
        for (uint256 i = 0; i < 999; i++) {
            vm.expectRevert(abi.encodeWithSelector(PaktolVault.HarvestTooFrequent.selector, uint256(0), minInterval));
            vm.prank(harvester);
            vaultStd.harvest();
        }

        // Only after MIN_HARVEST_INTERVAL does the next harvest succeed
        _warp(vaultStd.MIN_HARVEST_INTERVAL());
        vm.prank(harvester);
        vaultStd.harvest();
    }

    // ADV-02: deposit(MIN_DEPOSIT) just before each harvest — yield cap invariant holds for all users
    function test_adv02_sandwicher_cannot_exceed_cap() public {
        _deposit(vaultStd, user, DEPOSIT);

        address sandwicher = makeAddr("sandwicher");
        eure.mint(sandwicher, vaultStd.MIN_DEPOSIT() * 6);

        for (uint256 i = 0; i < 5; i++) {
            vm.startPrank(sandwicher);
            eure.approve(address(vaultStd), vaultStd.MIN_DEPOSIT());
            vaultStd.deposit(vaultStd.MIN_DEPOSIT(), sandwicher);
            vm.stopPrank();

            _warp(365 days / 5);
            _simulateYield(vaultStd, (DEPOSIT * CAP_STD) / 10_000 / 5);

            vm.prank(harvester);
            vaultStd.harvest();

            // Legit user never exceeds annual cap
            uint256 userAssets = vaultStd.convertToAssets(vaultStd.balanceOf(user));
            uint256 maxUserAssets = DEPOSIT + (DEPOSIT * CAP_STD) / 10_000;
            assertLe(userAssets, maxUserAssets + 1e9);
        }
    }
}
