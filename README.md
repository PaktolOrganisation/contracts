# paktol-contracts

ERC-4626 vault routing EURe (Monerium) into AAVE v3 on Gnosis Chain.

Two instances — Standard (0.5% fee, 3.5% cap) and Subscription (no fee, 5% cap, backend-gated via EIP-712).

## Stack

- Solidity ^0.8.24 — OpenZeppelin, AAVE v3
- Foundry — unit + fork tests
- Hardhat — business scenario tests (JS)

## Run

```bash
# Foundry
forge build
forge test --no-match-test fork

# Fork tests (requires Gnosis archive node)
GNOSIS_RPC_URL=https://... forge test --match-contract PaktolVaultForkTest

# Hardhat
npm install
npm test
```

## Deploy

```bash
# Gnosis Chain
cp .env.example .env  # fill in keys + addresses
forge script script/Deploy.s.sol --rpc-url $RPC_URL --broadcast --verify

# Sepolia (MockAavePool)
forge script script/DeploySepolia.s.sol --rpc-url $SEPOLIA_RPC_URL --broadcast
```

## Structure

```
src/
  PaktolVault.sol       — main contract
  interfaces/
    IAavePool.sol
test/
  PaktolVault.t.sol     — 77 Foundry tests
  PaktolVault.fork.t.sol
  PaktolVault.scenarios.js — 29 Hardhat scenarios
  mocks/
script/
  Deploy.s.sol
  DeploySepolia.s.sol
```
