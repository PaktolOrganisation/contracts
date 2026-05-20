// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "forge-std/Test.sol";
import "../src/PaktolVault.sol";

/// @title PaktolVaultForkTest
/// @notice Integration tests against real Gnosis Chain contracts.
///         Requires GNOSIS_RPC_URL env var pointing to an archive node.
///
/// @dev Run with:
///      GNOSIS_RPC_URL=https://... forge test --match-contract PaktolVaultForkTest -vvvv
///
///      These tests are skipped if GNOSIS_RPC_URL is not set.
///      They prove that PaktolVault integrates correctly with the real AAVE v3 Pool
///      and real EURe on Gnosis Chain — something unit tests with mocks cannot guarantee.
///
/// TODO: Confirm AAVE_POOL, EURE, and ATOKEN addresses on Gnosis Chain before running.
contract PaktolVaultForkTest is Test {
    /* ─────────────────── GNOSIS CHAIN ADDRESSES ────────────────────── */

    /// @dev Monerium EURe on Gnosis Chain. 18 decimals.
    address constant EURE = 0xcB444e90D8198415266c6a2724b7900fb12FC56E;

    /// @dev AAVE v3 Pool on Gnosis Chain.
    address constant AAVE_POOL = 0xb50201558B00496A145fE76f7424749556E326D8;

    /// @dev AAVE aGnoEURe on Gnosis Chain (interest-bearing EURe). Source: bgd-labs/aave-address-book.
    address constant ATOKEN = 0xEdBC7449a9b594CA4E053D9737EC5Dc4CbCcBfb2;

    /* ─────────────────────────── ACTORS ────────────────────────── */

    address internal owner = makeAddr("owner");
    address internal treasury = makeAddr("treasury");
    address internal guardian = makeAddr("guardian");
    address internal harvester = makeAddr("harvester");
    address internal user = makeAddr("user");

    PaktolVault internal vault;

    /* ─────────────────────────── SETUP ─────────────────────────── */

    function setUp() public {
        string memory rpc = vm.envOr("GNOSIS_RPC_URL", string(""));
        if (bytes(rpc).length == 0) {
            vm.skip(true);
            return;
        }

        uint256 forkBlock = vm.envOr("GNOSIS_FORK_BLOCK", uint256(0));
        if (forkBlock == 0) forkBlock = 39_000_000;
        vm.createSelectFork(rpc, forkBlock);

        vault = new PaktolVault(
            IERC20(EURE), "Paktol EUR", "pkEUR", owner,
            treasury, 350, 50, guardian, harvester,
            AAVE_POOL, ATOKEN, 0, makeAddr("signer"), false
        );
    }

    /* ─────────────────── EURe FUNDING HELPER ───────────────────── */

    /// @dev forge's deal() overwrites EURe's proxy implementation pointer (slot 3),
    ///      corrupting the contract. Instead, impersonate the AAVE aEURe contract
    ///      which holds real EURe as underlying collateral — no storage hacks needed.
    function _giveEURe(
        address to,
        uint256 amount
    ) internal {
        uint256 aTokenBalance = IERC20(EURE).balanceOf(ATOKEN);
        require(aTokenBalance >= amount, "insufficient EURe in AAVE pool - reduce amount");
        vm.prank(ATOKEN);
        IERC20(EURE).transfer(to, amount);
    }

    /* ─────────────────────── BASIC INTEGRATION ─────────────────── */

    /// @dev Deposit real EURe into PaktolVault, verify it lands in AAVE.
    function test_fork_deposit_realEURe() public {
        uint256 amount = 1_000e18;

        _giveEURe(user, amount);
        assertEq(IERC20(EURE).balanceOf(user), amount);

        vm.startPrank(user);
        IERC20(EURE).approve(address(vault), amount);
        uint256 shares = vault.deposit(amount, user);
        vm.stopPrank();

        assertGt(shares, 0, "should mint shares");
        assertEq(IERC20(EURE).balanceOf(address(vault)), 0, "no idle EURe in vault");
        assertApproxEqAbs(vault.totalAssets(), amount, 1e9, "totalAssets reflects deposit");

        // Verify aEURe balance — all funds deployed to AAVE.
        assertApproxEqAbs(IERC20(ATOKEN).balanceOf(address(vault)), amount, 1e9, "vault should hold aEURe");
    }

    /// @dev Deposit then redeem — user recovers their full EURe.
    function test_fork_deposit_redeem_roundtrip() public {
        uint256 amount = 1_000e18;
        _giveEURe(user, amount);

        vm.startPrank(user);
        IERC20(EURE).approve(address(vault), amount);
        uint256 shares = vault.deposit(amount, user);
        vm.stopPrank();

        vm.warp(block.timestamp + vault.WITHDRAWAL_COOLDOWN());

        vm.startPrank(user);
        vault.redeem(shares, user, user);
        vm.stopPrank();

        assertGe(IERC20(EURE).balanceOf(user), amount - 1e12, "user should recover at least their deposit");
    }

    /// @dev Warp time and harvest — verifies AAVE yield accrual and harvest logic.
    function test_fork_harvest_afterYieldAccrual() public {
        uint256 amount = 10_000e18;
        _giveEURe(user, amount);

        vm.startPrank(user);
        IERC20(EURE).approve(address(vault), amount);
        vault.deposit(amount, user);
        vm.stopPrank();

        uint256 totalBefore = vault.totalAssets();

        // Warp 30 days — aEURe rebases as AAVE accrues interest.
        vm.warp(block.timestamp + 30 days);
        vm.roll(block.number + (30 days / 5)); // ~5s per block on Gnosis

        // Harvest must not revert and must update state.
        vm.prank(harvester);
        vault.harvest();

        assertEq(vault.lastHarvestTimestamp(), block.timestamp, "timestamp updated");
        assertApproxEqAbs(vault.lastTotalAssets(), vault.totalAssets(), 1, "snapshot updated");

        uint256 totalAfter = vault.totalAssets();
        if (totalAfter > totalBefore) {
            uint256 grossYield = totalAfter - totalBefore + IERC20(EURE).balanceOf(treasury);
            uint256 cap = (totalBefore * 350 * 30 days) / (10_000 * 365 days);
            if (grossYield > cap) {
                assertGt(IERC20(EURE).balanceOf(treasury), 0, "treasury receives surplus");
            }
        }
    }

    /// @dev maxDeposit and maxMint return sane values on Gnosis Chain.
    function test_fork_erc4626_conformance_maxDeposit() public view {
        assertEq(vault.maxDeposit(user), type(uint256).max);
        assertEq(vault.maxMint(user), type(uint256).max);
    }

    /* ────────────────────── EMERGENCY EXIT (fork) ───────────────────── */

    /// @dev emergencyExitAave() pulls real aGnoEURe back to vault as idle EURe.
    function test_fork_emergencyExit_pullsAllFromAave() public {
        uint256 amount = 1_000e18;
        _giveEURe(user, amount);

        vm.startPrank(user);
        IERC20(EURE).approve(address(vault), amount);
        vault.deposit(amount, user);
        vm.stopPrank();

        // Pre-exit: all funds in AAVE as aGnoEURe.
        assertApproxEqAbs(IERC20(ATOKEN).balanceOf(address(vault)), amount, 1e9, "vault holds aEURe before exit");
        assertEq(IERC20(EURE).balanceOf(address(vault)), 0, "no idle EURe before exit");

        vm.prank(guardian);
        vault.pause();

        vm.prank(owner);
        vault.emergencyExitAave();

        // Post-exit: no aGnoEURe, full balance idle as EURe.
        assertEq(IERC20(ATOKEN).balanceOf(address(vault)), 0, "no aEURe after exit");
        assertApproxEqAbs(IERC20(EURE).balanceOf(address(vault)), amount, 1e9, "idle EURe after exit");
        assertApproxEqAbs(vault.totalAssets(), amount, 1e9, "totalAssets unchanged");
    }

    /// @dev After emergencyExitAave(), users can redeem from idle EURe without touching AAVE.
    function test_fork_emergencyExit_usersCanWithdraw() public {
        uint256 amount = 1_000e18;
        _giveEURe(user, amount);

        vm.startPrank(user);
        IERC20(EURE).approve(address(vault), amount);
        uint256 shares = vault.deposit(amount, user);
        vm.stopPrank();

        vm.prank(guardian);
        vault.pause();

        vm.prank(owner);
        vault.emergencyExitAave();

        // Redeem from idle — must not call AAVE withdraw.
        uint256 balBefore = IERC20(EURE).balanceOf(user);
        vm.prank(user);
        vault.redeem(shares, user, user);

        assertApproxEqAbs(IERC20(EURE).balanceOf(user), balBefore + amount, 1e9, "user recovers full deposit");
        assertEq(IERC20(ATOKEN).balanceOf(address(vault)), 0, "still no aEURe after redeem");
    }

    /* ────────────────── CONSTRUCTOR VALIDATION (fork) ──────────────── */

    /// @dev Passes a wrong aToken — real Aave returns correct one → mismatch → revert.
    function test_fork_constructor_rejectsWrongAToken() public {
        address wrongAToken = makeAddr("wrongAToken");
        vm.expectRevert(abi.encodeWithSelector(
            PaktolVault.ATokenMismatch.selector,
            wrongAToken,
            ATOKEN
        ));
        new PaktolVault(
            IERC20(EURE), "x", "x", owner,
            treasury, 350, 50, guardian, harvester,
            AAVE_POOL, wrongAToken, 0, makeAddr("signer"), false
        );
    }

    /* ────────────────────── DEPLOY SCRIPT (fork) ────────────────────── */

    /// @dev Mirrors Deploy.s.sol: deploy vault + seed dead shares atomically.
    ///      Validates the full deployment flow against real Gnosis Chain state.
    function test_fork_deploy_seedDeadShares() public {
        address deployer = makeAddr("deployer");
        uint256 seedAmount = vault.MIN_DEPOSIT();

        _giveEURe(deployer, seedAmount);

        // Deploy a fresh vault (same params as production Standard instance).
        vm.startPrank(deployer);
        PaktolVault freshVault = new PaktolVault(
            IERC20(EURE), "Paktol EUR", "pkEUR", owner,
            treasury, 350, 50, guardian, harvester,
            AAVE_POOL, ATOKEN, 0, makeAddr("signer"), false
        );

        // Seed dead shares — must happen before any real user deposit.
        IERC20(EURE).approve(address(freshVault), seedAmount);
        freshVault.deposit(seedAmount, address(0xdEaD));
        vm.stopPrank();

        // Post-deploy assertions (mirrors Deploy.s.sol require() checks).
        // AAVE rounds 1 wei on supply — tolerance of 1e9 covers it.
        assertApproxEqAbs(freshVault.lastTotalAssets(), seedAmount, 1e9, "seed: lastTotalAssets");
        assertGt(freshVault.totalSupply(), 0, "seed: shares minted");
        assertEq(freshVault.owner(), owner, "seed: owner");
        assertEq(freshVault.TREASURY(), treasury, "seed: treasury");
        assertEq(freshVault.AAVE_POOL(), AAVE_POOL, "seed: aavePool");
        assertEq(freshVault.ATOKEN(), ATOKEN, "seed: aToken");

        // Dead address holds shares — inflation attack window is closed.
        assertGt(freshVault.balanceOf(address(0xdEaD)), 0, "seed: dead address holds shares");

        // Verify funds are deployed to AAVE (not sitting idle).
        assertEq(IERC20(EURE).balanceOf(address(freshVault)), 0, "seed: no idle EURe");
        assertGt(IERC20(ATOKEN).balanceOf(address(freshVault)), 0, "seed: vault holds aEURe");
    }
}
