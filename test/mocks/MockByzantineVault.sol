// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "@openzeppelin/contracts/token/ERC20/extensions/ERC4626.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "./MockEURC.sol";

/// @notice Minimal ERC-4626 vault standing in for Byzantine VaultV2 in testnet deployments.
///         No whitelisting, no gates, no fees — pure pass-through with yield simulation.
contract MockByzantineVault is ERC4626 {
    constructor(IERC20 asset_) ERC4626(asset_) ERC20("Mock Byzantine EURC Vault", "bEURC") {}

    /// @dev Simulates yield by minting EURC directly into this vault.
    ///      Increases totalAssets() without minting new shares → share price rises.
    function simulateYield(uint256 amount) external {
        MockEURC(asset()).mint(address(this), amount);
    }
}
