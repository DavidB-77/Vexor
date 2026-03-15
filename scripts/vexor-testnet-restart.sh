#!/bin/bash
set -euo pipefail

exec /home/sol/vexor/bin/vexor-validator run \
  --bootstrap \
  --testnet \
  --dashboard \
  --identity /home/sol/.secrets/qubetest/validator-keypair.json \
  --vote-account /home/sol/.secrets/qubetest/vote-account-keypair.json \
  --known-validator 5D1fNXzvv5NjV1ysLjirC4WY92RNsVH18vjmcszZd8on \
  --known-validator 7XSY3MrYnK8vq693Rju17bbPkCN3Z7KvvfvJx4kdrsSY \
  --known-validator Ft5fbkqNa76vnsjYNwjDZUXoTWpP7VYm3mtsaQckQADN \
  --known-validator 9QxCLckBiJc783jnMvXZubK4wH86Eqqvashtrwvcsgkv \
  --known-validator 6gPFU17pZ7rSHCs7Uqr2WC5LqZDEVQd9mDXVkHezcVkn \
  --known-validator J5e4xh1V7zGZnHq9rYfsowFJghoc9SEZWFfiCdbc8FF1 \
  --known-validator FT9QgTVo375TgDAQusTgpsfXqTosCJLfrBpoVdcbnhtS \
  --ledger /home/sol/ledger \
  --accounts /mnt/ramdisk/accounts \
  --snapshots /home/sol/restart_snapshots \
  --log /home/sol/vexor-validator.log \
  --public-ip YOUR_VALIDATOR_IP \
  --gossip-port 8001 \
  --tpu-port 8003 \
  --tvu-port 8004 \
  --rpc-port 8899 \
  --dynamic-port-range 8000-8010 \
  --expected-shred-version 27350 \
  --enable-io-uring \
  --limit-ledger-size 50000000
