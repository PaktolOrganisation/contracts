// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "forge-std/Test.sol";
import "@openzeppelin/contracts/token/ERC20/extensions/ERC4626.sol";
import "@openzeppelin/contracts/token/ERC20/extensions/ERC20Permit.sol";
import "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import "../src/PaktolVaultV2.sol";

/* ─────────────────────────────── MOCKS ─────────────────────────────────── */

contract MockEURC is ERC20Permit {
    constructor() ERC20("Mock EURC", "mEURC") ERC20Permit("Mock EURC") {}
    function decimals() public pure override returns (uint8) { return 6; }
    function mint(address to, uint256 amount) external { _mint(to, amount); }
    function burn(address from, uint256 amount) external { _burn(from, amount); }
}

/// @dev Minimal ERC-4626. simulateYield mints, simulateLoss burns, setLiquidityCap
///      limits maxWithdraw to model Morpho liquidity constraints.
contract MockByzantineVault is ERC4626 {
    uint256 private _liquidityCap = type(uint256).max;

    constructor(IERC20 asset_) ERC4626(asset_) ERC20("Mock Byzantine", "mBZY") {}

    function simulateYield(uint256 amount) external {
        MockEURC(asset()).mint(address(this), amount);
    }

    function simulateLoss(uint256 amount) external {
        MockEURC(asset()).burn(address(this), amount);
    }

    function setLiquidityCap(uint256 cap) external {
        _liquidityCap = cap;
    }

    function maxWithdraw(address owner_) public view override returns (uint256) {
        uint256 full = super.maxWithdraw(owner_);
        return full < _liquidityCap ? full : _liquidityCap;
    }
}

/* ─────────────────────────────── TESTS ─────────────────────────────────── */

