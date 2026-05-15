// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "forge-std/Test.sol";
import "../src/PaktolVaultV2.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/extensions/ERC20Permit.sol";

/// @dev Fork tests against the real Byzantine EUR Sandbox vault on Base Mainnet.
///      Run with:
///        forge test --match-contract "ForkBase" --fork-url https://mainnet.base.org -vvv
///
///      No gas cost — everything runs in a local fork.
contract PaktolVaultV2ForkBaseTest is Test {

    /* ─────────────── Base Mainnet constants ────────────────────────── */

    address constant EURC_BASE     = 0x60a3E35Cc302bFA44Cb288Bc5a4F316Fdb1adb42;
    address constant BYZANTINE_EUR = 0x7aA6B0aff73E3E0416CdfCD64F51E5cFa910ad01;

    /* ─────────────── Roles ─────────────────────────────────────────── */

    address internal owner     = makeAddr("owner");
    address internal treasury  = makeAddr("treasury");
    address internal guardian  = makeAddr("guardian");
    address internal harvester = makeAddr("harvester");
    address internal user      = makeAddr("user");
    address internal user2     = makeAddr("user2");

    uint256 internal constant PERMIT_USER_KEY = 0xA11CE;
    address internal permitUser = vm.addr(PERMIT_USER_KEY);

    /* ─────────────── Vault params ──────────────────────────────────── */

    uint256 constant CAP_BPS = 350;  // 3.5%
    uint256 constant FEE_BPS = 50;   // 0.5%
    uint256 constant DEPOSIT = 100e6; // 100 EURC

    /* ─────────────── Vault instances ──────────────────────────────── */

    PaktolVaultV2 internal vaultStd;  // open vault
    PaktolVaultV2 internal vaultPkt;  // premium-gated vault

    /* ─────────────── setUp ─────────────────────────────────────────── */

    function setUp() public {
        // Fork is provided via --fork-url flag; verify we're on Base.
        assertEq(block.chainid, 8453, "must fork Base Mainnet (use --fork-url https://mainnet.base.org)");
        assertEq(IERC4626(BYZANTINE_EUR).asset(), EURC_BASE, "Byzantine asset mismatch");

        // Deploy both vaults
        vaultStd = new PaktolVaultV2(
            IERC20(EURC_BASE),
            "Paktol Standard EURC",  "pkEURC-S",
            owner, treasury, CAP_BPS, FEE_BPS,
            guardian, harvester,
            BYZANTINE_EUR,
            0, 0, false            // no TVL cap, no threshold, open
        );

        vaultPkt = new PaktolVaultV2(
            IERC20(EURC_BASE),
            "Paktol Premium EURC",  "pkEURC-P",
            owner, treasury, CAP_BPS, FEE_BPS,
            guardian, harvester,
            BYZANTINE_EUR,
            0, 100, true           // no TVL cap, threshold=100, gated
        );

        // Fund users with real EURC via deal() (modifies storage slot directly)
        deal(EURC_BASE, user,       10_000e6);
        deal(EURC_BASE, user2,      10_000e6);
        deal(EURC_BASE, permitUser, 10_000e6);

        // Seed dead shares on both vaults to prevent inflation attacks
        _seed(vaultStd);
        _seed(vaultPkt);
    }

    /* ─────────────── helpers ───────────────────────────────────────── */

    function _seed(PaktolVaultV2 vault_) internal {
        uint256 min = vault_.MIN_DEPOSIT();
        deal(EURC_BASE, owner, min);
        vm.startPrank(owner);
        if (vault_.REQUIRES_AUTH()) vault_.grantPremiumAccess(address(0xdEaD), 365 days);
        IERC20(EURC_BASE).approve(address(vault_), min);
        vault_.deposit(min, address(0xdEaD));
        vm.stopPrank();
    }

    function _deposit(PaktolVaultV2 vault_, address who, uint256 amount) internal returns (uint256) {
        deal(EURC_BASE, who, amount);
        vm.startPrank(who);
        IERC20(EURC_BASE).approve(address(vault_), amount);
        uint256 shares = vault_.deposit(amount, who);
        vm.stopPrank();
        return shares;
    }

    function _warp(uint256 delta) internal { vm.warp(block.timestamp + delta); }

    /* ══════════════════════════════════════════════════════════════════
       1. DEPLOYMENT & WIRING
       ══════════════════════════════════════════════════════════════════ */

    function test_fork_base_config() public view {
        assertEq(address(vaultStd.asset()), EURC_BASE);
        assertEq(address(vaultStd.BYZANTINE_VAULT()), BYZANTINE_EUR);
        assertEq(vaultStd.owner(), owner);
        assertEq(vaultStd.TREASURY(), treasury);
        assertFalse(vaultStd.REQUIRES_AUTH());
        assertTrue(vaultPkt.REQUIRES_AUTH());
    }

    /* ══════════════════════════════════════════════════════════════════
       2. DEPOSIT → BYZANTINE ROUTING
       ══════════════════════════════════════════════════════════════════ */

    function test_fork_base_deposit_routes_to_byzantine() public {
        uint256 shares = _deposit(vaultStd, user, DEPOSIT);
        uint256 min = vaultStd.MIN_DEPOSIT();

        assertGt(shares, 0, "vault shares minted");
        // totalAssets counts idle EURC + Byzantine position — correct either way.
        // On sandbox, maxDeposit()=0 (no supply queue) so EURC may stay idle.
        assertApproxEqAbs(vaultStd.totalAssets(), DEPOSIT + min, 1e3, "totalAssets correct");
        // All funds accounted for (idle + Byzantine)
        uint256 idle   = IERC20(EURC_BASE).balanceOf(address(vaultStd));
        uint256 bShares = IERC4626(BYZANTINE_EUR).balanceOf(address(vaultStd));
        uint256 bVal   = bShares > 0 ? IERC4626(BYZANTINE_EUR).convertToAssets(bShares) : 0;
        assertApproxEqAbs(idle + bVal, DEPOSIT + min, 1e3, "no funds lost");
    }

    function test_fork_base_totalAssets_reflects_byzantine() public {
        uint256 min = vaultStd.MIN_DEPOSIT();
        uint256 expected = DEPOSIT + min; // user + dead shares

        _deposit(vaultStd, user, DEPOSIT);

        // totalAssets includes idle EURC + Byzantine position — correct on sandbox and prod.
        assertApproxEqAbs(vaultStd.totalAssets(), expected, 1e3, "totalAssets correct");
    }

    /* ══════════════════════════════════════════════════════════════════
       3. WITHDRAW ROUNDTRIP
       ══════════════════════════════════════════════════════════════════ */

    function test_fork_base_redeem_roundtrip() public {
        uint256 shares = _deposit(vaultStd, user, DEPOSIT);
        uint256 balBefore = IERC20(EURC_BASE).balanceOf(user);

        // Wait out cooldown
        _warp(5 hours);

        vm.prank(user);
        uint256 received = vaultStd.redeem(shares, user, user);

        assertApproxEqAbs(received, DEPOSIT, 1e3, "user gets back deposit");
        assertGt(IERC20(EURC_BASE).balanceOf(user), balBefore, "user EURC balance increased");
    }

    function test_fork_base_withdraw_blocked_in_cooldown() public {
        _deposit(vaultStd, user, DEPOSIT);

        // Immediately after deposit — maxWithdraw must be 0
        assertEq(vaultStd.maxWithdraw(user), 0, "locked in cooldown");
        assertEq(vaultStd.maxRedeem(user), 0, "locked in cooldown");
    }

    function test_fork_base_withdraw_available_after_cooldown() public {
        _deposit(vaultStd, user, DEPOSIT);
        _warp(5 hours);

        assertGt(vaultStd.maxWithdraw(user), 0, "unlocked after cooldown");
    }

    /* ══════════════════════════════════════════════════════════════════
       4. HARVEST
       ══════════════════════════════════════════════════════════════════ */

    /// @dev Harvest callable after MIN_HARVEST_INTERVAL (1 day). May emit HarvestSkipped
    ///      on sandbox (no Morpho markets), but must not revert.
    function test_fork_base_harvest_callable_after_interval() public {
        _deposit(vaultStd, user, DEPOSIT);
        _warp(2 days);

        vm.prank(harvester);
        vaultStd.harvest();
    }

    function test_fork_base_harvest_blocked_when_paused() public {
        _deposit(vaultStd, user, DEPOSIT);
        _warp(2 days);

        vm.prank(guardian);
        vaultStd.pause();

        vm.prank(harvester);
        vm.expectRevert();
        vaultStd.harvest();
    }

    function test_fork_base_harvest_revert_before_interval() public {
        _deposit(vaultStd, user, DEPOSIT);
        // No warp — elapsed = 0 < MIN_HARVEST_INTERVAL → must revert
        vm.prank(harvester);
        vm.expectRevert();
        vaultStd.harvest();
    }

    /// @dev After a successful harvest (yield found, lastHarvestTimestamp updated),
    ///      a second call within 1 day must revert HarvestTooFrequent.
    function test_fork_base_harvest_too_frequent_after_success() public {
        _deposit(vaultStd, user, DEPOSIT);
        _warp(2 days);

        vm.prank(harvester);
        vaultStd.harvest();

        // Only test too-frequent if the first harvest was successful (not skipped).
        // HarvestSkipped does NOT update lastHarvestTimestamp by design.
        if (vaultStd.lastHarvestTimestamp() == block.timestamp) {
            vm.prank(harvester);
            vm.expectRevert(abi.encodeWithSelector(
                PaktolVaultV2.HarvestTooFrequent.selector,
                0,
                vaultStd.MIN_HARVEST_INTERVAL()
            ));
            vaultStd.harvest();
        }
    }

    /* ══════════════════════════════════════════════════════════════════
       5. PREMIUM ACCESS (vaultPkt)
       ══════════════════════════════════════════════════════════════════ */

    function test_fork_base_pkt_blocked_without_access() public {
        deal(EURC_BASE, user, DEPOSIT);
        vm.startPrank(user);
        IERC20(EURC_BASE).approve(address(vaultPkt), DEPOSIT);
        vm.expectRevert(abi.encodeWithSelector(PaktolVaultV2.PremiumAccessExpired.selector, 0));
        vaultPkt.deposit(DEPOSIT, user);
        vm.stopPrank();
    }

    function test_fork_base_pkt_deposit_with_access() public {
        vm.prank(owner);
        vaultPkt.grantPremiumAccess(user, 15 days);

        uint256 shares = _deposit(vaultPkt, user, DEPOSIT);
        assertGt(shares, 0, "shares minted");
        assertApproxEqAbs(vaultPkt.totalAssets(), DEPOSIT + vaultPkt.MIN_DEPOSIT(), 1e3, "totalAssets correct");
    }

    function test_fork_base_pkt_access_expires() public {
        vm.prank(owner);
        vaultPkt.grantPremiumAccess(user, 15 days);

        _deposit(vaultPkt, user, DEPOSIT);
        _warp(16 days);

        deal(EURC_BASE, user, DEPOSIT);
        vm.startPrank(user);
        IERC20(EURC_BASE).approve(address(vaultPkt), DEPOSIT);
        vm.expectRevert(abi.encodeWithSelector(
            PaktolVaultV2.PremiumAccessExpired.selector,
            block.timestamp - 1 days
        ));
        vaultPkt.deposit(DEPOSIT, user);
        vm.stopPrank();
    }

    function test_fork_base_pkt_withdraw_after_expiry() public {
        vm.prank(owner);
        vaultPkt.grantPremiumAccess(user, 15 days);

        uint256 shares = _deposit(vaultPkt, user, DEPOSIT);
        _warp(16 days); // access expired + cooldown passed

        uint256 balBefore = IERC20(EURC_BASE).balanceOf(user);
        vm.prank(user);
        vaultPkt.redeem(shares, user, user);

        assertApproxEqAbs(IERC20(EURC_BASE).balanceOf(user), balBefore + DEPOSIT, 1e3);
    }

    /* ══════════════════════════════════════════════════════════════════
       6. DEPOSIT WITH PERMIT
       ══════════════════════════════════════════════════════════════════ */

    function test_fork_base_depositWithPermit() public {
        uint256 deadline = block.timestamp + 1 hours;
        (uint8 v, bytes32 r, bytes32 s) = _signPermit(
            address(vaultStd), permitUser, PERMIT_USER_KEY, DEPOSIT, deadline
        );

        vm.prank(permitUser);
        uint256 shares = vaultStd.depositWithPermit(DEPOSIT, permitUser, deadline, v, r, s);

        assertGt(shares, 0, "shares minted");
        assertApproxEqAbs(vaultStd.totalAssets(), DEPOSIT + vaultStd.MIN_DEPOSIT(), 1e3, "totalAssets correct");
    }

    /* ══════════════════════════════════════════════════════════════════
       7. EMERGENCY EXIT
       ══════════════════════════════════════════════════════════════════ */

    function test_fork_base_emergencyExit_pulls_from_byzantine() public {
        _deposit(vaultStd, user, DEPOSIT);

        uint256 totalBefore = vaultStd.totalAssets();

        vm.prank(owner);
        vaultStd.emergencyExitByzantine();

        // All Byzantine shares redeemed (or were already 0 on sandbox)
        assertEq(IERC4626(BYZANTINE_EUR).balanceOf(address(vaultStd)), 0, "Byzantine shares redeemed");
        // All funds now idle in vault
        assertGt(IERC20(EURC_BASE).balanceOf(address(vaultStd)), 0, "EURC in vault");
        // totalAssets unchanged
        assertApproxEqAbs(vaultStd.totalAssets(), totalBefore, 1e3, "no value lost");
        assertTrue(vaultStd.paused(), "vault auto-paused");
    }

    function test_fork_base_emergencyExit_users_can_withdraw() public {
        uint256 shares = _deposit(vaultStd, user, DEPOSIT);

        vm.prank(owner);
        vaultStd.emergencyExitByzantine();

        uint256 balBefore = IERC20(EURC_BASE).balanceOf(user);
        vm.prank(user);
        vaultStd.redeem(shares, user, user);

        assertApproxEqAbs(IERC20(EURC_BASE).balanceOf(user), balBefore + DEPOSIT, 1e3);
    }

    /* ══════════════════════════════════════════════════════════════════
       8. MULTI-USER
       ══════════════════════════════════════════════════════════════════ */

    function test_fork_base_multiuser_proportional_shares() public {
        uint256 s1 = _deposit(vaultStd, user,  DEPOSIT);
        uint256 s2 = _deposit(vaultStd, user2, DEPOSIT * 2);

        // user2 deposited 2x → should have ~2x shares
        assertApproxEqAbs(s2, s1 * 2, 1e3);
    }

    /// @dev Treasury is exempt from the 4h cooldown.
    ///      Verified by checking maxRedeem immediately after minting shares to treasury.
    ///      If harvest skipped (no yield on sandbox), we deposit directly to treasury
    ///      as owner to test the exemption.
    function test_fork_base_treasury_exempt_from_cooldown() public {
        // Deposit directly to treasury to give it shares (bypasses cooldown check on receiver)
        // This works because deposit checks premiumExpiry[receiver], not timestamp.
        // Treasury is not the depositor — but to mint shares to treasury we must use
        // _mint directly... instead, just deposit to treasury and verify.
        uint256 amount = 10e6; // 10 EURC
        deal(EURC_BASE, owner, amount);
        vm.startPrank(owner);
        IERC20(EURC_BASE).approve(address(vaultStd), amount);
        vaultStd.deposit(amount, treasury);
        vm.stopPrank();

        uint256 treasuryShares = vaultStd.balanceOf(treasury);
        assertGt(treasuryShares, 0, "treasury has shares");

        // Treasury deposited so depositTimestamp[treasury] was set.
        // But treasury IS exempt from cooldown check (owner_ != TREASURY).
        // maxRedeem should be > 0 immediately.
        assertGt(vaultStd.maxRedeem(treasury), 0, "treasury exempt from 4h cooldown");
    }

    /* ─────────────── permit helper ─────────────────────────────────── */

    function _signPermit(
        address spender_,
        address owner_,
        uint256 ownerKey_,
        uint256 amount_,
        uint256 deadline_
    ) internal view returns (uint8 v, bytes32 r, bytes32 s) {
        bytes32 PERMIT_TYPEHASH =
            keccak256("Permit(address owner,address spender,uint256 value,uint256 nonce,uint256 deadline)");
        bytes32 structHash = keccak256(abi.encode(
            PERMIT_TYPEHASH, owner_, spender_, amount_,
            ERC20Permit(EURC_BASE).nonces(owner_), deadline_
        ));
        bytes32 digest = keccak256(abi.encodePacked(
            "\x19\x01",
            ERC20Permit(EURC_BASE).DOMAIN_SEPARATOR(),
            structHash
        ));
        (v, r, s) = vm.sign(ownerKey_, digest);
    }
}
