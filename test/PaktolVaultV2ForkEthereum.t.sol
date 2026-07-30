// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "forge-std/Test.sol";
import "../src/PaktolVaultV2.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/extensions/ERC20Permit.sol";

/// @dev Fork tests against the real Byzantine "ByzPrime EUR" vault on Ethereum Mainnet.
///      Run with:
///        forge test --match-contract "ForkEthereum" --fork-url https://ethereum-rpc.publicnode.com -vvv
///
///      Unlike PaktolVaultV2ForkBase.t.sol (which uses Byzantine's Base Sandbox vault, exempt
///      from whitelist), there is no known sandbox equivalent on Ethereum — the real vault's
///      sendAssetsGate / sendSharesGate / receiveSharesGate are live and would reject an
///      unwhitelisted address. We mock those 3 gate calls to return true for our own vault
///      addresses (vm.mockCall, local-fork only — no real transaction, no real whitelist
///      needed) so the FULL deposit/withdraw lifecycle can be exercised against the real
///      byzEUR vault's actual current state (share price, liquidity) before ever asking
///      Byzantine to whitelist the real deployment.
///
///      No gas cost — everything runs in a local fork.
contract PaktolVaultV2ForkEthereumTest is Test {

    /* ─────────────── Ethereum Mainnet constants ─────────────────────── */

    address constant EURC_ETHEREUM = 0x1aBaEA1f7C830bD89Acc67eC4af516284b1bC33c;
    address constant BYZANTINE_EUR = 0x2F99e35Ea811F3cC230B26dfF817604B5D4B6e38;

    // Byzantine's live gates on byzEUR (Ethereum) — verified on-chain, not assumed.
    address constant SEND_ASSETS_GATE    = 0x80dc268861Cf57D31c52E8cD0467B3d3024512bc;
    address constant SEND_SHARES_GATE    = 0x02B38131Bd473554D2CEd77018c18d030C7CE390;
    address constant RECEIVE_SHARES_GATE = 0x5351999cA54675607d08003d9113553162bB795D;
    // receiveAssetsGate() == address(0) on this vault — no mock needed, always allowed.

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
        // Fork is provided via --fork-url flag; verify we're on Ethereum mainnet.
        assertEq(block.chainid, 1, "must fork Ethereum Mainnet (use --fork-url https://ethereum-rpc.publicnode.com)");
        assertEq(IERC4626(BYZANTINE_EUR).asset(), EURC_ETHEREUM, "Byzantine asset mismatch");

        // Deploy both vaults
        vaultStd = new PaktolVaultV2(
            IERC20(EURC_ETHEREUM),
            "Paktol Standard EURC",  "pkEURC-S",
            owner, treasury, CAP_BPS, FEE_BPS,
            guardian, harvester,
            address(0),            // no granter
            BYZANTINE_EUR,
            0, false               // no TVL cap, open
        );

        vaultPkt = new PaktolVaultV2(
            IERC20(EURC_ETHEREUM),
            "Paktol Premium EURC",  "pkEURC-P",
            owner, treasury, CAP_BPS, FEE_BPS,
            guardian, harvester,
            address(0),            // no granter
            BYZANTINE_EUR,
            0, true                // no TVL cap, gated (REQUIRES_AUTH)
        );

        // Bypass Byzantine's real Ethereum whitelist gates for our two vault addresses —
        // local fork simulation only, does not require or imply real whitelist approval.
        _mockGates(address(vaultStd));
        _mockGates(address(vaultPkt));

        // Fund users with real EURC via deal() (modifies storage slot directly)
        deal(EURC_ETHEREUM, user,       10_000e6);
        deal(EURC_ETHEREUM, user2,      10_000e6);
        deal(EURC_ETHEREUM, permitUser, 10_000e6);

        // Seed dead shares on both vaults to prevent inflation attacks
        _seed(vaultStd);
        _seed(vaultPkt);
    }

    /* ─────────────── helpers ───────────────────────────────────────── */

    function _mockGates(address vaultAddr) internal {
        vm.mockCall(
            SEND_ASSETS_GATE,
            abi.encodeWithSignature("canSendAssets(address)", vaultAddr),
            abi.encode(true)
        );
        vm.mockCall(
            SEND_SHARES_GATE,
            abi.encodeWithSignature("canSendShares(address)", vaultAddr),
            abi.encode(true)
        );
        vm.mockCall(
            RECEIVE_SHARES_GATE,
            abi.encodeWithSignature("canReceiveShares(address)", vaultAddr),
            abi.encode(true)
        );
    }

    function _seed(PaktolVaultV2 vault_) internal {
        uint256 min = vault_.minDeposit();
        deal(EURC_ETHEREUM, owner, min);
        vm.startPrank(owner);
        if (vault_.REQUIRES_AUTH()) vault_.grantPremiumAccess(address(0xdEaD), 365 days);
        IERC20(EURC_ETHEREUM).approve(address(vault_), min);
        vault_.deposit(min, address(0xdEaD));
        vm.stopPrank();
    }

    function _deposit(PaktolVaultV2 vault_, address who, uint256 amount) internal returns (uint256) {
        deal(EURC_ETHEREUM, who, amount);
        vm.startPrank(who);
        IERC20(EURC_ETHEREUM).approve(address(vault_), amount);
        uint256 shares = vault_.deposit(amount, who);
        vm.stopPrank();
        return shares;
    }

    function _warp(uint256 delta) internal { vm.warp(block.timestamp + delta); }

    /* ══════════════════════════════════════════════════════════════════
       1. DEPLOYMENT & WIRING
       ══════════════════════════════════════════════════════════════════ */

    function test_fork_eth_config() public view {
        assertEq(address(vaultStd.asset()), EURC_ETHEREUM);
        assertEq(address(vaultStd.BYZANTINE_VAULT()), BYZANTINE_EUR);
        assertEq(vaultStd.owner(), owner);
        assertEq(vaultStd.TREASURY(), treasury);
        assertFalse(vaultStd.REQUIRES_AUTH());
        assertTrue(vaultPkt.REQUIRES_AUTH());
    }

    /* ══════════════════════════════════════════════════════════════════
       2. DEPOSIT → BYZANTINE ROUTING
       ══════════════════════════════════════════════════════════════════ */

    function test_fork_eth_deposit_routes_to_byzantine() public {
        uint256 shares = _deposit(vaultStd, user, DEPOSIT);
        uint256 min = vaultStd.minDeposit();

        assertGt(shares, 0, "vault shares minted");
        assertApproxEqAbs(vaultStd.totalAssets(), DEPOSIT + min, 1e3, "totalAssets correct");
        assertEq(IERC20(EURC_ETHEREUM).balanceOf(address(vaultStd)), 0, "no idle EURC - real vault accepts deposits");
        assertGt(IERC4626(BYZANTINE_EUR).balanceOf(address(vaultStd)), 0, "vault holds real Byzantine shares");
    }

    function test_fork_eth_totalAssets_reflects_byzantine() public {
        uint256 min = vaultStd.minDeposit();
        uint256 expected = DEPOSIT + min; // user + dead shares

        _deposit(vaultStd, user, DEPOSIT);

        assertApproxEqAbs(vaultStd.totalAssets(), expected, 1e3, "totalAssets correct");
    }

    /* ══════════════════════════════════════════════════════════════════
       3. WITHDRAW ROUNDTRIP
       ══════════════════════════════════════════════════════════════════ */

    function test_fork_eth_redeem_roundtrip() public {
        uint256 shares = _deposit(vaultStd, user, DEPOSIT);
        uint256 balBefore = IERC20(EURC_ETHEREUM).balanceOf(user);

        _warp(5 hours);

        vm.prank(user);
        uint256 received = vaultStd.redeem(shares, user, user);

        assertApproxEqAbs(received, DEPOSIT, 1e3, "user gets back deposit");
        assertGt(IERC20(EURC_ETHEREUM).balanceOf(user), balBefore, "user EURC balance increased");
    }

    function test_fork_eth_withdraw_blocked_in_cooldown() public {
        _deposit(vaultStd, user, DEPOSIT);

        assertEq(vaultStd.maxWithdraw(user), 0, "locked in cooldown");
        assertEq(vaultStd.maxRedeem(user), 0, "locked in cooldown");
    }

    function test_fork_eth_withdraw_available_after_cooldown() public {
        _deposit(vaultStd, user, DEPOSIT);
        _warp(5 hours);

        assertGt(vaultStd.maxWithdraw(user), 0, "unlocked after cooldown");
    }

    // F-04 KNOWN LIMITATION, confirmed against the live vault: Byzantine's own
    // maxWithdraw() is hardcoded to always return 0 (verified in their VaultV2.sol),
    // so byzantineRealLiquidity() currently equals idle EURC only — 0 right after a
    // full deposit sweep, since all EURC just moved into Byzantine. This is NOT a bug
    // in our code; it documents the real, current behavior against production Byzantine.
    function test_fork_eth_byzantineRealLiquidity_matches_real_vault() public {
        _deposit(vaultStd, user, DEPOSIT);

        assertEq(
            vaultStd.byzantineRealLiquidity(),
            IERC20(EURC_ETHEREUM).balanceOf(address(vaultStd)),
            "byzantineRealLiquidity currently reflects idle EURC only (Byzantine maxWithdraw() is always 0)"
        );
    }

    /* ══════════════════════════════════════════════════════════════════
       4. HARVEST
       ══════════════════════════════════════════════════════════════════ */

    function test_fork_eth_harvest_callable_after_interval() public {
        _deposit(vaultStd, user, DEPOSIT);
        _warp(2 days);

        vm.prank(harvester);
        vaultStd.harvest();
    }

    function test_fork_eth_harvest_blocked_when_paused() public {
        _deposit(vaultStd, user, DEPOSIT);
        _warp(2 days);

        vm.prank(guardian);
        vaultStd.pause();

        vm.prank(harvester);
        vm.expectRevert();
        vaultStd.harvest();
    }

    function test_fork_eth_harvest_revert_before_interval() public {
        _deposit(vaultStd, user, DEPOSIT);
        vm.prank(harvester);
        vm.expectRevert();
        vaultStd.harvest();
    }

    /* ══════════════════════════════════════════════════════════════════
       5. PREMIUM ACCESS (vaultPkt)
       ══════════════════════════════════════════════════════════════════ */

    function test_fork_eth_pkt_blocked_without_access() public {
        deal(EURC_ETHEREUM, user, DEPOSIT);
        vm.startPrank(user);
        IERC20(EURC_ETHEREUM).approve(address(vaultPkt), DEPOSIT);
        vm.expectRevert(abi.encodeWithSelector(PaktolVaultV2.PremiumAccessExpired.selector, 0));
        vaultPkt.deposit(DEPOSIT, user);
        vm.stopPrank();
    }

    function test_fork_eth_pkt_deposit_with_access() public {
        vm.prank(owner);
        vaultPkt.grantPremiumAccess(user, 15 days);

        uint256 shares = _deposit(vaultPkt, user, DEPOSIT);
        assertGt(shares, 0, "shares minted");
        assertApproxEqAbs(vaultPkt.totalAssets(), DEPOSIT + vaultPkt.minDeposit(), 1e3, "totalAssets correct");
    }

    /* ══════════════════════════════════════════════════════════════════
       6. DEPOSIT WITH PERMIT
       ══════════════════════════════════════════════════════════════════ */

    function test_fork_eth_depositWithPermit() public {
        uint256 deadline = block.timestamp + 1 hours;
        (uint8 v, bytes32 r, bytes32 s) = _signPermit(
            address(vaultStd), permitUser, PERMIT_USER_KEY, DEPOSIT, deadline
        );

        vm.prank(permitUser);
        uint256 shares = vaultStd.depositWithPermit(DEPOSIT, permitUser, deadline, v, r, s);

        assertGt(shares, 0, "shares minted");
        assertApproxEqAbs(vaultStd.totalAssets(), DEPOSIT + vaultStd.minDeposit(), 1e3, "totalAssets correct");
    }

    /* ══════════════════════════════════════════════════════════════════
       7. EMERGENCY EXIT + REDEPLOY (F-08)
       ══════════════════════════════════════════════════════════════════ */

    function test_fork_eth_emergencyExit_pulls_from_byzantine() public {
        _deposit(vaultStd, user, DEPOSIT);

        uint256 totalBefore = vaultStd.totalAssets();

        vm.prank(owner);
        vaultStd.emergencyExitByzantine();

        assertEq(IERC4626(BYZANTINE_EUR).balanceOf(address(vaultStd)), 0, "Byzantine shares redeemed");
        assertGt(IERC20(EURC_ETHEREUM).balanceOf(address(vaultStd)), 0, "EURC in vault");
        assertApproxEqAbs(vaultStd.totalAssets(), totalBefore, 1e3, "no value lost");
        assertTrue(vaultStd.paused(), "vault auto-paused");
    }

    function test_fork_eth_redeployToByzantine_after_emergencyExit() public {
        _deposit(vaultStd, user, DEPOSIT);

        vm.prank(owner);
        vaultStd.emergencyExitByzantine();

        vm.prank(owner);
        vaultStd.unpause();

        vm.prank(owner);
        vaultStd.redeployToByzantine();

        assertEq(IERC20(EURC_ETHEREUM).balanceOf(address(vaultStd)), 0, "no idle EURC after redeploy");
        assertGt(IERC4626(BYZANTINE_EUR).balanceOf(address(vaultStd)), 0, "Byzantine position restored");
    }

    function test_fork_eth_emergencyExit_users_can_withdraw() public {
        uint256 shares = _deposit(vaultStd, user, DEPOSIT);

        vm.prank(owner);
        vaultStd.emergencyExitByzantine();

        uint256 balBefore = IERC20(EURC_ETHEREUM).balanceOf(user);
        vm.prank(user);
        vaultStd.redeem(shares, user, user);

        assertApproxEqAbs(IERC20(EURC_ETHEREUM).balanceOf(user), balBefore + DEPOSIT, 1e3);
    }

    /* ══════════════════════════════════════════════════════════════════
       8. MULTI-USER
       ══════════════════════════════════════════════════════════════════ */

    function test_fork_eth_multiuser_proportional_shares() public {
        uint256 s1 = _deposit(vaultStd, user,  DEPOSIT);
        uint256 s2 = _deposit(vaultStd, user2, DEPOSIT * 2);

        assertApproxEqAbs(s2, s1 * 2, 1e3);
    }

    /* ══════════════════════════════════════════════════════════════════
       9. RESCUE TOKEN (F-07)
       ══════════════════════════════════════════════════════════════════ */

    function test_fork_eth_rescueToken_cannot_touch_asset_or_byzantine_shares() public {
        vm.startPrank(owner);
        vm.expectRevert(abi.encodeWithSelector(PaktolVaultV2.CannotRescueToken.selector, EURC_ETHEREUM));
        vaultStd.rescueToken(EURC_ETHEREUM, owner, 1);

        vm.expectRevert(abi.encodeWithSelector(PaktolVaultV2.CannotRescueToken.selector, BYZANTINE_EUR));
        vaultStd.rescueToken(BYZANTINE_EUR, owner, 1);
        vm.stopPrank();
    }

    /* ══════════════════════════════════════════════════════════════════
       10. FULL LIFECYCLE (GRANT → DEPOSIT → HARVEST → WITHDRAW)
       ══════════════════════════════════════════════════════════════════ */

    function test_fork_eth_full_lifecycle() public {
        address backendEOA = makeAddr("backendEOA");

        vm.prank(owner);
        vaultPkt.setGranter(backendEOA);

        vm.prank(backendEOA);
        vaultPkt.grantPremiumAccess(user, 90 days);
        assertGt(vaultPkt.premiumExpiry(user), block.timestamp, "access granted");

        uint256 shares = _deposit(vaultPkt, user, DEPOSIT);
        assertGt(shares, 0, "shares minted");

        _warp(2 days);
        vm.prank(harvester);
        vaultPkt.harvest();

        _warp(3 hours); // cooldown restant
        uint256 balBefore = IERC20(EURC_ETHEREUM).balanceOf(user);
        vm.prank(user);
        vaultPkt.redeem(shares, user, user);

        assertApproxEqAbs(IERC20(EURC_ETHEREUM).balanceOf(user), balBefore + DEPOSIT, 1e3, "user gets deposit back");
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
            ERC20Permit(EURC_ETHEREUM).nonces(owner_), deadline_
        ));
        bytes32 digest = keccak256(abi.encodePacked(
            "\x19\x01",
            ERC20Permit(EURC_ETHEREUM).DOMAIN_SEPARATOR(),
            structHash
        ));
        (v, r, s) = vm.sign(ownerKey_, digest);
    }
}