contract PaktolVaultV2Test is Test {
    MockEURC             internal eurc;
    MockByzantineVault   internal mockStd;
    MockByzantineVault   internal mockPkt;
    PaktolVaultV2        internal vaultStd;  // Standard — FEE 0.5%, CAP 3.5%, open
    PaktolVaultV2        internal vaultPkt;  // Premium  — FEE 0.5%, CAP 5%,   auth-gated

    address internal owner     = makeAddr("owner");
    address internal treasury  = makeAddr("treasury");
    address internal guardian  = makeAddr("guardian");
    address internal harvester = makeAddr("harvester");
    address internal user      = makeAddr("user");
    address internal user2     = makeAddr("user2");

    uint256 internal constant SIGNER_KEY     = 0xB4C4E3D;
    uint256 internal constant PERMIT_USER_KEY = 0xA11CE;
    address internal signer;

    uint256 constant CAP_STD = 350;
    uint256 constant CAP_PKT = 500;
    uint256 constant FEE_STD = 50;
    uint256 constant FEE_PKT = 50;

    uint256 constant DEPOSIT      = 1_000e6;   // 1 000 EURC (6 dec)
    uint256 constant USER_BALANCE = 10_000e6;

    /* ─────────────────────────── SETUP ─────────────────────────────── */

    function setUp() public {
        signer  = vm.addr(SIGNER_KEY);
        eurc    = new MockEURC();
        mockStd = new MockByzantineVault(IERC20(address(eurc)));
        mockPkt = new MockByzantineVault(IERC20(address(eurc)));

        vaultStd = new PaktolVaultV2(
            IERC20(address(eurc)), "Paktol Standard", "pkEURC-S",
            owner, treasury, CAP_STD, FEE_STD, guardian, harvester,
            address(mockStd), 0, signer, false
        );
        vaultPkt = new PaktolVaultV2(
            IERC20(address(eurc)), "Paktol Subscription", "pkEURC-P",
            owner, treasury, CAP_PKT, FEE_PKT, guardian, harvester,
            address(mockPkt), 0, signer, true
        );

        eurc.mint(user,  USER_BALANCE);
        eurc.mint(user2, USER_BALANCE);
    }

    /* ─────────────────────────── HELPERS ───────────────────────────── */

    function _warp(uint256 delta) internal { vm.warp(block.timestamp + delta); }

    function _deposit(PaktolVaultV2 vault_, address who, uint256 amount) internal returns (uint256 shares) {
        eurc.mint(who, amount);
        vm.startPrank(who);
        eurc.approve(address(vault_), amount);
        shares = vault_.deposit(amount, who);
        vm.stopPrank();
    }

    function _depositWithAuth(
        PaktolVaultV2 vault_,
        address who,
        uint256 amount
    ) internal returns (uint256 shares) {
        uint256 deadline = block.timestamp + 1 hours;
        bytes32 structHash = keccak256(abi.encode(
            vault_.DEPOSIT_AUTH_TYPEHASH(),
            who, amount, who, deadline,
            vault_.nonces(who)
        ));
        bytes32 digest = keccak256(abi.encodePacked("\x19\x01", vault_.DOMAIN_SEPARATOR(), structHash));
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(SIGNER_KEY, digest);
        bytes memory sig = abi.encodePacked(r, s, v);

        eurc.mint(who, amount);
        vm.startPrank(who);
        eurc.approve(address(vault_), amount);
        shares = vault_.depositWithAuth(amount, who, deadline, sig);
        vm.stopPrank();
    }

    function _signPermit(
        address spender_,
        address owner_,
        uint256 ownerKey_,
        uint256 amount_,
        uint256 deadline_
    ) internal view returns (uint8 v, bytes32 r, bytes32 s) {
        bytes32 PERMIT_TYPEHASH =
            keccak256("Permit(address owner,address spender,uint256 value,uint256 nonce,uint256 deadline)");
        bytes32 structHash =
            keccak256(abi.encode(PERMIT_TYPEHASH, owner_, spender_, amount_, eurc.nonces(owner_), deadline_));
        bytes32 digest = keccak256(abi.encodePacked("\x19\x01", eurc.DOMAIN_SEPARATOR(), structHash));
        (v, r, s) = vm.sign(ownerKey_, digest);
    }

    /* ─────────────────────── CONSTRUCTOR ───────────────────────────── */

    function test_constructor_immutables() public view {
        assertEq(vaultStd.CAP_BPS(),   CAP_STD);
        assertEq(vaultStd.FEE_BPS(),   FEE_STD);
        assertEq(vaultStd.TREASURY(),  treasury);
        assertEq(address(vaultStd.BYZANTINE_VAULT()), address(mockStd));
        assertEq(vaultStd.guardian(),  guardian);
        assertEq(vaultStd.harvester(), harvester);
        assertEq(vaultStd.SIGNER(),    signer);
        assertFalse(vaultStd.REQUIRES_AUTH());

        assertEq(vaultPkt.CAP_BPS(), CAP_PKT);
        assertEq(vaultPkt.FEE_BPS(), FEE_PKT);
        assertTrue(vaultPkt.REQUIRES_AUTH());
    }

    function test_constructor_revert_zeroAsset() public {
        vm.expectRevert(abi.encodeWithSelector(PaktolVaultV2.ZeroAddress.selector, "asset"));
        new PaktolVaultV2(
            IERC20(address(0)), "x", "x", owner, treasury, CAP_STD, FEE_STD,
            guardian, harvester, address(mockStd), 0, signer, false
        );
    }

    function test_constructor_revert_zeroTreasury() public {
        vm.expectRevert(abi.encodeWithSelector(PaktolVaultV2.ZeroAddress.selector, "treasury"));
        new PaktolVaultV2(
            IERC20(address(eurc)), "x", "x", owner, address(0), CAP_STD, FEE_STD,
            guardian, harvester, address(mockStd), 0, signer, false
        );
    }

    function test_constructor_revert_zeroByzantineVault() public {
        vm.expectRevert(abi.encodeWithSelector(PaktolVaultV2.ZeroAddress.selector, "byzantineVault"));
        new PaktolVaultV2(
            IERC20(address(eurc)), "x", "x", owner, treasury, CAP_STD, FEE_STD,
            guardian, harvester, address(0), 0, signer, false
        );
    }

    function test_constructor_revert_assetMismatch() public {
        MockEURC other = new MockEURC();
        vm.expectRevert(abi.encodeWithSelector(
            PaktolVaultV2.ByzantineVaultAssetMismatch.selector,
            address(eurc),   // mockStd.asset()
            address(other)   // expected by PaktolVaultV2
        ));
        new PaktolVaultV2(
            IERC20(address(other)), "x", "x", owner, treasury, CAP_STD, FEE_STD,
            guardian, harvester, address(mockStd), 0, signer, false
        );
    }

    function test_constructor_revert_capZero() public {
        vm.expectRevert(abi.encodeWithSelector(PaktolVaultV2.CapOutOfRange.selector, 0));
        new PaktolVaultV2(
            IERC20(address(eurc)), "x", "x", owner, treasury, 0, FEE_STD,
            guardian, harvester, address(mockStd), 0, signer, false
        );
    }

    function test_constructor_revert_capAboveMax() public {
        vm.expectRevert(abi.encodeWithSelector(PaktolVaultV2.CapOutOfRange.selector, 10_001));
        new PaktolVaultV2(
            IERC20(address(eurc)), "x", "x", owner, treasury, 10_001, FEE_STD,
            guardian, harvester, address(mockStd), 0, signer, false
        );
    }

    function test_constructor_revert_fee100pct() public {
        vm.expectRevert(abi.encodeWithSelector(PaktolVaultV2.FeeOutOfRange.selector, 10_000));
        new PaktolVaultV2(
            IERC20(address(eurc)), "x", "x", owner, treasury, CAP_STD, 10_000,
            guardian, harvester, address(mockStd), 0, signer, false
        );
    }

    // F-21: FEE_BPS > FLOOR_BPS causes harvest() DoS — tighten constructor bound.
    function test_f21_constructor_revert_fee_above_floor_bps() public {
        vm.expectRevert(abi.encodeWithSelector(PaktolVaultV2.FeeOutOfRange.selector, 201));
        new PaktolVaultV2(
            IERC20(address(eurc)), "x", "x", owner, treasury, CAP_STD, 201,
            guardian, harvester, address(mockStd), 0, signer, false
        );
    }

    function test_f21_constructor_accepts_fee_at_floor_bps() public {
        PaktolVaultV2 v = new PaktolVaultV2(
            IERC20(address(eurc)), "x", "x", owner, treasury, CAP_STD, 200,
            guardian, harvester, address(mockStd), 0, signer, false
        );
        assertEq(v.FEE_BPS(), 200);
    }

    // F-14: role separation enforced in constructor.
    function test_f14_constructor_revert_ownerEqualsGuardian() public {
        vm.expectRevert(PaktolVaultV2.RolesNotSeparated.selector);
        new PaktolVaultV2(
            IERC20(address(eurc)), "x", "x", owner, treasury, CAP_STD, FEE_STD,
            owner, harvester, address(mockStd), 0, signer, false
        );
    }

    function test_f14_constructor_revert_ownerEqualsHarvester() public {
        vm.expectRevert(PaktolVaultV2.RolesNotSeparated.selector);
        new PaktolVaultV2(
            IERC20(address(eurc)), "x", "x", owner, treasury, CAP_STD, FEE_STD,
            guardian, owner, address(mockStd), 0, signer, false
        );
    }

    function test_f14_constructor_revert_guardianEqualsHarvester() public {
        vm.expectRevert(PaktolVaultV2.RolesNotSeparated.selector);
        new PaktolVaultV2(
            IERC20(address(eurc)), "x", "x", owner, treasury, CAP_STD, FEE_STD,
            guardian, guardian, address(mockStd), 0, signer, false
        );
    }

    /* ───────────────────── DEPOSIT → BYZANTINE ROUTING ─────────────── */

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
        uint256 tiny = vaultStd.MIN_DEPOSIT() - 1;
        eurc.mint(user, tiny);
        vm.startPrank(user);
        eurc.approve(address(vaultStd), tiny);
        vm.expectRevert(abi.encodeWithSelector(PaktolVaultV2.DepositTooSmall.selector, tiny, vaultStd.MIN_DEPOSIT()));
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
            guardian, harvester, address(mockStd), 2_000e6, signer, false
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
            guardian, harvester, address(mockStd), cap, signer, false
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
            guardian, harvester, address(mockStd), cap, signer, false
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
            guardian, harvester, address(mockStd), cap, signer, false
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

    /* ────────────────────────── MINT ───────────────────────────────── */

    function test_mint_basic() public {
        uint256 sharesToMint = 500e9; // 500 share-units (shares have 9 effective decimals)
        vm.startPrank(user);
        eurc.approve(address(vaultStd), DEPOSIT);
        uint256 assetsUsed = vaultStd.mint(sharesToMint, user);
        vm.stopPrank();

        assertGt(assetsUsed, 0);
        assertEq(vaultStd.balanceOf(user), sharesToMint);
        assertEq(eurc.balanceOf(address(vaultStd)), 0, "no idle EURC after mint");
    }

    /* ────────────────────── WITHDRAW / REDEEM ──────────────────────── */

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

        // Cooldown bypassed when paused — must succeed immediately.
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

    /* ─────────────── HARVEST — STANDARD (exact math) ───────────────── */

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
        assertApproxEqAbs(eurc.balanceOf(treasury), expectedFee, 1e3);
        assertApproxEqAbs(vaultStd.totalAssets(), DEPOSIT + 20e6 - expectedFee, 1e3);
    }

    function test_harvest_std_atCap() public {
        // 40 EURC yield = 4% gross. aumFee = 5, remaining = 35 = maxNetYield → toTreasury = 5
        _deposit(vaultStd, user, DEPOSIT);
        _warp(365 days);
        mockStd.simulateYield(40e6);

        vm.prank(harvester);
        vaultStd.harvest();

        assertApproxEqAbs(eurc.balanceOf(treasury), 5e6, 1e3);
        assertApproxEqAbs(vaultStd.totalAssets(), DEPOSIT + 35e6, 1e3);
    }

    function test_harvest_std_aboveCap() public {
        // 60 EURC yield = 6% gross.
        // aumFee = 5, remaining = 55, maxNetYield = 35 → toUsers = 35, toTreasury = 25
        _deposit(vaultStd, user, DEPOSIT);
        _warp(365 days);
        mockStd.simulateYield(60e6);

        vm.prank(harvester);
        vaultStd.harvest();

        assertApproxEqAbs(eurc.balanceOf(treasury), 25e6, 1e3);
        assertApproxEqAbs(vaultStd.totalAssets(), DEPOSIT + 35e6, 1e3);
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
        assertApproxEqAbs(eurc.balanceOf(treasury), expectedFee, 1e3);
        assertApproxEqAbs(vaultStd.totalAssets(), DEPOSIT + 15e6 - expectedFee, 1e3);
    }

    function test_harvest_std_atFloor() public {
        // APY = 2% exactly — flooredFee == maxAumFee, seamless transition.
        _deposit(vaultStd, user, DEPOSIT);
        _warp(365 days);
        mockStd.simulateYield(20e6);

        vm.prank(harvester);
        vaultStd.harvest();

        uint256 expectedFee = (DEPOSIT * FEE_STD) / 10_000; // 5 EURC
        assertApproxEqAbs(eurc.balanceOf(treasury), expectedFee, 1e3);
    }

    /* ──────────────────── HARVEST — PREMIUM (FEE=0.5%) ────────────────── */

    function test_harvest_pkt_belowCap() public {
        // 40 EURC = 4% gross, AUM fee = 5e6, remaining = 35e6 < cap(50e6) → toUsers=35e6, toTreasury=5e6
        _depositWithAuth(vaultPkt, user, DEPOSIT);
        _warp(365 days);
        mockPkt.simulateYield(40e6);

        vm.prank(harvester);
        vaultPkt.harvest();

        assertApproxEqAbs(eurc.balanceOf(treasury), 5e6, 1e3);
        assertApproxEqAbs(vaultPkt.totalAssets(), DEPOSIT + 35e6, 1e3);
    }

    function test_harvest_pkt_atCap() public {
        // 50 EURC = 5% gross, AUM fee = 5e6, remaining = 45e6 < cap(50e6) → toUsers=45e6, toTreasury=5e6
        _depositWithAuth(vaultPkt, user, DEPOSIT);
        _warp(365 days);
        mockPkt.simulateYield(50e6);

        vm.prank(harvester);
        vaultPkt.harvest();

        assertApproxEqAbs(eurc.balanceOf(treasury), 5e6, 1e3);
        assertApproxEqAbs(vaultPkt.totalAssets(), DEPOSIT + 45e6, 1e3);
    }

    function test_harvest_pkt_aboveCap() public {
        // 70 EURC = 7% gross, AUM fee = 5e6, remaining = 65e6 > cap(50e6) → toUsers=50e6, toTreasury=20e6
        _depositWithAuth(vaultPkt, user, DEPOSIT);
        _warp(365 days);
        mockPkt.simulateYield(70e6);

        vm.prank(harvester);
        vaultPkt.harvest();

        assertApproxEqAbs(eurc.balanceOf(treasury), 20e6, 1e3);
        assertApproxEqAbs(vaultPkt.totalAssets(), DEPOSIT + 50e6, 1e3);
    }

    /* ─────────────────────── HARVEST GUARDS ────────────────────────── */

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

        assertGt(eurc.balanceOf(treasury), 0);
    }

    function test_harvest_revert_tooFrequent() public {
        _deposit(vaultStd, user, DEPOSIT);
        mockStd.simulateYield(40e6);
        _warp(vaultStd.MIN_HARVEST_INTERVAL() - 1);

        vm.expectRevert(abi.encodeWithSelector(
            PaktolVaultV2.HarvestTooFrequent.selector,
            vaultStd.MIN_HARVEST_INTERVAL() - 1,
            vaultStd.MIN_HARVEST_INTERVAL()
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
        // totalAssets = 1050, lastTotalAssets must still be 1000

        uint256 deposit2 = 200e6;
        _deposit(vaultStd, user2, deposit2);

        // Fix: lastTotalAssets = 1000 + 200 = 1200 (yield gap preserved)
        // Bug: lastTotalAssets = totalAssets() = 1250 (yield absorbed)
        assertEq(vaultStd.lastTotalAssets(), DEPOSIT + deposit2, "deposit must not absorb pending yield");

        _warp(365 days);
        vm.prank(harvester);
        vaultStd.harvest();

        assertGt(eurc.balanceOf(treasury), 0, "treasury must receive yield from pre-deposit accumulation");
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

        assertGt(eurc.balanceOf(treasury), 0, "treasury must receive yield from pre-withdrawal accumulation");
    }

    /* ───────────────────────── FUZZ ────────────────────────────────── */

    function testFuzz_deposit_withdraw_roundtrip(uint256 amount) public {
        amount = bound(amount, vaultStd.MIN_DEPOSIT(), 1_000_000e6);
        // _deposit mints internally — no extra mint needed here.

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

        _depositWithAuth(vaultPkt, user, DEPOSIT);
        _warp(365 days);
        if (yieldAmount > 0) mockPkt.simulateYield(yieldAmount);

        vm.prank(harvester);
        vaultPkt.harvest();

        uint256 userAssets    = vaultPkt.convertToAssets(vaultPkt.balanceOf(user));
        uint256 maxUserAssets = DEPOSIT + (DEPOSIT * CAP_PKT) / 10_000;
        assertLe(userAssets, maxUserAssets + 1e3);
    }

    /* ─────────────────── MULTI-USER ────────────────────────────────── */

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

    function test_maxWithdraw_limitedByByzantineLiquidity() public {
        _deposit(vaultStd, user, DEPOSIT);
        _warp(vaultStd.WITHDRAWAL_COOLDOWN());

        mockStd.setLiquidityCap(100e6);

        assertApproxEqAbs(vaultStd.maxWithdraw(user), 100e6, 1e3);
    }

    function test_maxWithdraw_zeroWhenNoPosition() public view {
        assertEq(vaultStd.maxWithdraw(user), 0);
    }

    function test_maxRedeem_limitedByByzantineLiquidity() public {
        uint256 shares = _deposit(vaultStd, user, DEPOSIT);
        _warp(vaultStd.WITHDRAWAL_COOLDOWN());

        mockStd.setLiquidityCap(100e6);

        uint256 maxR = vaultStd.maxRedeem(user);
        assertLe(maxR, shares);
        assertApproxEqAbs(vaultStd.convertToAssets(maxR), 100e6, 1e3);
    }

    function test_maxWithdraw_idleCountsTowardLiquidity() public {
        _deposit(vaultStd, user, DEPOSIT);

        vm.prank(guardian);
        vaultStd.pause();

        vm.prank(owner);
        vaultStd.emergencyExitByzantine();

        // All funds now idle — maxWithdraw should return full position.
        uint256 expected = vaultStd.convertToAssets(vaultStd.balanceOf(user));
        assertApproxEqAbs(vaultStd.maxWithdraw(user), expected, 1e3);
    }

    function test_maxDeposit_returnsZero_whenPaused() public {
        vm.prank(guardian);
        vaultStd.pause();
        assertEq(vaultStd.maxDeposit(user), 0);
    }

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

        assertEq(vaultStd.lastTotalAssets(), vaultStd.totalAssets(), "lastTotalAssets must reflect post-exit state");
        assertGt(vaultStd.lastHarvestTimestamp(), tsBefore, "lastHarvestTimestamp must be reset");
    }

    /* ─────────────── F-09: WITHDRAWAL COOLDOWN ─────────────────────── */

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

    function test_f09_cooldown_bypassed_when_paused() public {
        uint256 shares = _deposit(vaultStd, user, DEPOSIT);

        vm.prank(guardian);
        vaultStd.pause();

        uint256 balBefore = eurc.balanceOf(user);
        vm.prank(user);
        vaultStd.redeem(shares, user, user);

        assertApproxEqAbs(eurc.balanceOf(user), balBefore + DEPOSIT, 1e3);
    }

    function test_f09_maxWithdraw_zero_during_cooldown() public {
        _deposit(vaultStd, user, DEPOSIT);

        assertEq(vaultStd.maxWithdraw(user), 0, "maxWithdraw must be 0 during cooldown");
        assertEq(vaultStd.maxRedeem(user),   0, "maxRedeem must be 0 during cooldown");

        _warp(vaultStd.WITHDRAWAL_COOLDOWN());

        assertGt(vaultStd.maxWithdraw(user), 0);
        assertGt(vaultStd.maxRedeem(user),   0);
    }

    /* ─────────────────── PAUSE / GUARDIAN ──────────────────────────── */

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
        vm.expectRevert(PaktolVaultV2.NotGuardian.selector);
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
        vaultStd.unpause();
    }

    /* ───────────────────────── ADMIN ───────────────────────────────── */

    function test_setGuardian() public {
        address newGuardian = makeAddr("newGuardian");
        vm.prank(owner);
        vaultStd.setGuardian(newGuardian);
        assertEq(vaultStd.guardian(), newGuardian);
    }

    function test_setGuardian_revert_zeroAddress() public {
        vm.expectRevert(abi.encodeWithSelector(PaktolVaultV2.ZeroAddress.selector, "newGuardian"));
        vm.prank(owner);
        vaultStd.setGuardian(address(0));
    }

    function test_setGuardian_revert_unauthorized() public {
        vm.expectRevert();
        vm.prank(user);
        vaultStd.setGuardian(makeAddr("x"));
    }

    // F-14: role separation in setGuardian / setHarvester.
    function test_f14_setGuardian_revert_equalsOwner() public {
        vm.expectRevert(PaktolVaultV2.RolesNotSeparated.selector);
        vm.prank(owner);
        vaultStd.setGuardian(owner);
    }

    function test_f14_setGuardian_revert_equalsHarvester() public {
        vm.expectRevert(PaktolVaultV2.RolesNotSeparated.selector);
        vm.prank(owner);
        vaultStd.setGuardian(harvester);
    }

    function test_setHarvester() public {
        address newHarvester = makeAddr("newHarvester");
        vm.prank(owner);
        vaultStd.setHarvester(newHarvester);
        assertEq(vaultStd.harvester(), newHarvester);
    }

    function test_setHarvester_revert_zeroAddress() public {
        vm.expectRevert(abi.encodeWithSelector(PaktolVaultV2.ZeroAddress.selector, "newHarvester"));
        vm.prank(owner);
        vaultStd.setHarvester(address(0));
    }

    function test_setHarvester_revert_unauthorized() public {
        vm.expectRevert();
        vm.prank(user);
        vaultStd.setHarvester(makeAddr("x"));
    }

    function test_f14_setHarvester_revert_equalsOwner() public {
        vm.expectRevert(PaktolVaultV2.RolesNotSeparated.selector);
        vm.prank(owner);
        vaultStd.setHarvester(owner);
    }

    function test_f14_setHarvester_revert_equalsGuardian() public {
        vm.expectRevert(PaktolVaultV2.RolesNotSeparated.selector);
        vm.prank(owner);
        vaultStd.setHarvester(guardian);
    }

    /* ───────────────────── depositWithPermit ───────────────────────── */

    address internal permitUser = vm.addr(PERMIT_USER_KEY);

    function test_depositWithPermit_success() public {
        eurc.mint(permitUser, DEPOSIT);

        uint256 deadline = block.timestamp + 1 hours;
        (uint8 v, bytes32 r, bytes32 s) = _signPermit(address(vaultStd), permitUser, PERMIT_USER_KEY, DEPOSIT, deadline);

        vm.prank(permitUser);
        uint256 shares = vaultStd.depositWithPermit(DEPOSIT, permitUser, deadline, v, r, s);

        assertGt(shares, 0);
        assertEq(eurc.balanceOf(permitUser), 0, "EURC spent");
        assertApproxEqAbs(vaultStd.totalAssets(), DEPOSIT, 1e3);
    }

    function test_depositWithPermit_expiredDeadline() public {
        eurc.mint(permitUser, DEPOSIT);
        uint256 deadline = block.timestamp - 1;
        (uint8 v, bytes32 r, bytes32 s) = _signPermit(address(vaultStd), permitUser, PERMIT_USER_KEY, DEPOSIT, deadline);

        vm.prank(permitUser);
        vm.expectRevert();
        vaultStd.depositWithPermit(DEPOSIT, permitUser, deadline, v, r, s);
    }

    function test_depositWithPermit_invalidSignature() public {
        eurc.mint(permitUser, DEPOSIT);
        uint256 deadline = block.timestamp + 1 hours;
        (uint8 v, bytes32 r, bytes32 s) = _signPermit(address(vaultStd), permitUser, 0xBAD, DEPOSIT, deadline);

        vm.prank(permitUser);
        vm.expectRevert();
        vaultStd.depositWithPermit(DEPOSIT, permitUser, deadline, v, r, s);
    }

    function test_depositWithPermit_tooSmall() public {
        uint256 tiny = vaultStd.MIN_DEPOSIT() - 1;
        eurc.mint(permitUser, tiny);
        uint256 deadline = block.timestamp + 1 hours;
        (uint8 v, bytes32 r, bytes32 s) = _signPermit(address(vaultStd), permitUser, PERMIT_USER_KEY, tiny, deadline);

        vm.prank(permitUser);
        vm.expectRevert(abi.encodeWithSelector(PaktolVaultV2.DepositTooSmall.selector, tiny, vaultStd.MIN_DEPOSIT()));
        vaultStd.depositWithPermit(tiny, permitUser, deadline, v, r, s);
    }

    function test_depositWithPermit_blockedWhenPaused() public {
        eurc.mint(permitUser, DEPOSIT);
        vm.prank(guardian);
        vaultStd.pause();

        uint256 deadline = block.timestamp + 1 hours;
        (uint8 v, bytes32 r, bytes32 s) = _signPermit(address(vaultStd), permitUser, PERMIT_USER_KEY, DEPOSIT, deadline);

        vm.prank(permitUser);
        vm.expectRevert();
        vaultStd.depositWithPermit(DEPOSIT, permitUser, deadline, v, r, s);
    }

    function test_depositWithPermit_blockedOnRestrictedVault() public {
        eurc.mint(permitUser, DEPOSIT);
        uint256 deadline = block.timestamp + 1 hours;
        (uint8 v, bytes32 r, bytes32 s) = _signPermit(address(vaultPkt), permitUser, PERMIT_USER_KEY, DEPOSIT, deadline);

        vm.prank(permitUser);
        vm.expectRevert(PaktolVaultV2.UseDepositWithAuth.selector);
        vaultPkt.depositWithPermit(DEPOSIT, permitUser, deadline, v, r, s);
    }

    /* ───────────────── depositWithPermit — F-13 ────────────────────── */

    /// @dev F-13: invalid permit + NO pre-existing allowance must revert.
    function test_f13_invalidPermit_withoutAllowance_reverts() public {
        eurc.mint(permitUser, DEPOSIT);

        uint256 deadline = block.timestamp + 1 hours;
        (uint8 v, bytes32 r, bytes32 s) = _signPermit(address(vaultStd), permitUser, 0xBAD, DEPOSIT, deadline);

        vm.prank(permitUser);
        vm.expectRevert(PaktolVaultV2.InsufficientAllowance.selector);
        vaultStd.depositWithPermit(DEPOSIT, permitUser, deadline, v, r, s);
    }

    /// @dev F-13: expired permit + NO pre-existing allowance must revert.
    function test_f13_expiredPermit_withoutAllowance_reverts() public {
        eurc.mint(permitUser, DEPOSIT);

        uint256 deadline = block.timestamp - 1;
        (uint8 v, bytes32 r, bytes32 s) = _signPermit(address(vaultStd), permitUser, PERMIT_USER_KEY, DEPOSIT, deadline);

        vm.prank(permitUser);
        vm.expectRevert(PaktolVaultV2.InsufficientAllowance.selector);
        vaultStd.depositWithPermit(DEPOSIT, permitUser, deadline, v, r, s);
    }

    /// @dev F-13: sufficient pre-existing allowance skips permit entirely — deposit succeeds
    ///      even with garbage permit params. Documented acceptable behavior: if the user
    ///      already approved enough, permit is irrelevant.
    function test_f13_sufficientAllowance_skipsPermit_succeeds() public {
        eurc.mint(permitUser, DEPOSIT);

        vm.prank(permitUser);
        eurc.approve(address(vaultStd), DEPOSIT);

        // Garbage permit params are ignored since allowance is already sufficient
        vm.prank(permitUser);
        uint256 shares = vaultStd.depositWithPermit(DEPOSIT, permitUser, 0, 0, bytes32(0), bytes32(0));

        assertGt(shares, 0);
    }

    /// @dev F-13: nonce check — permit front-ran (nonce consumed externally) then deposit
    ///      with that same permit must still work via residual allowance set by front-runner.
    function test_f13_frontRunPermit_depositsViaResidualAllowance() public {
        eurc.mint(permitUser, DEPOSIT);

        uint256 deadline = block.timestamp + 1 hours;
        (uint8 v, bytes32 r, bytes32 s) = _signPermit(address(vaultStd), permitUser, PERMIT_USER_KEY, DEPOSIT, deadline);

        // Front-runner consumes the permit (sets allowance to vault)
        vm.prank(address(0xBEEF));
        IERC20Permit(address(eurc)).permit(permitUser, address(vaultStd), DEPOSIT, deadline, v, r, s);

        // Original depositWithPermit call: permit fails (nonce consumed) but allowance exists
        vm.prank(permitUser);
        uint256 shares = vaultStd.depositWithPermit(DEPOSIT, permitUser, deadline, v, r, s);

        assertGt(shares, 0, "should succeed via residual allowance from front-runner");
    }

    /* ─────────────────────── depositWithAuth ───────────────────────── */

    function test_depositWithAuth_success() public {
        uint256 shares = _depositWithAuth(vaultPkt, user, DEPOSIT);
        assertGt(shares, 0);
        assertEq(vaultPkt.nonces(user), 1);
    }

    function test_depositWithAuth_incrementsNonce() public {
        _depositWithAuth(vaultPkt, user, DEPOSIT);
        assertEq(vaultPkt.nonces(user), 1);
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
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(SIGNER_KEY, digest);
        bytes memory sig = abi.encodePacked(r, s, v);

        eurc.mint(user, DEPOSIT * 2);
        vm.startPrank(user);
        eurc.approve(address(vaultPkt), DEPOSIT * 2);
        vaultPkt.depositWithAuth(DEPOSIT, user, deadline, sig);
        vm.expectRevert(PaktolVaultV2.InvalidSignature.selector);
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
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(SIGNER_KEY, digest);
        bytes memory sig = abi.encodePacked(r, s, v);

        vm.prank(user);
        vm.expectRevert(PaktolVaultV2.SignatureExpired.selector);
        vaultPkt.depositWithAuth(DEPOSIT, user, deadline, sig);
    }

    function test_depositWithAuth_wrongSigner() public {
        uint256 wrongKey = 0xBADBAD;
        uint256 deadline = block.timestamp + 1 hours;
        bytes32 structHash = keccak256(abi.encode(
            vaultPkt.DEPOSIT_AUTH_TYPEHASH(),
            user, DEPOSIT, user, deadline,
            vaultPkt.nonces(user)
        ));
        bytes32 digest = keccak256(abi.encodePacked("\x19\x01", vaultPkt.DOMAIN_SEPARATOR(), structHash));
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(wrongKey, digest);
        bytes memory sig = abi.encodePacked(r, s, v);

        eurc.mint(user, DEPOSIT);
        vm.startPrank(user);
        eurc.approve(address(vaultPkt), DEPOSIT);
        vm.expectRevert(PaktolVaultV2.InvalidSignature.selector);
        vaultPkt.depositWithAuth(DEPOSIT, user, deadline, sig);
        vm.stopPrank();
    }

    function test_deposit_blockedOnRestrictedVault() public {
        vm.startPrank(user);
        eurc.approve(address(vaultPkt), DEPOSIT);
        vm.expectRevert(PaktolVaultV2.UseDepositWithAuth.selector);
        vaultPkt.deposit(DEPOSIT, user);
        vm.stopPrank();
    }

    function test_mint_blockedOnRestrictedVault() public {
        vm.startPrank(user);
        eurc.approve(address(vaultPkt), DEPOSIT);
        vm.expectRevert(PaktolVaultV2.UseDepositWithAuth.selector);
        vaultPkt.mint(1e9, user);
        vm.stopPrank();
    }

    /* ─────────────── totalAssets reflects Byzantine yield ──────────── */

    function test_totalAssets_reflectsYield() public {
        _deposit(vaultStd, user, DEPOSIT);
        uint256 before = vaultStd.totalAssets();

        mockStd.simulateYield(500e6);

        assertGt(vaultStd.totalAssets(), before);
    }
}
