// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/// @notice Minimal AAVE v3 IPool interface — only the functions PaktolVault uses.
interface IAavePool {
    /// @notice Aave v3 reserve data — full struct layout required for correct ABI decoding.
    struct ReserveData {
        uint256 configuration;
        uint128 liquidityIndex;
        uint128 currentLiquidityRate;
        uint128 variableBorrowIndex;
        uint128 currentVariableBorrowRate;
        uint128 currentStableBorrowRate;
        uint40  lastUpdateTimestamp;
        uint16  id;
        address aTokenAddress;
        address stableDebtTokenAddress;
        address variableDebtTokenAddress;
        address interestRateStrategyAddress;
        uint128 accruedToTreasury;
        uint128 unbacked;
        uint128 isolationModeTotalDebt;
    }

    /// @notice Returns reserve data for the given asset. Used in constructor to validate aToken consistency.
    function getReserveData(address asset) external view returns (ReserveData memory);

    /// @notice Supplies an amount of underlying asset into the reserve.
    /// @param asset        The underlying asset to supply.
    /// @param amount       The amount to supply.
    /// @param onBehalfOf   Address that will receive the aTokens.
    /// @param referralCode Integrator referral code. Use 0.
    function supply(
        address asset,
        uint256 amount,
        address onBehalfOf,
        uint16 referralCode
    ) external;

    /// @notice Withdraws an amount of underlying asset from the reserve.
    /// @param asset    The underlying asset to withdraw.
    /// @param amount   The amount to withdraw. type(uint256).max = withdraw all.
    /// @param to       Address that receives the underlying.
    /// @return         The actual amount withdrawn.
    function withdraw(
        address asset,
        uint256 amount,
        address to
    ) external returns (uint256);
}
