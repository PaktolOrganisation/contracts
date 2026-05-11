// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "@openzeppelin/contracts/token/ERC20/extensions/ERC4626.sol";
import "@openzeppelin/contracts/interfaces/IERC4626.sol";
import "@openzeppelin/contracts/token/ERC20/extensions/IERC20Permit.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import "@openzeppelin/contracts/access/Ownable2Step.sol";
import "@openzeppelin/contracts/utils/Pausable.sol";
import "@openzeppelin/contracts/utils/cryptography/ECDSA.sol";

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
///         Premium — points tier or legal entity (FEE_BPS = 50, CAP_BPS = 500):
///           - 0.5% annual AUM fee on total capital, pro-rated per harvest.
///           - Fee floor at 2% APY: below that, fee scales down with yield.
///           - User net yield capped at 5% per year.
///           - AUM fee + surplus above cap → treasury.
///           - Deposits gated via depositWithAuth() — backend signs when tier is active.
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

    bytes32 public constant DEPOSIT_AUTH_TYPEHASH =
        keccak256("DepositAuth(address sender,uint256 assets,address receiver,uint256 deadline,uint256 nonce)");

    /// @notice APY floor below which the AUM fee is pro-rated down (200 = 2%).
    uint256 public constant FLOOR_BPS = 200;

    /// @notice Minimum deposit. EURC has 6 decimals: 1e3 = 0.001 EURC.
    uint256 public constant MIN_DEPOSIT = 1e3;

    uint256 public constant MIN_HARVEST_INTERVAL = 1 days;

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
    address public immutable SIGNER;
    bool public immutable REQUIRES_AUTH;
    bytes32 public immutable DOMAIN_SEPARATOR;

    /* ───────────────────────────── STORAGE ─────────────────────────── */

    uint256 public lastTotalAssets;
    mapping(address => uint256) public nonces;
    uint256 public lastHarvestTimestamp;
    mapping(address => uint256) public depositTimestamp;
    address public guardian;
    address public harvester;

    /* ───────────────────────────── EVENTS ──────────────────────────── */

    event Harvested(uint256 grossYield, uint256 toTreasury, uint256 toUsers, uint256 timestamp);
    event GuardianChanged(address indexed oldGuardian, address indexed newGuardian);
    event HarvesterChanged(address indexed oldHarvester, address indexed newHarvester);
    event EmergencyExitV2(uint256 amount, uint256 timestamp);

    /* ───────────────────────────── ERRORS ──────────────────────────── */

    error ZeroAddress(string param);
    error ByzantineVaultAssetMismatch(address byzantineAsset, address expected);
    error CapOutOfRange(uint256 provided);
    error FeeOutOfRange(uint256 provided);
    error NotGuardian();
    error NotHarvester();
    error DepositTooSmall(uint256 assets, uint256 minimum);
    error TvlCapExceeded(uint256 current, uint256 cap);
    error HarvestTooFrequent(uint256 elapsed, uint256 minimum);
    error InsufficientAllowance();
    error UseDepositWithAuth();
    error InvalidSignature();
    error SignatureExpired();
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
    /// @param byzantineVault_ Byzantine Finance VaultV2 address. Must accept EURC.
    /// @param maxTvl_         Maximum total assets. 0 = uncapped.
    /// @param signer_         Backend wallet that signs depositWithAuth. Cannot be address(0).
    /// @param requiresAuth_   If true, only depositWithAuth() is accepted.
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
        address byzantineVault_,
        uint256 maxTvl_,
        address signer_,
        bool    requiresAuth_
    ) ERC4626(asset_) ERC20(name_, symbol_) Ownable(owner_) {
        if (address(asset_) == address(0)) revert ZeroAddress("asset");
        if (treasury_       == address(0)) revert ZeroAddress("treasury");
        if (guardian_       == address(0)) revert ZeroAddress("guardian");
        if (harvester_      == address(0)) revert ZeroAddress("harvester");
        if (byzantineVault_ == address(0)) revert ZeroAddress("byzantineVault");
        if (signer_         == address(0)) revert ZeroAddress("signer");
        if (capBps_ == 0 || capBps_ > BPS_DENOMINATOR) revert CapOutOfRange(capBps_);
        if (feeBps_ > FLOOR_BPS) revert FeeOutOfRange(feeBps_);
        if (owner_ == guardian_ || owner_ == harvester_ || guardian_ == harvester_) revert RolesNotSeparated();

        address byzantineAsset = IERC4626(byzantineVault_).asset();
        if (byzantineAsset != address(asset_)) revert ByzantineVaultAssetMismatch(byzantineAsset, address(asset_));

        TREASURY       = treasury_;
        CAP_BPS        = capBps_;
        FEE_BPS        = feeBps_;
        guardian       = guardian_;
        harvester      = harvester_;
        BYZANTINE_VAULT = IERC4626(byzantineVault_);
        MAX_TVL        = maxTvl_;
        SIGNER         = signer_;
        REQUIRES_AUTH  = requiresAuth_;

        DOMAIN_SEPARATOR = keccak256(abi.encode(
            keccak256("EIP712Domain(string name,string version,uint256 chainId,address verifyingContract)"),
            keccak256(bytes(name_)),
            keccak256("1"),
            block.chainid,
            address(this)
        ));

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

    /// @notice Returns 0 within WITHDRAWAL_COOLDOWN window (vault not paused).
    ///         Bounded by Byzantine's available liquidity (Morpho redemption queue).
    function maxWithdraw(address owner_) public view override returns (uint256) {
        if (!paused() && block.timestamp < depositTimestamp[owner_] + WITHDRAWAL_COOLDOWN) return 0;
        uint256 userAssets = convertToAssets(balanceOf(owner_));
        uint256 idle       = IERC20(asset()).balanceOf(address(this));
        uint256 liquid     = idle + BYZANTINE_VAULT.maxWithdraw(address(this));
        return userAssets < liquid ? userAssets : liquid;
    }

    /// @notice Returns 0 within WITHDRAWAL_COOLDOWN window (vault not paused).
    function maxRedeem(address owner_) public view override returns (uint256) {
        if (!paused() && block.timestamp < depositTimestamp[owner_] + WITHDRAWAL_COOLDOWN) return 0;
        uint256 userShares = balanceOf(owner_);
        uint256 idle       = IERC20(asset()).balanceOf(address(this));
        uint256 liquid     = idle + BYZANTINE_VAULT.maxWithdraw(address(this));
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
    function _depositToByzantine() internal {
        uint256 amount = IERC20(asset()).balanceOf(address(this));
        if (amount == 0) return;
        IERC20(asset()).forceApprove(address(BYZANTINE_VAULT), amount);
        BYZANTINE_VAULT.deposit(amount, address(this));
    }

    /// @dev Pulls EURC from Byzantine. Uses idle balance first, then withdraws remainder.
    function _withdrawFromByzantine(uint256 amount, address to) internal {
        uint256 idle   = IERC20(asset()).balanceOf(address(this));
        uint256 needed = idle >= amount ? 0 : amount - idle;
        if (needed > 0) {
            BYZANTINE_VAULT.withdraw(needed, address(this), address(this));
        }
        if (to != address(this)) {
            IERC20(asset()).safeTransfer(to, amount);
        }
    }

    /* ──────────────────────── DEPOSIT / WITHDRAW ───────────────────── */

    function _syncLastTotalAssets(int256 delta) internal {
        if (delta >= 0) {
            lastTotalAssets += uint256(delta);
        } else {
            uint256 decrease = uint256(-delta);
            lastTotalAssets = lastTotalAssets > decrease ? lastTotalAssets - decrease : 0;
        }
    }

    function _executeDeposit(uint256 assets, address receiver) internal returns (uint256) {
        if (assets < MIN_DEPOSIT) revert DepositTooSmall(assets, MIN_DEPOSIT);
        uint256 current = totalAssets();
        if (MAX_TVL != 0 && current + assets > MAX_TVL) revert TvlCapExceeded(current, MAX_TVL);
        uint256 shares = super.deposit(assets, receiver);
        _depositToByzantine();
        _syncLastTotalAssets(int256(assets));
        depositTimestamp[receiver] = block.timestamp;
        return shares;
    }

    function deposit(uint256 assets, address receiver) public override whenNotPaused nonReentrant returns (uint256) {
        if (REQUIRES_AUTH) revert UseDepositWithAuth();
        return _executeDeposit(assets, receiver);
    }

    function depositUpToCap(
        uint256 assets,
        address receiver
    ) external whenNotPaused nonReentrant returns (uint256 accepted, uint256 shares) {
        if (REQUIRES_AUTH) revert UseDepositWithAuth();
        uint256 remaining = maxDeposit(receiver);
        if (remaining == 0) return (0, 0);
        accepted = assets > remaining ? remaining : assets;
        shares = _executeDeposit(accepted, receiver);
    }

    function depositWithPermit(
        uint256 assets,
        address receiver,
        uint256 deadline,
        uint8 v, bytes32 r, bytes32 s
    ) external whenNotPaused nonReentrant returns (uint256) {
        if (REQUIRES_AUTH) revert UseDepositWithAuth();
        if (assets < MIN_DEPOSIT) revert DepositTooSmall(assets, MIN_DEPOSIT);
        try IERC20Permit(asset()).permit(msg.sender, address(this), assets, deadline, v, r, s) { } catch { }
        if (IERC20(asset()).allowance(msg.sender, address(this)) < assets) revert InsufficientAllowance();
        return _executeDeposit(assets, receiver);
    }

    function depositWithAuth(
        uint256 assets,
        address receiver,
        uint256 deadline,
        bytes calldata sig
    ) external whenNotPaused nonReentrant returns (uint256) {
        if (block.timestamp > deadline) revert SignatureExpired();
        bytes32 structHash = keccak256(abi.encode(
            DEPOSIT_AUTH_TYPEHASH,
            msg.sender, assets, receiver, deadline,
            nonces[msg.sender]++
        ));
        bytes32 digest = keccak256(abi.encodePacked("\x19\x01", DOMAIN_SEPARATOR, structHash));
        if (ECDSA.recover(digest, sig) != SIGNER) revert InvalidSignature();
        return _executeDeposit(assets, receiver);
    }

    function mint(uint256 shares, address receiver) public override whenNotPaused nonReentrant returns (uint256) {
        if (REQUIRES_AUTH) revert UseDepositWithAuth();
        uint256 assets = previewMint(shares);
        if (assets < MIN_DEPOSIT) revert DepositTooSmall(assets, MIN_DEPOSIT);
        uint256 current = totalAssets();
        if (MAX_TVL != 0 && current + assets > MAX_TVL) revert TvlCapExceeded(current, MAX_TVL);
        uint256 assetsUsed = super.mint(shares, receiver);
        _depositToByzantine();
        _syncLastTotalAssets(int256(assetsUsed));
        depositTimestamp[receiver] = block.timestamp;
        return assetsUsed;
    }

    function withdraw(uint256 assets, address receiver, address owner_) public override nonReentrant returns (uint256) {
        if (!paused() && block.timestamp < depositTimestamp[owner_] + WITHDRAWAL_COOLDOWN) {
            revert WithdrawalCooldown(depositTimestamp[owner_] + WITHDRAWAL_COOLDOWN);
        }
        uint256 shares = super.withdraw(assets, receiver, owner_);
        _syncLastTotalAssets(-int256(assets));
        return shares;
    }

    function redeem(uint256 shares, address receiver, address owner_) public override nonReentrant returns (uint256) {
        if (!paused() && block.timestamp < depositTimestamp[owner_] + WITHDRAWAL_COOLDOWN) {
            revert WithdrawalCooldown(depositTimestamp[owner_] + WITHDRAWAL_COOLDOWN);
        }
        uint256 assets = super.redeem(shares, receiver, owner_);
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
    function harvest() external nonReentrant {
        if (msg.sender != owner() && msg.sender != harvester) revert NotHarvester();

        uint256 elapsed = block.timestamp - lastHarvestTimestamp;
        if (elapsed < MIN_HARVEST_INTERVAL) revert HarvestTooFrequent(elapsed, MIN_HARVEST_INTERVAL);

        uint256 current = totalAssets();

        if (current <= lastTotalAssets) {
            lastTotalAssets = current;
            return;
        }

        uint256 grossYield = current - lastTotalAssets;

        uint256 maxAumFee  = (lastTotalAssets * FEE_BPS * elapsed) / (BPS_DENOMINATOR * SECONDS_PER_YEAR);
        uint256 flooredFee = (grossYield * FEE_BPS) / FLOOR_BPS;
        uint256 aumFee     = maxAumFee < flooredFee ? maxAumFee : flooredFee;

        uint256 remaining   = grossYield - aumFee;
        uint256 maxNetYield = (lastTotalAssets * CAP_BPS * elapsed) / (BPS_DENOMINATOR * SECONDS_PER_YEAR);
        uint256 toUsers     = remaining < maxNetYield ? remaining : maxNetYield;
        uint256 toTreasury  = grossYield - toUsers;

        lastTotalAssets      = current - toTreasury;
        lastHarvestTimestamp = block.timestamp;

        emit Harvested(grossYield, toTreasury, toUsers, block.timestamp);

        if (toTreasury > 0) {
            _withdrawFromByzantine(toTreasury, TREASURY);
        }
    }

    /* ───────────────────────────── GUARDIAN ────────────────────────── */

    function setGuardian(address newGuardian_) external onlyOwner {
        if (newGuardian_ == address(0)) revert ZeroAddress("newGuardian");
        if (newGuardian_ == owner() || newGuardian_ == harvester) revert RolesNotSeparated();
        emit GuardianChanged(guardian, newGuardian_);
        guardian = newGuardian_;
    }

    function setHarvester(address newHarvester_) external onlyOwner {
        if (newHarvester_ == address(0)) revert ZeroAddress("newHarvester");
        if (newHarvester_ == owner() || newHarvester_ == guardian) revert RolesNotSeparated();
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
        lastHarvestTimestamp = block.timestamp;
        emit EmergencyExitV2(withdrawn, block.timestamp);
    }
}
