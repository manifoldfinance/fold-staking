#!/usr/bin/env bash

source .env

forge script script/FoldCaptiveStaking.s.sol:FoldCaptiveStakingScript \
    --chain-id 1 \
    --fork-url $RPC_MAINNET \
    --broadcast \
    --private-key $PRIVATE_KEY \
    -vvv