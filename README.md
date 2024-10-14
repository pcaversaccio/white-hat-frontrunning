# White Hat Frontrunning

White hat frontrunning [script](./go.sh) to outpace hackers and secure funds from compromised wallets. The (Bash) script is intentionally designed with minimal dependencies, requiring only the native tools provided by Linux and [`cast`](https://github.com/foundry-rs/foundry/tree/master/crates/cast) from [Foundry](https://github.com/foundry-rs/foundry).

## Usage

> [!NOTE]
> Ensure that [`cast`] is installed locally. For installation instructions, refer to this [guide](https://book.getfoundry.sh/getting-started/installation).

First, modify the main loop in the [script](./go.sh). At present, it's set to send gas to a victim wallet and transfer a specific token. Since the main loop needs to be tailored for each rescue, please review and adjust it carefully.

Next, make the script executable:

```console
chmod +x go.sh
```

Now it's time to configure the `.env` accordingly (this is an illustrative `.env` file):

> [!CAUTION]
> The private keys below are placeholders and should never be used in a production environment!

```txt
PROVIDER_URL="https://rpc.flashbots.net"
RELAY_URL="https://relay.flashbots.net"
VICTIM_PK="0x1234567890"
GAS_PK="0x9876543210"
FLASHBOTS_SIGNATURE_PK="0x31337"
TARGET_CONTRACT="0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48"
```

Finally, execute the script:

```console
./go.sh
```
