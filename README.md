# White Hat Frontrunning

[![License: AGPL-3.0-only](https://img.shields.io/badge/License-AGPL--3.0--only-blue)](https://www.gnu.org/licenses/agpl-3.0)

White hat frontrunning [script](./go.sh) to outpace hackers and secure funds from compromised wallets. The (Bash) [script](./go.sh) is intentionally designed with minimal dependencies, requiring only the native tools provided by Linux and [`cast`](https://github.com/foundry-rs/foundry/tree/master/crates/cast) from [Foundry](https://github.com/foundry-rs/foundry).

## Usage

> [!NOTE]
> Ensure that [`cast`](https://github.com/foundry-rs/foundry/tree/master/crates/cast) is installed locally. For installation instructions, refer to this [guide](https://book.getfoundry.sh/getting-started/installation).

First, modify the main loop in the [script](./go.sh). At present, it's set to send gas to a victim wallet and transfer a specific token. Since the main loop needs to be tailored for each rescue, please review and adjust it carefully.

Next, make the [script](./go.sh) executable:

```console
chmod +x go.sh
```

> [!TIP]
> The [script](./go.sh) is already set as _executable_ in the repository, so you can run it immediately after cloning or pulling the repository without needing to change permissions.

Now it's time to configure the `.env` accordingly (this is an illustrative `.env` file):

> [!CAUTION]
> The private keys below are placeholders and should never be used in a production environment!

```txt
PROVIDER_URL="https://rpc.flashbots.net"
RELAY_URL="https://relay.flashbots.net"
VICTIM_PK="0x1234567890"
GAS_PK="0x9876543210"
FLASHBOTS_SIGNATURE_PK="0x31337"
TOKEN_CONTRACT="0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48"
```

> [!TIP]
> When submitting bundles to Flashbots, they are signed with your `FLASHBOTS_SIGNATURE_PK` key, enabling Flashbots to verify your identity and track your [reputation](https://docs.flashbots.net/flashbots-auction/advanced/reputation) over time. This reputation system is designed to safeguard the infrastructure from threats such as DDoS attacks. It's important to note that this key **does not** handle any funds and is **not** required to be the primary Ethereum key used for transaction authentication. Its sole purpose is to establish your identity with Flashbots. You can use any ECDSA `secp256k1` key for this, and if you need to create a new one, you can use [`cast wallet new`](https://book.getfoundry.sh/reference/cast/cast-wallet-new).

Finally, execute the [script](./go.sh):

```console
./go.sh
```

To enable _debug mode_, set the `DEBUG` environment variable to `true` before running the [script](./go.sh):

```console
DEBUG=true ./go.sh
```

This will print each command before it is executed, which is helpful when troubleshooting.

## Community Examples

> [!WARNING]
> I have reviewed these examples as part of the PR process, but they haven't been fully tested. Please ensure a thorough review before using them!

The [`community-examples/`](./community-examples/) directory contains customised versions of the primary [`go.sh`](./go.sh) script, tailored for a variety of rescue scenarios.
