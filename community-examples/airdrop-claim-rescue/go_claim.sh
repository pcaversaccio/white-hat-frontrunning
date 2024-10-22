#!/bin/bash

############################################
# Skills are what matters. Not cheap talk. #
############################################

# @license GNU Affero General Public License v3.0 only
# @author pcaversaccio

# Enable strict error handling:
# -e: Exit immediately if a command exits with a non-zero status.
# -u: Treat unset variables as an error and exit.
# -o pipefail: Return the exit status of the first failed command in a pipeline.
set -euo pipefail

# Load environment variables from `.env` file.
if [ -f .env ]; then
    set -a
    . ./.env
    set +a
else
    echo ".env file not found"
    exit 1
fi

# Utility function to check if a variable is set without exposing its value.
check_var() {
    if [ -z "${!1}" ]; then
        echo "Error: $1 is not set in the .env file"
        exit 1
    else
        echo "$1 is set"
    fi
}

vars=(
    PROVIDER_URL
    RELAY_URL
    VICTIM_PK
    GAS_PK
    FLASHBOTS_SIGNATURE_PK
    TOKEN_CONTRACT
    RECIPIENT_WALLET
    AIRDROP_CONTRACT
)

# Check if the required environment variables are set.
for var in "${vars[@]}"; do
    check_var "$var"
done

echo "Private keys and RPC URLs loaded successfully!"

# Utility function to derive a wallet address.
derive_wallet() {
    local pk="$1"
    cast wallet address --private-key "$pk"
}

# Derive the wallets.
VICTIM_WALLET=$(derive_wallet "$VICTIM_PK")
GAS_WALLET=$(derive_wallet "$GAS_PK")
FLASHBOTS_WALLET=$(derive_wallet "$FLASHBOTS_SIGNATURE_PK")

# Utility function to create the Flashbots signature (https://docs.flashbots.net/flashbots-auction/advanced/rpc-endpoint#authentication).
create_flashbots_signature() {
    local payload="$1"
    local private_key="$2"
    local payload_keccak=$(cast keccak "$payload")
    local payload_hashed=$(cast hash-message "$payload_keccak")
    local signature=$(cast wallet sign "$payload_hashed" --private-key "$private_key" --no-hash | tr -d '\n')
    echo "$signature"
}

# Utility function to build a transaction.
build_transaction() {
    local from_pk="$1"
    local to_address="$2"
    local value="$3"
    local nonce="$4"
    local gas_limit="$5"
    local gas_price="$6"
    local data="${7:-}"

    # Note that `--gas-price` is the maximum fee per gas for EIP-1559
    # transactions. See here: https://book.getfoundry.sh/reference/cli/cast/mktx.
    cast mktx --private-key "$from_pk" \
        --rpc-url "$PROVIDER_URL" \
        "$to_address" $( [[ -n "$data" ]] && echo -n "$data" ) \
        --value "$value" \
        --nonce "$nonce" \
        --gas-price "$gas_price" \
        --gas-limit "$gas_limit"
}

# Utility function to create the bundle.
create_bundle() {
    local BLOCK_NUMBER="$1"
    shift

    local txs=()
    # Loop through all the remaining arguments (transaction hashes).
    for tx in "$@"; do
        txs+=("\"$tx\"")
    done

    # Join the transaction hashes into a comma-separated string.
    # Note that `IFS` stands for "Internal Field Separator". It is
    # a special variable in Bash that determines how Bash recognises
    # word boundaries. By setting `IFS=,` we instruct Bash to use a
    # comma as a separator for words in the subsequent command.
    local txs_string=$(IFS=,; echo -n "${txs[*]}")

    # Create the bundle JSON.
    BUNDLE_JSON="{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"eth_sendBundle\",\"params\":[{\"txs\":[$txs_string],\"blockNumber\":\"$(cast to-hex "$BLOCK_NUMBER")\",\"minTimestamp\":0}]}"
    echo -n "$BUNDLE_JSON"
}

