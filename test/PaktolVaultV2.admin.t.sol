// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "./PaktolVaultV2Base.t.sol";

contract PaktolVaultV2AdminTest is PaktolVaultV2Base {

    /* ────────────────────── PAUSE / GUARDIAN ───────────────────────── */

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

    /* ──────────────────────────── ADMIN ────────────────────────────── */

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

    /* ─────────── M-2: transferOwnership role separation ────────────── */

    function test_m2_transferOwnership_revert_toGuardian() public {
        vm.expectRevert(PaktolVaultV2.RolesNotSeparated.selector);
        vm.prank(owner);
        vaultStd.transferOwnership(guardian);
    }

    function test_m2_transferOwnership_revert_toHarvester() public {
        vm.expectRevert(PaktolVaultV2.RolesNotSeparated.selector);
        vm.prank(owner);
        vaultStd.transferOwnership(harvester);
    }

    function test_m2_transferOwnership_ok_toNewAddress() public {
        address newOwner = makeAddr("newOwner");
        vm.prank(owner);
        vaultStd.transferOwnership(newOwner);
        // Ownable2Step: newOwner must accept
        vm.prank(newOwner);
        vaultStd.acceptOwnership();
        assertEq(vaultStd.owner(), newOwner);
    }
}
