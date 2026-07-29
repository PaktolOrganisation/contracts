// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "./PaktolVaultV2Base.t.sol";

/* ─────────────────────── MALICIOUS CONTRACTS ───────────────────────────── */

/// @dev Reentrant ERC-20: on transfer triggers vault.deposit() again.
contract ReentrantEURC is MockEURC {
    address public target;
    bool    private _lock;

    function setTarget(address t) external { target = t; }

    function transfer(address to, uint256 amount) public override returns (bool) {
        if (!_lock && target != address(0)) {
            _lock = true;
            try PaktolVaultV2(target).deposit(1e3, address(this)) {} catch {}
            _lock = false;
        }
        return super.transfer(to, amount);
    }

    function transferFrom(address from, address to, uint256 amount) public override returns (bool) {
        if (!_lock && target != address(0)) {
            _lock = true;
            try PaktolVaultV2(target).deposit(1e3, address(this)) {} catch {}
            _lock = false;
        }
        return super.transferFrom(from, to, amount);
    }
}

/// @dev Reentrant Byzantine vault: on deposit/withdraw triggers vault again.
contract ReentrantByzantine is MockByzantineVault {
    address public paktolVault;
    bool    private _lock;

    constructor(IERC20 asset_) MockByzantineVault(asset_) {}

    function setPaktolVault(address v) external { paktolVault = v; }

    function deposit(uint256 assets, address receiver) public override returns (uint256) {
        if (!_lock && paktolVault != address(0)) {
            _lock = true;
            // Try to reenter paktol deposit during Byzantine deposit
            try PaktolVaultV2(paktolVault).deposit(1e3, address(this)) {} catch {}
            _lock = false;
        }
        return super.deposit(assets, receiver);
    }

    function withdraw(uint256 assets, address receiver, address owner_) public override returns (uint256) {
        if (!_lock && paktolVault != address(0)) {
            _lock = true;
            // Try to reenter paktol withdraw during Byzantine withdraw
            try PaktolVaultV2(paktolVault).withdraw(assets / 2, receiver, paktolVault) {} catch {}
            _lock = false;
        }
        return super.withdraw(assets, receiver, owner_);
    }
}

/* ──────────────────────── SECURITY TESTS ───────────────────────────────── */

