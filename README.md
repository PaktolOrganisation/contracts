# paktol-contracts

ERC-4626 vaults routing stablecoin deposits into yield sources on two chains.

| Version | Chain | Asset | Yield source |
|---------|-------|-------|--------------|
| V1 | Gnosis Chain | EURe (Monerium) | AAVE v3 |
| V2 | Base Mainnet | EURC (Circle) | Byzantine Finance VaultV2 (Morpho-backed) |

Each version ships two vault instances — **Standard** and **Premium**:

| | Standard | Premium |
|--|----------|---------|
| AUM fee | 0.5% / year | 0.5% / year |
| User yield cap | 3.5% / year | 5% / year |
| Access | Open | Points-gated (V2) / Backend-signed EIP-712 (V1) |

## Stack

- Solidity 0.8.24 — OpenZeppelin, AAVE v3 (V1), Byzantine Finance (V2)
- Foundry — 275 unit + fork tests
- Hardhat — business scenario tests (JS)

## Run

```bash
# Foundry (unit tests, no fork)
forge build
forge test --no-match-path "*/fork*"

# Fork tests — V1 (requires Gnosis archive node)
GNOSIS_RPC_URL=https://... forge test --match-contract PaktolVaultForkTest

# Fork tests — V2 (requires Base mainnet RPC)
forge test --match-contract PaktolVaultV2ForkBase --fork-url https://mainnet.base.org

# Hardhat (V1 business scenarios)
npm install
npm test
```

## Deploy

```bash
cp .env.example .env  # fill in keys + addresses

# V1 — Gnosis Chain
forge script script/Deploy.s.sol --rpc-url $GNOSIS_RPC_URL --broadcast --verify

# V1 — Sepolia (MockAavePool)
forge script script/DeploySepolia.s.sol --rpc-url $SEPOLIA_RPC_URL --broadcast

# V2 — Base Mainnet
forge script script/DeployBaseV2.s.sol --rpc-url $BASE_RPC_URL --broadcast --verify

# V2 — Sepolia
forge script script/DeploySepoliaV2.s.sol --rpc-url $SEPOLIA_RPC_URL --broadcast
```

## Structure

```
src/
  PaktolVault.sol          — V1: EURe → AAVE v3 (Gnosis)
  PaktolVaultV2.sol        — V2: EURC → Byzantine Finance (Base)
  interfaces/
    IAavePool.sol

test/
  PaktolVault.t.sol              — V1 unit tests
  PaktolVault.erc4626.t.sol      — V1 a16z ERC-4626 compliance suite
  PaktolVault.fork.t.sol         — V1 fork tests (Gnosis mainnet)
  PaktolVault.scenarios.js       — V1 Hardhat business scenarios
  PaktolVaultV2.admin.t.sol      — V2 admin / role tests
  PaktolVaultV2.constructor.t.sol
  PaktolVaultV2.deposit.t.sol
  PaktolVaultV2.emergency.t.sol
  PaktolVaultV2.harvest.t.sol
  PaktolVaultV2.multiuser.t.sol
  PaktolVaultV2.permit.t.sol
  PaktolVaultV2.points.t.sol     — V2 points-gated premium access
  PaktolVaultV2.treasury.t.sol
  PaktolVaultV2Base.t.sol        — V2 base setup helpers
  PaktolVaultV2ForkBase.t.sol    — V2 fork tests (Base mainnet)
  mocks/

script/
  Deploy.s.sol             — V1 Gnosis mainnet
  DeploySepolia.s.sol      — V1 Sepolia testnet
  DeployBaseV2.s.sol       — V2 Base mainnet
  DeploySepoliaV2.s.sol    — V2 Sepolia testnet
```
