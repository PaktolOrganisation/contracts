// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "erc4626-tests/ERC4626.test.sol";

// Selective imports to avoid namespace collision with a16z's own IERC20/IERC4626 declarations.
import {PaktolVault} from "../src/PaktolVault.sol";
import {MockEURe}    from "./mocks/MockEURe.sol";
import {MockAavePool} from "./mocks/MockAavePool.sol";
import {IERC20 as OzIERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

/// @title PaktolVaultERC4626ComplianceTest
/// @notice Runs the a16z ERC-4626 compliance test suite against PaktolVault.
///
///         Vault-specific constraints:
///           • MIN_DEPOSIT = 1e9: amounts below this are skipped via try/catch + vm.assume(false).
///           • AAVE-backed totalAssets: gains simulated by minting EURe idle to vault.
///           • Loss scenarios skipped — covered by dedicated unit tests.
///           • REQUIRES_AUTH = false (Standard vault, open deposits).
contract PaktolVaultERC4626ComplianceTest is ERC4626Test {
    MockEURe     internal eure;
    MockAavePool internal pool;
    PaktolVault  internal vault;

    address internal owner      = makeAddr("owner");
    address internal treasury   = makeAddr("treasury");
    address internal guardian   = makeAddr("guardian");
    address internal harvester  = makeAddr("harvester");
    address internal signerAddr = makeAddr("signer");

    function setUp() public override {
        eure = new MockEURe();
        pool = new MockAavePool(address(eure));

        vault = new PaktolVault(
            OzIERC20(address(eure)), "Paktol Standard", "pkEUR-S", owner,
            treasury, 350, 50, guardian, harvester,
            address(pool), address(pool.aToken()), 0, signerAddr, false
        );

        _underlying_ = address(eure);
        _vault_      = address(vault);
        _delta_      = 0;
        _vaultMayBeEmpty = false;
        _unlimitedAmount = false;
    }

    /// @dev Simulate yield by minting EURe idle to vault (totalAssets includes idle balance).
    ///      Skip loss scenarios — Aave loss handling is in PaktolVault.t.sol.
    function setUpYield(Init memory init) public override {
        if (init.yield >= 0) {
            uint256 gain = uint256(init.yield);
            if (gain > 0) {
                try IMockERC20(_underlying_).mint(_vault_, gain) {} catch { vm.assume(false); }
            }
        } else {
            vm.assume(false);
        }
    }
}
