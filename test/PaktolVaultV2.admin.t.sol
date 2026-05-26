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

    // F-14: setGuardian rejects granter address.
    function test_f14_setGuardian_revert_equalsGranter() public {
        vm.expectRevert(PaktolVaultV2.RolesNotSeparated.selector);
        vm.prank(owner);
        vaultStd.setGuardian(granter);
    }

    // F-14: setHarvester rejects granter address.
    function test_f14_setHarvester_revert_equalsGranter() public {
        vm.expectRevert(PaktolVaultV2.RolesNotSeparated.selector);
        vm.prank(owner);
        vaultStd.setHarvester(granter);
    }

    /* ──────────────────── GRANTER ──────────────────────────────────── */

    function test_setGranter() public {
        address newGranter = makeAddr("newGranter");
        vm.prank(owner);
        vaultStd.setGranter(newGranter);
        assertEq(vaultStd.granter(), newGranter);
    }

    function test_setGranter_zero_disables() public {
        vm.prank(owner);
        vaultStd.setGranter(address(0));
        assertEq(vaultStd.granter(), address(0));
    }

    function test_setGranter_revert_unauthorized() public {
        vm.expectRevert();
        vm.prank(user);
        vaultStd.setGranter(makeAddr("x"));
    }

    function test_setGranter_revert_equalsOwner() public {
        vm.expectRevert(PaktolVaultV2.RolesNotSeparated.selector);
        vm.prank(owner);
        vaultStd.setGranter(owner);
    }

    function test_setGranter_revert_equalsGuardian() public {
        vm.expectRevert(PaktolVaultV2.RolesNotSeparated.selector);
        vm.prank(owner);
        vaultStd.setGranter(guardian);
    }

    function test_setGranter_revert_equalsHarvester() public {
        vm.expectRevert(PaktolVaultV2.RolesNotSeparated.selector);
        vm.prank(owner);
        vaultStd.setGranter(harvester);
    }

    function test_granter_can_grantPremiumAccess() public {
        vm.prank(granter);
        vaultPkt.grantPremiumAccess(user, 7 days);
        assertGt(vaultPkt.premiumExpiry(user), block.timestamp);
    }

    function test_randomUser_cannot_grantPremiumAccess() public {
        vm.expectRevert(PaktolVaultV2.NotGranter.selector);
        vm.prank(user);
        vaultPkt.grantPremiumAccess(user2, 7 days);
    }

    /* ─────────── setMinHarvestInterval / setMinDeposit ─────────────── */

    function test_setMinHarvestInterval() public {
        vm.prank(owner);
        vaultStd.setMinHarvestInterval(2 hours);
        assertEq(vaultStd.minHarvestInterval(), 2 hours);
    }

    function test_setMinHarvestInterval_revert_tooShort() public {
        vm.expectRevert(
            abi.encodeWithSelector(PaktolVaultV2.IntervalTooShort.selector, 30 minutes, 1 hours)
        );
        vm.prank(owner);
        vaultStd.setMinHarvestInterval(30 minutes);
    }

    function test_setMinHarvestInterval_revert_unauthorized() public {
        vm.expectRevert();
        vm.prank(user);
        vaultStd.setMinHarvestInterval(2 hours);
    }

    function test_setMinDeposit() public {
        vm.prank(owner);
        vaultStd.setMinDeposit(1e6);
        assertEq(vaultStd.minDeposit(), 1e6);
    }

    function test_setMinDeposit_revert_unauthorized() public {
        vm.expectRevert();
        vm.prank(user);
        vaultStd.setMinDeposit(1e6);
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

    function test_m2_transferOwnership_revert_toGranter() public {
        vm.expectRevert(PaktolVaultV2.RolesNotSeparated.selector);
        vm.prank(owner);
        vaultStd.transferOwnership(granter);
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
