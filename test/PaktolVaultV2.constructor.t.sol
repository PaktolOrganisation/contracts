// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "./PaktolVaultV2Base.t.sol";

contract PaktolVaultV2ConstructorTest is PaktolVaultV2Base {

    function test_constructor_immutables() public view {
        assertEq(vaultStd.CAP_BPS(),   CAP_STD);
        assertEq(vaultStd.FEE_BPS(),   FEE_STD);
        assertEq(vaultStd.TREASURY(),  treasury);
        assertEq(address(vaultStd.BYZANTINE_VAULT()), address(mockStd));
        assertEq(vaultStd.guardian(),  guardian);
        assertEq(vaultStd.harvester(), harvester);
        assertFalse(vaultStd.REQUIRES_AUTH());
        assertEq(vaultStd.premiumThreshold(), 0);
        assertEq(vaultPkt.premiumThreshold(), PREMIUM_THRESHOLD);

        assertEq(vaultPkt.CAP_BPS(), CAP_PKT);
        assertEq(vaultPkt.FEE_BPS(), FEE_PKT);
        assertTrue(vaultPkt.REQUIRES_AUTH());
    }

    function test_constructor_revert_zeroAsset() public {
        vm.expectRevert(abi.encodeWithSelector(PaktolVaultV2.ZeroAddress.selector, "asset"));
        new PaktolVaultV2(
            IERC20(address(0)), "x", "x", owner, treasury, CAP_STD, FEE_STD,
            guardian, harvester, address(mockStd), 0, 0, false
        );
    }

    function test_constructor_revert_zeroTreasury() public {
        vm.expectRevert(abi.encodeWithSelector(PaktolVaultV2.ZeroAddress.selector, "treasury"));
        new PaktolVaultV2(
            IERC20(address(eurc)), "x", "x", owner, address(0), CAP_STD, FEE_STD,
            guardian, harvester, address(mockStd), 0, 0, false
        );
    }

    function test_constructor_revert_zeroByzantineVault() public {
        vm.expectRevert(abi.encodeWithSelector(PaktolVaultV2.ZeroAddress.selector, "byzantineVault"));
        new PaktolVaultV2(
            IERC20(address(eurc)), "x", "x", owner, treasury, CAP_STD, FEE_STD,
            guardian, harvester, address(0), 0, 0, false
        );
    }

    function test_constructor_revert_assetMismatch() public {
        MockEURC other = new MockEURC();
        vm.expectRevert(abi.encodeWithSelector(
            PaktolVaultV2.ByzantineVaultAssetMismatch.selector,
            address(eurc),
            address(other)
        ));
        new PaktolVaultV2(
            IERC20(address(other)), "x", "x", owner, treasury, CAP_STD, FEE_STD,
            guardian, harvester, address(mockStd), 0, 0, false
        );
    }

    function test_constructor_revert_capZero() public {
        vm.expectRevert(abi.encodeWithSelector(PaktolVaultV2.CapOutOfRange.selector, 0));
        new PaktolVaultV2(
            IERC20(address(eurc)), "x", "x", owner, treasury, 0, FEE_STD,
            guardian, harvester, address(mockStd), 0, 0, false
        );
    }

    function test_constructor_revert_capAboveMax() public {
        vm.expectRevert(abi.encodeWithSelector(PaktolVaultV2.CapOutOfRange.selector, 10_001));
        new PaktolVaultV2(
            IERC20(address(eurc)), "x", "x", owner, treasury, 10_001, FEE_STD,
            guardian, harvester, address(mockStd), 0, 0, false
        );
    }

    function test_constructor_revert_fee100pct() public {
        vm.expectRevert(abi.encodeWithSelector(PaktolVaultV2.FeeOutOfRange.selector, 10_000));
        new PaktolVaultV2(
            IERC20(address(eurc)), "x", "x", owner, treasury, CAP_STD, 10_000,
            guardian, harvester, address(mockStd), 0, 0, false
        );
    }

    // F-21: FEE_BPS > FLOOR_BPS causes harvest() DoS — tighten constructor bound.
    function test_f21_constructor_revert_fee_above_floor_bps() public {
        vm.expectRevert(abi.encodeWithSelector(PaktolVaultV2.FeeOutOfRange.selector, 201));
        new PaktolVaultV2(
            IERC20(address(eurc)), "x", "x", owner, treasury, CAP_STD, 201,
            guardian, harvester, address(mockStd), 0, 0, false
        );
    }

    function test_f21_constructor_accepts_fee_at_floor_bps() public {
        PaktolVaultV2 v = new PaktolVaultV2(
            IERC20(address(eurc)), "x", "x", owner, treasury, CAP_STD, 200,
            guardian, harvester, address(mockStd), 0, 0, false
        );
        assertEq(v.FEE_BPS(), 200);
    }

    // F-14: role separation enforced in constructor.
    function test_f14_constructor_revert_ownerEqualsGuardian() public {
        vm.expectRevert(PaktolVaultV2.RolesNotSeparated.selector);
        new PaktolVaultV2(
            IERC20(address(eurc)), "x", "x", owner, treasury, CAP_STD, FEE_STD,
            owner, harvester, address(mockStd), 0, 0, false
        );
    }

    function test_f14_constructor_revert_ownerEqualsHarvester() public {
        vm.expectRevert(PaktolVaultV2.RolesNotSeparated.selector);
        new PaktolVaultV2(
            IERC20(address(eurc)), "x", "x", owner, treasury, CAP_STD, FEE_STD,
            guardian, owner, address(mockStd), 0, 0, false
        );
    }

    function test_f14_constructor_revert_guardianEqualsHarvester() public {
        vm.expectRevert(PaktolVaultV2.RolesNotSeparated.selector);
        new PaktolVaultV2(
            IERC20(address(eurc)), "x", "x", owner, treasury, CAP_STD, FEE_STD,
            guardian, guardian, address(mockStd), 0, 0, false
        );
    }
}
