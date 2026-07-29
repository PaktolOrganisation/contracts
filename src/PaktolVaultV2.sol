// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import "@openzeppelin/contracts/token/ERC20/extensions/ERC4626.sol";
import "@openzeppelin/contracts/interfaces/IERC4626.sol";
import "@openzeppelin/contracts/token/ERC20/extensions/IERC20Permit.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import "@openzeppelin/contracts/access/Ownable2Step.sol";
import "@openzeppelin/contracts/utils/Pausable.sol";

/// @title PaktolVaultV2
/// @author P.LECROSNIER
/// @notice ERC-4626 vault routing EURC deposits into Byzantine Finance VaultV2 on Base.
///         Identical fee/harvest logic to PaktolVault — only the yield source changes
///         (Byzantine VaultV2 Morpho-backed ERC-4626 instead of AAVE v3).
///
///         Standard (FEE_BPS = 50, CAP_BPS = 350):
///           - 0.5% annual AUM fee on total capital, pro-rated per harvest.
///           - Fee floor at 2% APY: below that, fee scales down with yield.
///           - User net yield capped at 3.5% per year.
///           - AUM fee + surplus above cap → treasury.
///
///         Premium — backend-authorized access (FEE_BPS = 50, CAP_BPS = 500):
///           - 0.5% annual AUM fee on total capital, pro-rated per harvest.
///           - Fee floor at 2% APY: below that, fee scales down with yield.
///           - User net yield capped at 5% per year.
///           - AUM fee + surplus above cap → treasury.
///           - Deposits gated by premiumExpiry, granted off-chain via grantPremiumAccess().
///
///         Harvest formula (unified, covers both plans):
///           maxAumFee  = lastTotalAssets × FEE_BPS × elapsed / (BPS_DENOMINATOR × SECONDS_PER_YEAR)
///           flooredFee = grossYield × FEE_BPS / FLOOR_BPS
///           aumFee     = min(maxAumFee, flooredFee)
///           remaining  = grossYield − aumFee
///           toUsers    = min(remaining, maxNetYield)
///           toTreasury = grossYield − toUsers
///
contract PaktolVaultV2 is ERC4626, Ownable2Step, Pausable, ReentrancyGuard {
    using SafeERC20 for IERC20;

    /* ─────────────────────────── CONSTANTS ─────────────────────────── */

    uint256 public constant BPS_DENOMINATOR = 10_000;
    uint256 public constant SECONDS_PER_YEAR = 365 days;

    /// @notice APY floor below which the AUM fee is pro-rated down (200 = 2%).
    uint256 public constant FLOOR_BPS = 200;

    /// @notice Minimum deposit. EURC has 6 decimals: 1e3 = 0.001 EURC. Adjustable by owner.
    uint256 public minDeposit = 1e3;

    /// @notice Minimum time between harvests. Adjustable by owner. Minimum 1 hour.
    uint256 public minHarvestInterval = 1 days;

    uint256 public constant WITHDRAWAL_COOLDOWN = 4 hours;

    /* ─────────────────────────── IMMUTABLES ────────────────────────── */

    uint256 public immutable CAP_BPS;
    uint256 public immutable FEE_BPS;
    address public immutable TREASURY;

    /// @notice Byzantine Finance VaultV2 (ERC-4626, Morpho-backed).
    ///         Must accept EURC as its underlying asset.
    ///         Paktol's deployer address must be whitelisted on Byzantine's GateWhitelist
    ///         before any deposit can succeed.
    IERC4626 public immutable BYZANTINE_VAULT;

    uint256 public immutable MAX_TVL;
    bool public immutable REQUIRES_AUTH;

    /* ───────────────────────────── STORAGE ─────────────────────────── */

    uint256 public lastTotalAssets;
    uint256 public lastTreasuryAssets;
    uint256 public lastHarvestTimestamp;
    mapping(address => uint256) public depositTimestamp;
    mapping(address => uint256) public premiumExpiry;
    address public guardian;
    address public harvester;

    /// @notice Backend EOA allowed to call grantPremiumAccess() only.
    ///         address(0) = disabled (only owner can grant). Changeable by owner (Safe).
    address public granter;

    /* ───────────────────────────── EVENTS ──────────────────────────── */

    event Harvested(uint256 grossYield, uint256 toTreasury, uint256 toUsers, uint256 timestamp);
    event HarvestSkipped(uint256 totalAssets, uint256 timestamp);
    event GuardianChanged(address indexed oldGuardian, address indexed newGuardian);
    event HarvesterChanged(address indexed oldHarvester, address indexed newHarvester);
    event GranterChanged(address indexed oldGranter, address indexed newGranter);
    event MinHarvestIntervalUpdated(uint256 oldInterval, uint256 newInterval);
    event MinDepositUpdated(uint256 oldMinDeposit, uint256 newMinDeposit);
    event EmergencyExitV2(uint256 amount, uint256 timestamp);
    event PremiumAccessGranted(address indexed user, uint256 expiry);

    /* ───────────────────────────── ERRORS ──────────────────────────── */

    error ZeroAddress(string param);
    error ByzantineVaultAssetMismatch(address byzantineAsset, address expected);
    error CapOutOfRange(uint256 provided);
    error FeeOutOfRange(uint256 provided);
    error NotGuardian();
    error NotHarvester();
    error NotGranter();
    error IntervalTooShort(uint256 provided, uint256 minimum);
    error DepositTooSmall(uint256 assets, uint256 minimum);
    error TvlCapExceeded(uint256 current, uint256 cap);
    error HarvestTooFrequent(uint256 elapsed, uint256 minimum);
    error InsufficientAllowance();
    error PremiumAccessExpired(uint256 expiredAt);
    error WithdrawalCooldown(uint256 availableAt);
    error RolesNotSeparated();

    /* ─────────────────────────── CONSTRUCTOR ───────────────────────── */

    /// @param asset_          EURC token address (6 decimals).
    /// @param name_           Share token name.
    /// @param symbol_         Share token symbol.
    /// @param owner_          Initial owner — multisig in production.
    /// @param treasury_       Receives fee + yield surplus. Cannot be address(0).
    /// @param capBps_         Annual net yield cap in bps. Range: 1–10_000.
    /// @param feeBps_         Fixed fee on gross yield in bps. 50 = Standard, 0 = Paktol.
    /// @param guardian_       Emergency pause address. Cannot be address(0).
    /// @param harvester_      Keeper bot allowed to call harvest(). Cannot be address(0).
    /// @param granter_        Backend EOA for grantPremiumAccess(). address(0) = disabled.
    /// @param byzantineVault_ Byzantine Finance VaultV2 address. Must accept EURC.
    /// @param maxTvl_            Maximum total assets. 0 = uncapped.
    /// @param requiresAuth_      If true, deposits require active premiumExpiry.
    constructor(
        IERC20  asset_,
        string memory name_,
        string memory symbol_,
        address owner_,
        address treasury_,
        uint256 capBps_,
        uint256 feeBps_,
        address guardian_,
        address harvester_,
        address granter_,
        address byzantineVault_,
        uint256 maxTvl_,
        bool    requiresAuth_
    ) ERC4626(asset_) ERC20(name_, symbol_) Ownable(owner_) {
        if (address(asset_) == address(0)) revert ZeroAddress("asset");
        if (treasury_       == address(0)) revert ZeroAddress("treasury");
        if (guardian_       == address(0)) revert ZeroAddress("guardian");
        if (harvester_      == address(0)) revert ZeroAddress("harvester");
        if (byzantineVault_ == address(0)) revert ZeroAddress("byzantineVault");
        if (capBps_ == 0 || capBps_ > BPS_DENOMINATOR) revert CapOutOfRange(capBps_);
        if (feeBps_ > FLOOR_BPS) revert FeeOutOfRange(feeBps_);
        if (owner_ == guardian_ || owner_ == harvester_ || guardian_ == harvester_) revert RolesNotSeparated();
        if (granter_ != address(0)) {
            if (granter_ == owner_ || granter_ == guardian_ || granter_ == harvester_) revert RolesNotSeparated();
        }

        address byzantineAsset = IERC4626(byzantineVault_).asset();
        if (byzantineAsset != address(asset_)) revert ByzantineVaultAssetMismatch(byzantineAsset, address(asset_));

        TREASURY        = treasury_;
        CAP_BPS         = capBps_;
        FEE_BPS         = feeBps_;
        guardian        = guardian_;
        harvester       = harvester_;
        granter         = granter_;
        BYZANTINE_VAULT = IERC4626(byzantineVault_);
        MAX_TVL         = maxTvl_;
        REQUIRES_AUTH   = requiresAuth_;

        lastHarvestTimestamp = block.timestamp;
    }

    /* ───────────────────────── VIRTUAL SHARES ──────────────────────── */

    function _decimalsOffset() internal pure override returns (uint8) {
        return 3;
    }

    /* ──────────────────────── ERC-4626 OVERRIDES ───────────────────── */

    function maxDeposit(address) public view override returns (uint256) {
        if (paused()) return 0;
        if (MAX_TVL == 0) return type(uint256).max;
        uint256 current = totalAssets();
        return current >= MAX_TVL ? 0 : MAX_TVL - current;
    }

    function maxMint(address receiver) public view override returns (uint256) {
        uint256 maxDep = maxDeposit(receiver);
        if (maxDep == type(uint256).max) return type(uint256).max;
        return previewDeposit(maxDep);
    }

    function _byzantineLiquid() internal view returns (uint256) {
        uint256 idle      = IERC20(asset()).balanceOf(address(this));
        uint256 byzShares = BYZANTINE_VAULT.balanceOf(address(this));
        uint256 byzAssets = byzShares > 0 ? BYZANTINE_VAULT.convertToAssets(byzShares) : 0;
        return idle + byzAssets;
    }

    /// @notice Returns 0 within WITHDRAWAL_COOLDOWN window (vault not paused).
    ///         Liquid = idle EURC + Byzantine position (convertToAssets of our shares).
    ///         Using convertToAssets instead of BYZANTINE_VAULT.maxWithdraw() because
    ///         some vaults (e.g. MetaMorpho sandbox with no configured markets) return
    ///         maxWithdraw=0 even when funds are fully redeemable.
    ///         Treasury is exempt: its depositTimestamp is never set (stays 0), so the
    ///         cooldown check is always false — fee shares can be redeemed immediately.
    function maxWithdraw(address owner_) public view override returns (uint256) {
        if (!paused() && owner_ != TREASURY && block.timestamp < depositTimestamp[owner_] + WITHDRAWAL_COOLDOWN) return 0;
        uint256 userAssets = convertToAssets(balanceOf(owner_));
        uint256 liquid     = _byzantineLiquid();
        return userAssets < liquid ? userAssets : liquid;
    }

    /// @notice Returns 0 within WITHDRAWAL_COOLDOWN window (vault not paused).
    ///         Treasury exempt — see maxWithdraw.
    function maxRedeem(address owner_) public view override returns (uint256) {
        if (!paused() && owner_ != TREASURY && block.timestamp < depositTimestamp[owner_] + WITHDRAWAL_COOLDOWN) return 0;
        uint256 userShares = balanceOf(owner_);
        uint256 liquid     = _byzantineLiquid();
        uint256 userAssets = convertToAssets(userShares);
        if (userAssets <= liquid) return userShares;
        return convertToShares(liquid);
    }

    /* ──────────────────────────── TOTAL ASSETS ─────────────────────── */

    /// @notice Byzantine shares converted to EURC + any idle EURC held by this vault.
    function totalAssets() public view override returns (uint256) {
        uint256 bzyShares = BYZANTINE_VAULT.balanceOf(address(this));
        uint256 bzyValue  = bzyShares > 0 ? BYZANTINE_VAULT.convertToAssets(bzyShares) : 0;
        return bzyValue + IERC20(asset()).balanceOf(address(this));
    }

    /* ─────────────────────── BYZANTINE ROUTING ─────────────────────── */

    /// @dev Pushes all idle EURC into Byzantine VaultV2. Called after every deposit/mint.
    ///      Byzantine's maxDeposit() always returns 0 by design — the real gate check
    ///      happens inside deposit() itself via canSendAssets / canReceiveShares.
    function _depositToByzantine() internal {
        uint256 amount = IERC20(asset()).balanceOf(address(this));
        if (amount == 0) return;
        IERC20(asset()).forceApprove(address(BYZANTINE_VAULT), amount);
        BYZANTINE_VAULT.deposit(amount, address(this));
    }

    /* ──────────────────────── DEPOSIT / WITHDRAW ───────────────────── */

    function _syncLastTotalAssets(int256 delta) internal {
        if (delta >= 0) {
            // forge-lint: disable-next-line(unsafe-typecast)
            lastTotalAssets += uint256(delta);
        } else {
            // forge-lint: disable-next-line(unsafe-typecast)
            uint256 decrease = uint256(-delta);
            lastTotalAssets = lastTotalAssets > decrease ? lastTotalAssets - decrease : 0;
        }
    }

    function _executeDeposit(uint256 assets, address receiver) internal returns (uint256) {
        if (assets < minDeposit) revert DepositTooSmall(assets, minDeposit);
        uint256 current = totalAssets();
        if (MAX_TVL != 0 && current + assets > MAX_TVL) revert TvlCapExceeded(current, MAX_TVL);
        uint256 shares = super.deposit(assets, receiver);
        _depositToByzantine();
        // forge-lint: disable-next-line(unsafe-typecast)
        _syncLastTotalAssets(int256(assets));
        depositTimestamp[receiver] = block.timestamp;
        return shares;
    }

    function deposit(uint256 assets, address receiver) public override whenNotPaused nonReentrant returns (uint256) {
        if (REQUIRES_AUTH && block.timestamp > premiumExpiry[receiver])
            revert PremiumAccessExpired(premiumExpiry[receiver]);
        return _executeDeposit(assets, receiver);
    }

    function depositUpToCap(
        uint256 assets,
        address receiver
    ) external whenNotPaused nonReentrant returns (uint256 accepted, uint256 shares) {
        if (REQUIRES_AUTH && block.timestamp > premiumExpiry[receiver])
            revert PremiumAccessExpired(premiumExpiry[receiver]);
        uint256 remaining = maxDeposit(receiver);
        if (remaining == 0) return (0, 0);
        accepted = assets > remaining ? remaining : assets;
        shares = _executeDeposit(accepted, receiver);
    }

    /// @dev F-13: permit is only called when allowance is insufficient.
    ///      If permit fails (nonce unchanged), revert — prevents a third party from
    ///      triggering a deposit against a residual pre-existing allowance via an
    ///      invalid/expired permit signature.
    function depositWithPermit(
        uint256 assets,
        address receiver,
        uint256 deadline,
        uint8 v, bytes32 r, bytes32 s
    ) external whenNotPaused nonReentrant returns (uint256) {
        if (REQUIRES_AUTH && block.timestamp > premiumExpiry[receiver])
            revert PremiumAccessExpired(premiumExpiry[receiver]);
        if (assets < minDeposit) revert DepositTooSmall(assets, minDeposit);
        if (IERC20(asset()).allowance(msg.sender, address(this)) < assets) {
            uint256 nonceBefore = IERC20Permit(asset()).nonces(msg.sender);
            try IERC20Permit(asset()).permit(msg.sender, address(this), assets, deadline, v, r, s) { } catch { }
            if (IERC20Permit(asset()).nonces(msg.sender) == nonceBefore) revert InsufficientAllowance();
        }
        return _executeDeposit(assets, receiver);
    }

    function mint(uint256 shares, address receiver) public override whenNotPaused nonReentrant returns (uint256) {
        if (REQUIRES_AUTH && block.timestamp > premiumExpiry[receiver])
            revert PremiumAccessExpired(premiumExpiry[receiver]);
        uint256 assets = previewMint(shares);
        if (assets < minDeposit) revert DepositTooSmall(assets, minDeposit);
        uint256 current = totalAssets();
        if (MAX_TVL != 0 && current + assets > MAX_TVL) revert TvlCapExceeded(current, MAX_TVL);
        uint256 assetsUsed = super.mint(shares, receiver);
        _depositToByzantine();
        // forge-lint: disable-next-line(unsafe-typecast)
        _syncLastTotalAssets(int256(assetsUsed));
        depositTimestamp[receiver] = block.timestamp;
        return assetsUsed;
    }

    function withdraw(uint256 assets, address receiver, address owner_) public override nonReentrant returns (uint256) {
        if (!paused() && block.timestamp < depositTimestamp[owner_] + WITHDRAWAL_COOLDOWN) {
            revert WithdrawalCooldown(depositTimestamp[owner_] + WITHDRAWAL_COOLDOWN);
        }
        uint256 shares = super.withdraw(assets, receiver, owner_);
        // forge-lint: disable-next-line(unsafe-typecast)
        _syncLastTotalAssets(-int256(assets));
        return shares;
    }

    function redeem(uint256 shares, address receiver, address owner_) public override nonReentrant returns (uint256) {
        if (!paused() && block.timestamp < depositTimestamp[owner_] + WITHDRAWAL_COOLDOWN) {
            revert WithdrawalCooldown(depositTimestamp[owner_] + WITHDRAWAL_COOLDOWN);
        }
        uint256 assets = super.redeem(shares, receiver, owner_);
        // forge-lint: disable-next-line(unsafe-typecast)
        _syncLastTotalAssets(-int256(assets));
        return assets;
    }

    function _update(address from, address to, uint256 amount) internal override {
        super._update(from, to, amount);
        if (from != address(0) && to != address(0)) {
            if (depositTimestamp[from] > depositTimestamp[to]) {
                depositTimestamp[to] = depositTimestamp[from];
            }
        }
    }

    /// @dev CEI: shares burned → emit → pull from Byzantine → transfer to receiver.
    function _withdraw(
        address caller,
        address receiver,
        address owner_,
        uint256 assets,
        uint256 shares
    ) internal override {
        if (caller != owner_) _spendAllowance(owner_, caller, shares);
        _burn(owner_, shares);
        emit Withdraw(caller, receiver, owner_, assets, shares);
        uint256 idle = IERC20(asset()).balanceOf(address(this));
        if (idle < assets) {
            BYZANTINE_VAULT.withdraw(assets - idle, address(this), address(this));
        }
        IERC20(asset()).safeTransfer(receiver, assets);
    }

    /* ───────────────────────────── HARVEST ─────────────────────────── */

    /// @notice Collects yield since last harvest and routes it per plan rules.
    ///         Callable by owner or harvester.
    ///         Treasury fee is minted as vault shares (Morpho pattern) — no Byzantine
    ///         withdrawal at harvest time. Treasury shares compound at Morpho APY and
    ///         are redeemable anytime via redeem(). Treasury is excluded from AUM fee
    ///         and cap calculations so its shares earn uncapped Morpho yield.
    function harvest() external nonReentrant whenNotPaused {
        if (msg.sender != owner() && msg.sender != harvester) revert NotHarvester();

        uint256 elapsed = block.timestamp - lastHarvestTimestamp;
        if (elapsed < minHarvestInterval) revert HarvestTooFrequent(elapsed, minHarvestInterval);

        uint256 current = totalAssets();

        if (current <= lastTotalAssets) {
            lastTotalAssets    = current;
            lastTreasuryAssets = convertToAssets(balanceOf(TREASURY));
            emit HarvestSkipped(current, block.timestamp);
            return;
        }

        uint256 grossYield = current - lastTotalAssets;

        // Both snapshots from the same point in time — no timing mismatch.
        // lastTreasuryAssets is set at the end of each harvest, same block as lastTotalAssets.
        uint256 userAssets = lastTotalAssets > lastTreasuryAssets
            ? lastTotalAssets - lastTreasuryAssets
            : 0;

        // userYield: yield attributable to user capital only (proportional split).
        uint256 userYield  = lastTotalAssets > 0
            ? grossYield * userAssets / lastTotalAssets
            : grossYield;

        uint256 maxAumFee  = (userAssets * FEE_BPS * elapsed) / (BPS_DENOMINATOR * SECONDS_PER_YEAR);
        uint256 flooredFee = (userYield * FEE_BPS) / FLOOR_BPS;
        uint256 aumFee     = maxAumFee < flooredFee ? maxAumFee : flooredFee;

        uint256 remaining   = grossYield - aumFee;
        uint256 maxNetYield = (userAssets * CAP_BPS * elapsed) / (BPS_DENOMINATOR * SECONDS_PER_YEAR);
        uint256 toUsers     = remaining < maxNetYield ? remaining : maxNetYield;
        uint256 toTreasury  = grossYield - toUsers;

        // Treasury stays in vault — full pool is the new baseline.
        lastTotalAssets      = current;
        lastHarvestTimestamp = block.timestamp;

        emit Harvested(grossYield, toTreasury, toUsers, block.timestamp);

        // Morpho pattern: mint shares to treasury instead of withdrawing assets.
        // feeShares chosen so treasury receives exactly toTreasury EURC worth of shares.
        if (toTreasury > 0) {
            uint256 denom = current - toTreasury;
            if (denom == 0) denom = 1;
            uint256 feeShares = toTreasury
                * (totalSupply() + 10 ** _decimalsOffset())
                / denom;
            _mint(TREASURY, feeShares);
        }

        // Snapshot treasury value post-mint — used as baseline for next harvest's userAssets.
        lastTreasuryAssets = convertToAssets(balanceOf(TREASURY));
    }

    /* ───────────────────────────── GUARDIAN ────────────────────────── */

    /// @notice Grants time-limited access to the premium vault.
    ///         Callable by owner or granter (backend EOA).
    function grantPremiumAccess(address user, uint256 duration) external {
        if (msg.sender != owner() && msg.sender != granter) revert NotGranter();
        if (user == address(0)) revert ZeroAddress("user");
        uint256 expiry = block.timestamp + duration;
        premiumExpiry[user] = expiry;
        emit PremiumAccessGranted(user, expiry);
    }

    function setGranter(address newGranter) external onlyOwner {
        if (newGranter != address(0)) {
            if (newGranter == owner() || newGranter == guardian || newGranter == harvester)
                revert RolesNotSeparated();
        }
        emit GranterChanged(granter, newGranter);
        granter = newGranter;
    }

    function setMinHarvestInterval(uint256 newInterval) external onlyOwner {
        if (newInterval < 1 hours) revert IntervalTooShort(newInterval, 1 hours);
        emit MinHarvestIntervalUpdated(minHarvestInterval, newInterval);
        minHarvestInterval = newInterval;
    }

    function setMinDeposit(uint256 newMinDeposit) external onlyOwner {
        emit MinDepositUpdated(minDeposit, newMinDeposit);
        minDeposit = newMinDeposit;
    }

    function transferOwnership(address newOwner) public override onlyOwner {
        if (newOwner == guardian || newOwner == harvester || newOwner == granter) revert RolesNotSeparated();
        super.transferOwnership(newOwner);
    }

    function setGuardian(address newGuardian_) external onlyOwner {
        if (newGuardian_ == address(0)) revert ZeroAddress("newGuardian");
        if (newGuardian_ == owner() || newGuardian_ == harvester || newGuardian_ == granter) revert RolesNotSeparated();
        emit GuardianChanged(guardian, newGuardian_);
        guardian = newGuardian_;
    }

    function setHarvester(address newHarvester_) external onlyOwner {
        if (newHarvester_ == address(0)) revert ZeroAddress("newHarvester");
        if (newHarvester_ == owner() || newHarvester_ == guardian || newHarvester_ == granter) revert RolesNotSeparated();
        emit HarvesterChanged(harvester, newHarvester_);
        harvester = newHarvester_;
    }

    /* ──────────────────────────────  PAUSE  ────────────────────────── */

    function pause() external {
        if (msg.sender != owner() && msg.sender != guardian) revert NotGuardian();
        _pause();
    }

    function unpause() external onlyOwner {
        _unpause();
    }

    /* ────────────────────────── EMERGENCY EXIT ──────────────────────── */

    /// @notice Redeems all Byzantine shares back to idle EURC in this vault.
    ///         Pauses deposits atomically. Users can still withdraw from idle balance.
    function emergencyExitByzantine() external onlyOwner nonReentrant {
        if (!paused()) _pause();
        uint256 shares = BYZANTINE_VAULT.balanceOf(address(this));
        if (shares == 0) return;
        uint256 withdrawn = BYZANTINE_VAULT.redeem(shares, address(this), address(this));
        lastTotalAssets      = totalAssets();
        lastTreasuryAssets   = convertToAssets(balanceOf(TREASURY));
        lastHarvestTimestamp = block.timestamp;
        emit EmergencyExitV2(withdrawn, block.timestamp);
    }
}
