// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

interface IERC20 {
    function transferFrom(address from, address to, uint256 amount) external returns (bool);
    function transfer(address to, uint256 amount) external returns (bool);
}

/**
 * @title SepoliaUsdcEscrow
 * @notice Escrow minimal pour smoke-tester Striga → Privy → dépôt on-chain.
 *         Asset = USDC Circle Sepolia. Remplacer via env par le SC Paktol Ethereum en prod.
 */
contract SepoliaUsdcEscrow {
    IERC20 public constant USDC =
        IERC20(0x1c7D4B196Cb0C7B01d743Fbc6116a902379C7238);

    mapping(address => uint256) public deposited;

    event Deposited(address indexed user, uint256 amount);
    event Withdrawn(address indexed user, uint256 amount);

    function deposit(uint256 amount) external {
        require(amount > 0, "zero amount");
        deposited[msg.sender] += amount;
        require(USDC.transferFrom(msg.sender, address(this), amount), "transferFrom failed");
        emit Deposited(msg.sender, amount);
    }

    /// @notice Sandbox / relayer : crédite `user` en tirant l'USDC depuis msg.sender.
    function depositFor(address user, uint256 amount) external {
        require(user != address(0), "zero user");
        require(amount > 0, "zero amount");
        deposited[user] += amount;
        require(USDC.transferFrom(msg.sender, address(this), amount), "transferFrom failed");
        emit Deposited(user, amount);
    }

    function withdraw(uint256 amount) external {
        require(amount > 0, "zero amount");
        require(deposited[msg.sender] >= amount, "insufficient");
        deposited[msg.sender] -= amount;
        require(USDC.transfer(msg.sender, amount), "transfer failed");
        emit Withdrawn(msg.sender, amount);
    }

    /// @notice Sandbox / relayer : sort les fonds de `user` vers `to`
    ///         (ex. adresse dépôt Striga) — msg.sender paie le gas uniquement.
    function withdrawTo(address user, address to, uint256 amount) external {
        require(user != address(0) && to != address(0), "zero addr");
        require(amount > 0, "zero amount");
        require(deposited[user] >= amount, "insufficient");
        deposited[user] -= amount;
        require(USDC.transfer(to, amount), "transfer failed");
        emit Withdrawn(user, amount);
    }
}
