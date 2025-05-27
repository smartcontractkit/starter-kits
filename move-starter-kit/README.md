# Move starter kit

## prerequisites
1. Install [Aptos CLI](https://aptos.dev/en/build/cli)<br>
2. Config an account on Aptos testnet

Create an aptos account on aptos testnet, and get test tokens from the [official faucet](https://aptos.dev/en/network/faucet). 
```
aptos init --network testnet --assume-yes
```
Set the `sender` and `owner` as your generated `account` in the file `~/Move.toml`. The account address can be found in `~/.aptos/config.yaml`
```toml
[package]
name = "move_starter_kit"
version = "1.0.0"
authors = []

[addresses]
sender = <YOUR_ACCOUNT_ADDRESS>
owner = <YOUR_ACCOUNT_ADDRESS>
data_feeds = "0xf1099f135ddddad1c065203431be328a408b0ca452ada70374ce26bd2b32fdd3"
platform = "0x516e771e1b4a903afe74c27d057c65849ecc1383782f6642d7ff21425f4f9c99"
move_stdlib = "0x1"
aptos_std = "0x1"

[dev-addresses]

[dependencies]
AptosFramework = { git = "https://github.com/aptos-labs/aptos-core.git", subdir = "aptos-move/framework/aptos-framework", rev = "main" }
MoveStdlib = { git = "https://github.com/aptos-labs/aptos-core.git", subdir = "aptos-move/framework/move-stdlib", rev = "main" }
ChainlinkDataFeeds = { local = "./ChainlinkDataFeeds" }
```

## Data Feeds on Aptos
1. Deploy the module with command.
```shell
aptos move publish --skip-fetch-latest-git-deps
```

2. fetch the BTC/USD feed and save to the account's global storage.
```shell
aptos move run \
--function-id '<YOUR_ACCOUNT_ADDRESS>::price_feed_demo::fetch_price' \
--args hex:0x01a0b4d920000332000000000000000000000000000000000000000000000000
```
Other data feed module addresses can be found [here](https://docs.chain.link/data-feeds/price-feeds/addresses?page=1&testnetPage=1&network=aptos). 

3. Retrieve this data using the view function.
```shell
aptos move view \
--function-id '<YOUR_ACCOUNT_ADDRESS>::price_feed_demo::get_price_data' \
--args address:<YOUR_ACCOUNT_ADDRESS>
```