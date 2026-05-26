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

## Deployed contracts

### V2 — Base Mainnet

| Vault | Address | Cap |
|-------|---------|-----|
| Vault A (Premium) | `0xFf8ed721E257aE96d9085DDe22a98d8C88093618` | 5% / year |
| Vault B (Standard) | `0xD895Df1594F1520a3e531ae78458f6618649493C` | 3.5% / year |

- Byzantine vault: `0x061b3aff8e21a9d194ce43cEfc20A0eFf122Ec69`
- Treasury: `0x3469682e65faFc2d2fAE93f528230B899B183a84`

### V1 — Gnosis Chain

Deployed. Addresses managed internally.

## Security

**V1 — Security audit completed.**

`PaktolVault.sol` (V1) was reviewed by an external security auditor. All findings have been resolved:

| Finding | Severity | Status |
|---------|----------|--------|
| F-03 — aToken/asset consistency check in constructor | P1 | ✅ Fixed |
| F-09 — 4-hour withdrawal cooldown (harvest sandwich) | P0 | ✅ Fixed |
| F-10 — `_idleBalance` excludes donations from `totalAssets()` | P1 | ✅ Fixed |
| F-11 — `emergencyExitAave()` atomic auto-pause | P1 | ✅ Fixed |
| F-13 — `depositWithPermit()` nonce guard | P1 | ✅ Fixed |
| F-16 — ERC-4626 compliance | P1 | ✅ Fixed |
| F-18 — `lastTotalAssets` preserved across deposit/withdraw | P1 | ✅ Fixed |
| F-19 — `depositUpToCap()` eliminates TVL-cap griefing | P1 | ✅ Fixed |
| F-20 — `lastHarvestTimestamp` not advanced on no-yield harvest | P1 | ✅ Fixed |
| F-21 — `feeBps` constructor bound tightened to `FLOOR_BPS` | P2 | ✅ Fixed |
| F-22 — `emergencyExitAave()` uses `type(uint256).max` | P2 | ✅ Fixed |
| F-06, F-17, F-23, F-26, F-27 | P2 | ✅ Fixed |

**V2 — Not yet audited.**

## Stack

- Solidity 0.8.24 — OpenZeppelin, AAVE v3 (V1), Byzantine Finance (V2)
- Foundry — unit + fork tests
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
  PaktolVaultV2.erc4626.t.sol    — V2 a16z ERC-4626 compliance suite
  PaktolVaultV2.emergency.t.sol
  PaktolVaultV2.harvest.t.sol
  PaktolVaultV2.multiuser.t.sol
  PaktolVaultV2.permit.t.sol
  PaktolVaultV2.points.t.sol     — V2 points-gated premium access
  PaktolVaultV2.security.t.sol   — V2 security / adversarial tests
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
