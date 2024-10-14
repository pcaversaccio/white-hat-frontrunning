#!/bin/bash

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

# Check if the required environment variables are set.
check_var "PROVIDER_URL"
check_var "RELAY_URL"
check_var "VICTIM_PK"
check_var "GAS_PK"
check_var "FLASHBOTS_SIGNATURE_PK"
check_var "TARGET_CONTRACT"

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
    local payload_hashed=$(cast hash-message "${payload_keccak:2}")
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
    local data="${7}"

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
    local txs_string=$(IFS=,; echo -n "${txs[*]}")

    # Create the bundle JSON.
    BUNDLE_JSON="{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"eth_sendBundle\",\"params\":[{\"txs\":[$txs_string],\"blockNumber\":\"$(cast to-hex "$BLOCK_NUMBER")\",\"minTimestamp\":0}]}"
    echo -n "$BUNDLE_JSON"
}

# Utility function to send the bundle.
send_bundle() {
    local bundle_json="$1"
    local flashbots_signature="$2"

    curl -X POST -H "Content-Type: application/json" \
         -H "X-Flashbots-Signature: $FLASHBOTS_WALLET:$flashbots_signature" \
         -d "$(echo -n "$bundle_json")" "$RELAY_URL"
}

# Main loop; customise as needed. Resubmits the bundle every 8 seconds.
while true; do
    # Retrieve and adjust the gas price by 20%.
    GAS_PRICE=$(cast gas-price --rpc-url "$PROVIDER_URL")
    GAS_PRICE=$(( (GAS_PRICE * 120) / 100 ))

    # Set the gas limits for the different transfers.
    TRANSFER_ETH=21000
    TRANSFER_TOKEN_GAS=80000

    # Calculate the gas cost to fill and convert to ether.
    GAS_TO_FILL=$(( GAS_PRICE * TRANSFER_TOKEN_GAS ))
    echo "GAS TO FILL: $(cast to-unit $GAS_TO_FILL ether)"

    # Get the next block number.
    BLOCK_NUMBER=$(( $(cast block-number --rpc-url "$PROVIDER_URL") + 1 ))

    # Retrieve the account nonces for the gas and victim wallet.
    GAS_NONCE=$(cast nonce "$GAS_WALLET" --rpc-url "$PROVIDER_URL")
    VICTIM_NONCE=$(cast nonce "$VICTIM_WALLET" --rpc-url "$PROVIDER_URL")

    # Build the transactions.
    # Transfer of ETH to the victim wallet.
    TX1=$(build_transaction "$GAS_PK" "$VICTIM_WALLET" "$GAS_TO_FILL" "$GAS_NONCE" "$TRANSFER_ETH" "$GAS_PRICE")

    # Transfer of 1 USDC (remember that USDC has 6 decimals) to rescue wallet.
    PAYLOAD=$(cast calldata "transfer(address,uint256)" "$GAS_WALLET" 1000000)
    TX2=$(build_transaction "$VICTIM_PK" "$TARGET_CONTRACT" 0 "$VICTIM_NONCE" "$TRANSFER_TOKEN_GAS" "$GAS_PRICE" "$PAYLOAD")

    echo "TX1: $TX1"
    echo "TX2: $TX2"

    # Prepare the bundle JSON.
    BUNDLE_JSON=$(create_bundle "$(cast to-hex $BLOCK_NUMBER)" "$TX1" "$TX2")
    echo -e "Bundle JSON:\n$BUNDLE_JSON"
    echo "$BUNDLE_JSON" > bundle.json

    # Create the Flashbots signature and send the bundle.
    FLASHBOTS_SIGNATURE=$(create_flashbots_signature "$BUNDLE_JSON" "$FLASHBOTS_SIGNATURE_PK")
    echo "$FLASHBOTS_WALLET:$FLASHBOTS_SIGNATURE" > flashbots_signature.txt
    send_bundle "$BUNDLE_JSON" "$FLASHBOTS_SIGNATURE"

    echo "Waiting for 8 seconds before next iteration..."
    sleep 8
done
