// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "./PaktolVaultV2Base.t.sol";

contract PaktolVaultV2PermitTest is PaktolVaultV2Base {

    address internal permitUser = vm.addr(PERMIT_USER_KEY);

    /* ──────────────────── depositWithPermit ────────────────────────── */

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
        uint256 tiny = vaultStd.minDeposit() - 1;
        eurc.mint(permitUser, tiny);
        uint256 deadline = block.timestamp + 1 hours;
        (uint8 v, bytes32 r, bytes32 s) = _signPermit(address(vaultStd), permitUser, PERMIT_USER_KEY, tiny, deadline);

        vm.prank(permitUser);
        vm.expectRevert(abi.encodeWithSelector(PaktolVaultV2.DepositTooSmall.selector, tiny, vaultStd.minDeposit()));
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

    function test_depositWithPermit_blockedWithoutAccess() public {
        eurc.mint(permitUser, DEPOSIT);
        uint256 deadline = block.timestamp + 1 hours;
        (uint8 v, bytes32 r, bytes32 s) = _signPermit(address(vaultPkt), permitUser, PERMIT_USER_KEY, DEPOSIT, deadline);

        vm.prank(permitUser);
        vm.expectRevert(abi.encodeWithSelector(
            PaktolVaultV2.PremiumAccessExpired.selector, 0
        ));
        vaultPkt.depositWithPermit(DEPOSIT, permitUser, deadline, v, r, s);
    }

    function test_depositWithPermit_successWithAccess() public {
        eurc.mint(permitUser, DEPOSIT);
        vm.prank(owner);
        vaultPkt.grantPremiumAccess(permitUser, 15 days);

        uint256 deadline = block.timestamp + 1 hours;
        (uint8 v, bytes32 r, bytes32 s) = _signPermit(address(vaultPkt), permitUser, PERMIT_USER_KEY, DEPOSIT, deadline);

        vm.prank(permitUser);
        uint256 shares = vaultPkt.depositWithPermit(DEPOSIT, permitUser, deadline, v, r, s);
        assertGt(shares, 0);
    }

    /* ─────────────── depositWithPermit — F-13 ──────────────────────── */

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
}
