#!/usr/bin/env bash
set -euo pipefail
export PATH="$HOME/.foundry/bin:$PATH"
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
WORKDIR=$(mktemp -d)
cp "$ROOT/src/SepoliaUsdcEscrow.sol" "$WORKDIR/"
mkdir -p "$WORKDIR/src"
mv "$WORKDIR/SepoliaUsdcEscrow.sol" "$WORKDIR/src/"
cat > "$WORKDIR/foundry.toml" <<TOML
[profile.default]
src = "src"
out = "out"
libs = []
solc_version = "0.8.24"
TOML
cd "$WORKDIR"
forge build
: "${DEPLOYER_PRIVATE_KEY:?set DEPLOYER_PRIVATE_KEY}"
: "${SEPOLIA_RPC_URL:=https://ethereum-sepolia-rpc.publicnode.com}"
forge create src/SepoliaUsdcEscrow.sol:SepoliaUsdcEscrow \
  --rpc-url "$SEPOLIA_RPC_URL" \
  --private-key "$DEPLOYER_PRIVATE_KEY" \
  --broadcast
