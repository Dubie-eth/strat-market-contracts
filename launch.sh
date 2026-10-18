#!/usr/bin/env bash
# STRATM launch on Robinhood Chain via ERC20T fork. Usage:
#   ACCOUNT=<foundry keystore name> TREASURY=<treasury address> ./launch.sh
set -euo pipefail
: "${ACCOUNT:?set ACCOUNT to your foundry keystore name (cast wallet list)}"
: "${TREASURY:?set TREASURY to your treasury address}"
export RH_RPC_URL=https://rpc.mainnet.chain.robinhood.com
SENDER=$(cast wallet address --account "$ACCOUNT")
echo "Deployer: $SENDER  balance: $(cast balance $SENDER --rpc-url $RH_RPC_URL --ether) ETH"
export HOOK_OWNER=$TREASURY PROTOCOL_FEE_RECIPIENT=$TREASURY
export TOKEN_OWNER=$TREASURY FEE_RECIPIENT=$TREASURY FEE_DECAY_RECIPIENT=$TREASURY
export TOKEN_NAME="Strat Market" TOKEN_SYMBOL=STRATM CREATOR_BPS=500 TAX_BPS=300 DECAY_INTERVAL=10 START_PRICE_WEI=5000000000
forge build
echo "== Dry run: deploy ==" && forge script script/Deploy.s.sol --rpc-url $RH_RPC_URL --account "$ACCOUNT" --sender $SENDER
read -rp "Broadcast DEPLOY to Robinhood mainnet? type yes: " a; [ "$a" = yes ] || exit 1
forge script script/Deploy.s.sol --rpc-url $RH_RPC_URL --account "$ACCOUNT" --sender $SENDER --broadcast
read -rp "Paste FACTORY address from output: " FACTORY; read -rp "Paste HOOK address: " HOOK; export FACTORY HOOK
echo "== Dry run: launch ==" && forge script script/Launch.s.sol --rpc-url $RH_RPC_URL --account "$ACCOUNT" --sender $SENDER
read -rp "Broadcast LAUNCH of STRATM? type yes: " a; [ "$a" = yes ] || exit 1
forge script script/Launch.s.sol --rpc-url $RH_RPC_URL --account "$ACCOUNT" --sender $SENDER --broadcast
echo "Done. Token address is in the output above / broadcast/Launch.s.sol/4663/run-latest.json"
