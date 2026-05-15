// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "forge-std/Test.sol";
import "@openzeppelin/contracts/token/ERC20/extensions/ERC4626.sol";
import "@openzeppelin/contracts/token/ERC20/extensions/ERC20Permit.sol";
import "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import "../src/PaktolVaultV2.sol";

/* ─────────────────────────────── MOCKS ─────────────────────────────────── */

contract MockEURC is ERC20Permit {
    constructor() ERC20("Mock EURC", "mEURC") ERC20Permit("Mock EURC") {}
    function decimals() public pure override returns (uint8) { return 6; }
    function mint(address to, uint256 amount) external { _mint(to, amount); }
    function burn(address from, uint256 amount) external { _burn(from, amount); }
}

/// @dev Minimal ERC-4626. simulateYield mints, simulateLoss burns, setLiquidityCap
///      limits maxWithdraw to model Morpho liquidity constraints.
contract MockByzantineVault is ERC4626 {
    uint256 private _liquidityCap = type(uint256).max;

    constructor(IERC20 asset_) ERC4626(asset_) ERC20("Mock Byzantine", "mBZY") {}

    function simulateYield(uint256 amount) external {
        MockEURC(asset()).mint(address(this), amount);
    }

    function simulateLoss(uint256 amount) external {
        MockEURC(asset()).burn(address(this), amount);
    }

    function setLiquidityCap(uint256 cap) external {
        _liquidityCap = cap;
    }

    function maxWithdraw(address owner_) public view override returns (uint256) {
        uint256 full = super.maxWithdraw(owner_);
        return full < _liquidityCap ? full : _liquidityCap;
    }
}

/* ─────────────────────────────── BASE ──────────────────────────────────── */

contract PaktolVaultV2Base is Test {
    MockEURC             internal eurc;
    MockByzantineVault   internal mockStd;
    MockByzantineVault   internal mockPkt;
    PaktolVaultV2        internal vaultStd;  // Standard — FEE 0.5%, CAP 3.5%, open
    PaktolVaultV2        internal vaultPkt;  // Premium  — FEE 0.5%, CAP 5%, points-gated

    address internal owner     = makeAddr("owner");
    address internal treasury  = makeAddr("treasury");
    address internal guardian  = makeAddr("guardian");
    address internal harvester = makeAddr("harvester");
    address internal user      = makeAddr("user");
    address internal user2     = makeAddr("user2");

    uint256 internal constant PERMIT_USER_KEY = 0xA11CE;

    uint256 constant CAP_STD = 350;
    uint256 constant CAP_PKT = 500;
    uint256 constant FEE_STD = 50;
    uint256 constant FEE_PKT = 50;

    uint256 constant PREMIUM_THRESHOLD = 100;

    uint256 constant DEPOSIT      = 1_000e6;
    uint256 constant USER_BALANCE = 10_000e6;

    function setUp() public virtual {
        eurc    = new MockEURC();
        mockStd = new MockByzantineVault(IERC20(address(eurc)));
        mockPkt = new MockByzantineVault(IERC20(address(eurc)));

        vaultStd = new PaktolVaultV2(
            IERC20(address(eurc)), "Paktol Standard", "pkEURC-S",
            owner, treasury, CAP_STD, FEE_STD, guardian, harvester,
            address(mockStd), 0, 0, false
        );
        vaultPkt = new PaktolVaultV2(
            IERC20(address(eurc)), "Paktol Subscription", "pkEURC-P",
            owner, treasury, CAP_PKT, FEE_PKT, guardian, harvester,
            address(mockPkt), 0, PREMIUM_THRESHOLD, true
        );

        eurc.mint(user,  USER_BALANCE);
        eurc.mint(user2, USER_BALANCE);
    }

    function _warp(uint256 delta) internal { vm.warp(block.timestamp + delta); }

    function _deposit(PaktolVaultV2 vault_, address who, uint256 amount) internal returns (uint256 shares) {
        eurc.mint(who, amount);
        vm.startPrank(who);
        eurc.approve(address(vault_), amount);
        shares = vault_.deposit(amount, who);
        vm.stopPrank();
    }

    /// @dev Grant 15-day premium access then deposit into vaultPkt.
    function _depositPremium(address who, uint256 amount) internal returns (uint256 shares) {
        vm.prank(owner);
        vaultPkt.grantPremiumAccess(who, 15 days);
        shares = _deposit(vaultPkt, who, amount);
    }

    function _signPermit(
        address spender_,
        address owner_,
        uint256 ownerKey_,
        uint256 amount_,
        uint256 deadline_
    ) internal view returns (uint8 v, bytes32 r, bytes32 s) {
        bytes32 PERMIT_TYPEHASH =
            keccak256("Permit(address owner,address spender,uint256 value,uint256 nonce,uint256 deadline)");
        bytes32 structHash =
            keccak256(abi.encode(PERMIT_TYPEHASH, owner_, spender_, amount_, eurc.nonces(owner_), deadline_));
        bytes32 digest = keccak256(abi.encodePacked("\x19\x01", eurc.DOMAIN_SEPARATOR(), structHash));
        (v, r, s) = vm.sign(ownerKey_, digest);
    }
}
