# 🥷🏽 White Hat Frontrunning

[![License: AGPL-3.0-only](https://img.shields.io/badge/License-AGPL--3.0--only-blue)](https://www.gnu.org/licenses/agpl-3.0)

White hat frontrunning [script](./go.sh) to outpace hackers and secure funds from compromised wallets. The (Bash) [script](./go.sh) is intentionally designed with minimal dependencies, requiring only the native tools provided by Linux and [`cast`](https://github.com/foundry-rs/foundry/tree/master/crates/cast) from [Foundry](https://github.com/foundry-rs/foundry).

## Usage

> [!NOTE]
> Ensure that [`cast`](https://github.com/foundry-rs/foundry/tree/master/crates/cast) is installed locally. For installation instructions, refer to this [guide](https://www.getfoundry.sh/introduction/installation).

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
> When submitting bundles to Flashbots, they are signed with your `FLASHBOTS_SIGNATURE_PK` key, enabling Flashbots to verify your identity and track your [reputation](https://docs.flashbots.net/flashbots-auction/advanced/reputation) over time. This reputation system is designed to safeguard the infrastructure from threats such as DDoS attacks. It's important to note that this key **does not** handle any funds and is **not** required to be the primary Ethereum key used for transaction authentication. Its sole purpose is to establish your identity with Flashbots. You can use any ECDSA `secp256k1` key for this, and if you need to create a new one, you can use [`cast wallet new`](https://www.getfoundry.sh/reference/cast/wallet).

Finally, execute the [script](./go.sh):

```console
./go.sh
```

To enable _debug mode_, set the `DEBUG` environment variable to `true` before runni:ng the [script](./go.sh):

```console
DEBUG=true ./go.sh
```

This will print each command before it is executed, which is helpful when troubleshooting.

> [!WARNING]
> The _debug mode_ is **not** a dry-run. It will still send the rescue transactions, only with extra output.

## EIP-7702-Based Rescue

Using [EIP-7702](https://eips.ethereum.org/EIPS/eip-7702), you can rescue all funds from a compromised wallet using a paymaster and a friendly delegator. There is _no need_ to send ether to the compromised wallet at all. The script [`go_eip7702.sh`](./go_eip7702.sh) handles the full rescue logic. It deploys a Vyper contract called [`recoverooor.vy`](./recoverooor.vy), which acts as the (friendly) delegator to facilitate the asset transfers. All you need to do is set the environment variables `RPC_URL`, `VICTIM_PK`, and `PAYMASTER_PK`, along with the `PAYLOAD` parameter containing the calldata to be executed by the delegator contract.

> [!TIP]
> To generate the same bytecode for [`recoverooor.vy`](./recoverooor.vy) as the script [`go_eip7702.sh`](./go_eip7702.sh), install the necessary dependencies via `pip install vyper==0.4.2 snekmate==0.1.2rc1` and compile the contract using `vyper recoverooor.vy`.

To get started, configure your `.env` file as shown below:

> [!CAUTION]
> The private keys below are placeholders and should never be used in a production environment!

```txt
RPC_URL="https://rpc.flashbots.net"
VICTIM_PK="0x1234567890"
PAYMASTER_PK="0xba5Ed"
```

The `PAYLOAD` parameter in the script [`go_eip7702.sh`](./go_eip7702.sh) must be the calldata that calls the [`recoverooor.vy`](./recoverooor.vy) contract with the appropriate logic (refer to the [`encode_recover_multicall.sh`](./encode_recover_multicall.sh) script for details on how to encode calldata for the `recover_multicall` function). The [`recoverooor.vy`](./recoverooor.vy) contract will be deployed with the paymaster wallet as the `OWNER`. The [`script`](./go_eip7702.sh) also resets the [EIP-7702](https://eips.ethereum.org/EIPS/eip-7702) authorisation at the end, in case the `OWNER` can no longer be trusted in the future.

To perform the rescue, simply run:

```console
./go_eip7702.sh
```

To enable _debug mode_, set the `DEBUG` environment variable to `true` before running the [script](./go_eip7702.sh):

```console
DEBUG=true ./go_eip7702.sh
```

This will print each command before it is executed, which is helpful when troubleshooting.

> [!WARNING]
> The _debug mode_ is **not** a dry-run. It will still send the rescue transactions, only with extra output.

> [!TIP]
> To make an authorisation replayable across all chains, simply set the chain ID to `0` (see [here](https://eips.ethereum.org/EIPS/eip-7702#protection-from-malleability-cross-chain)). While `cast` does not currently support this feature, you can use my [`ethers`](https://docs.ethers.org/v6/)-based [script](https://github.com/pcaversaccio/raw-tx/blob/bd86ddb1311bffe8e24ddea961bc09e4952cf4f6/scripts/sign-eip7702.ts#L61-L73) to generate a replayable authorisation. This authorisation can then be passed into the main [script](./go_eip7702.sh).

## Community Examples

> [!WARNING]
> I have reviewed these examples as part of the PR process, but they haven't been fully tested. Please ensure a thorough review before using them!

The [`community-examples/`](./community-examples/) directory contains customised versions of the primary [`go.sh`](./go.sh) script, tailored for a variety of rescue scenarios.

## Real-World Rescues

- [Degen Rescue](https://basescan.org/tx/0x344237ab211385caa2db08a9bb20a012bf0c0c0c4c6919005dd28fb18d08625a)
- [Zyfai Rescue](https://arbiscan.io/tx/0x966ccc006e135e481b3aa4bb9645f0e05cc19dfa33baf3643d4fcb3b7c2f20b9)