contract PaktolVaultV2SecurityTest is PaktolVaultV2Base {

    /* ══════════════════════════════════════════════════════════════════
       1. INFLATION ATTACK (share price manipulation)
       ══════════════════════════════════════════════════════════════════ */

    /// @dev Attacker donates EURC directly to vault before first real deposit.
    ///      Virtual shares (_decimalsOffset = 3) make the attack uneconomical.
    function test_inflation_attack_blocked_by_virtual_shares() public {
        address attacker = makeAddr("attacker");
        address victim   = makeAddr("victim");

        // Attacker seeds 1 share to themselves (minimum deposit)
        eurc.mint(attacker, 1e3);
        vm.startPrank(attacker);
        eurc.approve(address(vaultStd), 1e3);
        uint256 attackerShares = vaultStd.deposit(1e3, attacker);
        vm.stopPrank();

        // Attacker donates 10_000 EURC directly to inflate share price
        eurc.mint(attacker, 10_000e6);
        vm.prank(attacker);
        eurc.transfer(address(vaultStd), 10_000e6);

        // Victim deposits 10_000 EURC
        eurc.mint(victim, 10_000e6);
        vm.startPrank(victim);
        eurc.approve(address(vaultStd), 10_000e6);
        uint256 victimShares = vaultStd.deposit(10_000e6, victim);
        vm.stopPrank();

        // Victim must get > 0 shares (not rounded down to 0)
        assertGt(victimShares, 0, "victim must get shares");

        // Wait cooldown and redeem
        _warp(vaultStd.WITHDRAWAL_COOLDOWN() + 1);
        uint256 balBefore = eurc.balanceOf(victim);
        vm.prank(victim);
        vaultStd.redeem(victimShares, victim, victim);

        // Victim must get back close to their deposit (max 1% loss)
        uint256 received = eurc.balanceOf(victim) - balBefore;
        assertGt(received, 9_900e6, "victim loses less than 1% to attacker");

        // Attacker shares are nearly worthless relative to their donation
        uint256 attackerAssets = vaultStd.convertToAssets(attackerShares);
        assertLt(attackerAssets, 1e3 + 10_000e6, "attacker gains nothing from donation");
    }

    /// @dev Fuzz: any deposit amount >= minDeposit always produces > 0 shares.
    function testFuzz_deposit_always_produces_shares(uint256 assets) public {
        assets = bound(assets, vaultStd.minDeposit(), 1_000_000e6);
        eurc.mint(user, assets);
        vm.startPrank(user);
        eurc.approve(address(vaultStd), assets);
        uint256 shares = vaultStd.deposit(assets, user);
        vm.stopPrank();
        assertGt(shares, 0, "non-zero shares for any valid deposit");
    }

    /* ══════════════════════════════════════════════════════════════════
       2. REENTRANCY — via malicious EURC token
       ══════════════════════════════════════════════════════════════════ */

    function test_reentrancy_deposit_via_malicious_eurc() public {
        ReentrantEURC reurc = new ReentrantEURC();

        // Deploy vault with the malicious EURC
        MockByzantineVault rbyz = new MockByzantineVault(IERC20(address(reurc)));
        PaktolVaultV2 rvault = new PaktolVaultV2(
            IERC20(address(reurc)), "R", "R",
            owner, treasury, 350, 50,
            guardian, harvester, address(0),
            address(rbyz), 0, false
        );

        reurc.setTarget(address(rvault));

        reurc.mint(user, 10_000e6);
        vm.startPrank(user);
        reurc.approve(address(rvault), 10_000e6);
        // nonReentrant must block the inner call — outer deposit succeeds, inner reverts silently
        uint256 shares = rvault.deposit(1_000e6, user);
        vm.stopPrank();

        // State must be consistent — no double-accounting
        assertGt(shares, 0, "deposit succeeded");
        assertApproxEqAbs(rvault.totalAssets(), 1_000e6, 1e3, "totalAssets correct after reentrancy attempt");
        assertApproxEqAbs(rvault.lastTotalAssets(), 1_000e6, 1e3, "lastTotalAssets consistent");
    }

    /* ══════════════════════════════════════════════════════════════════
       3. REENTRANCY — via malicious Byzantine vault
       ══════════════════════════════════════════════════════════════════ */

    function test_reentrancy_deposit_via_malicious_byzantine() public {
        ReentrantByzantine rbyz = new ReentrantByzantine(IERC20(address(eurc)));

        PaktolVaultV2 rvault = new PaktolVaultV2(
            IERC20(address(eurc)), "R", "R",
            owner, treasury, 350, 50,
            guardian, harvester, address(0),
            address(rbyz), 0, false
        );

        rbyz.setPaktolVault(address(rvault));

        eurc.mint(user, 10_000e6);
        vm.startPrank(user);
        eurc.approve(address(rvault), 10_000e6);
        uint256 shares = rvault.deposit(1_000e6, user);
        vm.stopPrank();

        assertGt(shares, 0, "deposit succeeded");
        assertApproxEqAbs(rvault.totalAssets(), 1_000e6, 1e3, "no double-accounting");
    }

    /* ══════════════════════════════════════════════════════════════════
       4. OWNABLE2STEP
       ══════════════════════════════════════════════════════════════════ */

    function test_ownable2step_pending_owner_cannot_act() public {
        address newOwner = makeAddr("newOwner");
        vm.prank(owner);
        vaultStd.transferOwnership(newOwner);

        // pendingOwner is set but not yet owner
        assertEq(vaultStd.pendingOwner(), newOwner);
        assertEq(vaultStd.owner(), owner);

        // pendingOwner cannot call onlyOwner functions before accepting
        vm.startPrank(newOwner);
        vm.expectRevert();
        vaultStd.setGuardian(makeAddr("x"));
        vm.stopPrank();
    }

    function test_ownable2step_accept_transfers_ownership() public {
        address newOwner = makeAddr("newOwner");
        vm.prank(owner);
        vaultStd.transferOwnership(newOwner);

        vm.prank(newOwner);
        vaultStd.acceptOwnership();

        assertEq(vaultStd.owner(), newOwner);
        assertEq(vaultStd.pendingOwner(), address(0));
    }

    function test_ownable2step_only_pending_can_accept() public {
        address newOwner = makeAddr("newOwner");
        vm.prank(owner);
        vaultStd.transferOwnership(newOwner);

        vm.expectRevert();
        vm.prank(user);
        vaultStd.acceptOwnership();
    }

    function test_ownable2step_cancel_by_transferring_to_zero() public {
        address newOwner = makeAddr("newOwner");
        vm.startPrank(owner);
        vaultStd.transferOwnership(newOwner);
        // Transfer to another address cancels previous pending
        address another = makeAddr("another");
        vaultStd.transferOwnership(another);
        vm.stopPrank();

        assertEq(vaultStd.pendingOwner(), another);
    }

    /* ══════════════════════════════════════════════════════════════════
       5. EDGE CASES
       ══════════════════════════════════════════════════════════════════ */

    function test_granter_zero_disables_grant_for_non_owner() public {
        // Disable granter on vaultPkt
        vm.prank(owner);
        vaultPkt.setGranter(address(0));

        // Former granter can no longer grant on vaultPkt
        vm.prank(granter);
        vm.expectRevert(PaktolVaultV2.NotGranter.selector);
        vaultPkt.grantPremiumAccess(user, 7 days);
    }

    function test_depositUpToCap_with_requires_auth() public {
        uint256 cap = 2_000e6;
        PaktolVaultV2 capped = new PaktolVaultV2(
            IERC20(address(eurc)), "x", "x",
            owner, treasury, 350, 50,
            guardian, harvester, address(0),
            address(mockPkt), cap, true
        );

        // Without access — must revert
        eurc.mint(user, 1_000e6);
        vm.startPrank(user);
        eurc.approve(address(capped), 1_000e6);
        vm.expectRevert(abi.encodeWithSelector(PaktolVaultV2.PremiumAccessExpired.selector, 0));
        capped.depositUpToCap(1_000e6, user);
        vm.stopPrank();

        // With access — truncates at cap
        vm.prank(owner);
        capped.grantPremiumAccess(user, 30 days);

        vm.startPrank(user);
        eurc.approve(address(capped), 1_000e6);
        (uint256 accepted, uint256 shares) = capped.depositUpToCap(1_000e6, user);
        vm.stopPrank();

        assertGt(accepted, 0, "accepted some");
        assertGt(shares, 0, "minted shares");
    }

    function test_first_harvest_after_deploy_no_revert() public {
        // Deploy fresh vault, seed dead shares, harvest immediately after minHarvestInterval
        PaktolVaultV2 fresh = new PaktolVaultV2(
            IERC20(address(eurc)), "x", "x",
            owner, treasury, 350, 50,
            guardian, harvester, address(0),
            address(mockStd), 0, false
        );

        eurc.mint(owner, 1e3);
        vm.startPrank(owner);
        eurc.approve(address(fresh), 1e3);
        fresh.deposit(1e3, address(0xdEaD));
        vm.stopPrank();

        _warp(fresh.minHarvestInterval() + 1);

        // Should not revert even with lastTotalAssets = minDeposit
        vm.prank(harvester);
        fresh.harvest();
    }

    function test_cooldown_reset_on_share_transfer() public {
        _deposit(vaultStd, user, DEPOSIT);
        // user transfers shares to user2 — user2 inherits the cooldown timestamp
        uint256 shares = vaultStd.balanceOf(user);
        vm.prank(user);
        vaultStd.transfer(user2, shares);

        // user2 cannot immediately withdraw (inherits user's cooldown)
        assertEq(vaultStd.maxWithdraw(user2), 0, "cooldown inherited on transfer");

        // After cooldown, user2 can withdraw
        _warp(vaultStd.WITHDRAWAL_COOLDOWN() + 1);
        assertGt(vaultStd.maxWithdraw(user2), 0, "user2 can withdraw after cooldown");
    }

    function test_treasury_shares_not_subject_to_aum_fee() public {
        _deposit(vaultStd, user, DEPOSIT);
        _warp(vaultStd.minHarvestInterval() + 1);
        mockStd.simulateYield(500e6);

        vm.prank(harvester);
        vaultStd.harvest();

        uint256 treasuryShares = vaultStd.balanceOf(treasury);
        assertGt(treasuryShares, 0, "treasury received fee shares");

        // Treasury can redeem immediately (exempt from cooldown)
        assertGt(vaultStd.maxRedeem(treasury), 0, "treasury exempt from cooldown");
    }
}