# Utility function to send the bundle.
send_bundle() {
    local bundle_json="$1"

    # Prepare the common headers.
    local headers=(
        -H "Content-Type: application/json"
    )

    # Check if `RELAY_URL` contains `flashbots.net`. Flashbots relays require
    # a specific signature header for authentication. Other relays may not
    # accept or require this header, so we only include it for Flashbots.
    if [[ "$RELAY_URL" == *"flashbots.net"* ]]; then
        local flashbots_signature=$(create_flashbots_signature "$bundle_json" "$FLASHBOTS_SIGNATURE_PK")
        headers+=(-H "X-Flashbots-Signature: $FLASHBOTS_WALLET:$flashbots_signature")
    fi

    # Send the request with the appropriate headers.
    curl -X POST "${headers[@]}" \
         -d "$(echo -n "$bundle_json")" "$RELAY_URL"
}

#####################################
# CUSTOMISE ACCORDING TO YOUR NEEDS #
#####################################

# Main loop; customise as needed. Resubmits the bundle every 8 seconds.
while true; do
    # Retrieve and adjust the gas price by 20%.
    GAS_PRICE=$(cast gas-price --rpc-url "$PROVIDER_URL")
    GAS_PRICE=$(( (GAS_PRICE * 120) / 100 ))

    # Set the gas limits for the different transfers.
    TRANSFER_ETH=21000
    TRANSFER_TOKEN_GAS=80000
    # Set the gas needed for the Puffer airdrop claim.
    CLAIM_AIRDROP_GAS=170000

    # Calculate the gas cost to fill and convert to ether.
    GAS_TO_FILL=$(( GAS_PRICE * (CLAIM_AIRDROP_GAS + TRANSFER_TOKEN_GAS) ))
    echo "GAS TO FILL: $(cast to-unit $GAS_TO_FILL ether)"

    # Get the next block number.
    BLOCK_NUMBER=$(( $(cast block-number --rpc-url "$PROVIDER_URL") + 1 ))

    # Retrieve the account nonces for the gas and victim wallet.
    GAS_NONCE=$(cast nonce "$GAS_WALLET" --rpc-url "$PROVIDER_URL")
    VICTIM_NONCE=$(cast nonce "$VICTIM_WALLET" --rpc-url "$PROVIDER_URL")
    VICTIM_NEXT_NONCE=$(( VICTIM_NONCE + 1 ))

    # Build the transactions.
    # Example transfer of ETH to the victim wallet.
    TX1=$(build_transaction "$GAS_PK" "$VICTIM_WALLET" "$GAS_TO_FILL" "$GAS_NONCE" "$TRANSFER_ETH" "$GAS_PRICE")

    # Claim the Puffer airdrop.
    # The payload can be retrieved from the airdrop website.
    # Initiate the airdrop claim with the victim wallet and copy the payload from the "HEX" tab.
    PAYLOAD="0xd4b52e0b"
    TX2=$(build_transaction "$VICTIM_PK" "$AIRDROP_CONTRACT" 0 "$VICTIM_NONCE" "$CLAIM_AIRDROP_GAS" "$GAS_PRICE" "$PAYLOAD")

    # An example transfer of 70 Puffer (with 18 decimals) claimed from the airdrop to the rescue wallet.
    TRANSFER_TOKEN_AMOUNT=70000000000000000000
    PAYLOAD=$(cast calldata "transfer(address,uint256)" "$RECIPIENT_WALLET" "$TRANSFER_TOKEN_AMOUNT")
    TX3=$(build_transaction "$VICTIM_PK" "$TOKEN_CONTRACT" 0 "$VICTIM_NEXT_NONCE" "$TRANSFER_TOKEN_GAS" "$GAS_PRICE" "$PAYLOAD")

    echo "TX1: $TX1"
    echo "TX2: $TX2"
    echo "TX3: $TX3"

    # Prepare the bundle JSON.
    BUNDLE_JSON=$(create_bundle "$(cast to-hex $BLOCK_NUMBER)" "$TX1" "$TX2" "$TX3")
    echo -e "Bundle JSON:\n$BUNDLE_JSON"
    echo "$BUNDLE_JSON" > bundle.json

    # Send the bundle.
    send_bundle "$BUNDLE_JSON"

    echo "Waiting for 8 seconds before next iteration..."
    sleep 8
done
