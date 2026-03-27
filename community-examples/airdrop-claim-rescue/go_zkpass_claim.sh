#!/usr/bin/env bash

############################################
# Skills are what matters. Not cheap talk. #
############################################

# @license GNU Affero General Public License v3.0 only
# @author pcaversaccio

set -Eeuo pipefail

if [[ "${DEBUG:-false}" == "true" ]]; then
	set -x
fi

if [[ -f .env ]]; then
	set -a
	. ./.env
	set +a
else
	echo ".env file not found"
	exit 1
fi

check_var() {
	if [[ -z "${!1:-}" ]]; then
		echo "Error: $1 is not set in the .env file"
		exit 1
	else
		echo "$1 is set"
	fi
}

vars=(
	RELAY_URL
	VICTIM_PK
	GAS_PK
	FLASHBOTS_SIGNATURE_PK
	AIRDROP_CONTRACT
	TOKEN_CONTRACT
	RECIPIENT_WALLET
	CLAIM_SELECTOR
	TRANSFER_TOKEN_AMOUNT
	CLAIM_PAYLOAD
)

for var in "${vars[@]}"; do
	check_var "$var"
done

READ_RPC_URL="${READ_RPC_URL:-${PROVIDER_URL:-}}"

if [[ -z "$READ_RPC_URL" ]]; then
	echo "Error: set READ_RPC_URL to a standard Ethereum mainnet RPC endpoint."
	exit 1
fi

readonly AIRDROP_CONTRACT="${AIRDROP_CONTRACT}"
readonly TOKEN_CONTRACT="${TOKEN_CONTRACT}"
readonly RECIPIENT_WALLET="${RECIPIENT_WALLET}"
readonly CLAIM_SELECTOR="${CLAIM_SELECTOR}"
readonly CLAIM_AIRDROP_GAS=550000
readonly TRANSFER_ETH_GAS=21000
readonly TRANSFER_TOKEN_GAS=65000
readonly GAS_BUFFER_BPS=12000
readonly MAX_FEE_BPS=12000
readonly BASE_FEE_BUFFER_BPS=500
readonly MIN_PRIORITY_GAS_PRICE=100000000
readonly SEND_BLOCK_COUNT=3
readonly TRANSFER_TOKEN_AMOUNT="${TRANSFER_TOKEN_AMOUNT}"
readonly CLAIM_PAYLOAD="${CLAIM_PAYLOAD}"

echo "Private keys and relay URL loaded successfully!"
echo "Read RPC URL is set"

derive_wallet() {
	local pk="$1"
	cast wallet address --private-key "$pk"
}

lower_hex() {
	printf '%s\n' "$1" | tr '[:upper:]' '[:lower:]'
}

normalize_uint() {
	python3 - "$1" <<'PY'
import sys

value = sys.argv[1].strip()
if value.startswith("0x"):
    print(int(value, 16))
else:
    print(int(value))
PY
}

mul_div_int() {
	python3 - "$1" "$2" "$3" <<'PY'
import sys

a = int(sys.argv[1])
b = int(sys.argv[2])
c = int(sys.argv[3])
print((a * b) // c)
PY
}

builders_json() {
	python3 - "${BUNDLE_BUILDERS:-}" <<'PY'
import json
import sys

raw = sys.argv[1].strip()
if not raw:
    print("")
    raise SystemExit(0)

builders = [item.strip() for item in raw.split(",") if item.strip()]
print(json.dumps(builders, separators=(",", ":")))
PY
}

create_flashbots_signature() {
	local payload="$1"
	local private_key="$2"
	local payload_keccak
	local payload_hashed
	local signature

	payload_keccak=$(cast keccak "$payload")
	payload_hashed=$(cast hash-message "$payload_keccak")
	signature=$(cast wallet sign "$payload_hashed" --private-key "$private_key" --no-hash | tr -d '\n')
	echo "$signature"
}

build_transaction() {
	local from_pk="$1"
	local to_address="$2"
	local value="$3"
	local nonce="$4"
	local gas_limit="$5"
	local gas_price="$6"
	local priority_gas_price="$7"
	local data="${8:-}"

	cast mktx --private-key "$from_pk" \
		--rpc-url "$READ_RPC_URL" \
		"$to_address" $([[ -n "$data" ]] && echo -n "$data") \
		--value "$value" \
		--nonce "$nonce" \
		--gas-price "$gas_price" \
		--priority-gas-price "$priority_gas_price" \
		--gas-limit "$gas_limit"
}

create_bundle_json() {
	local method="$1"
	local block_number="$2"
	local txs_string="$3"
	local state_block_number="${4:-latest}"
	local builders

	builders=$(builders_json)

	if [[ "$method" == "eth_callBundle" ]]; then
		printf '{"jsonrpc":"2.0","id":1,"method":"%s","params":[{"txs":[%s],"blockNumber":"%s","stateBlockNumber":"%s","timestamp":0}]}' \
			"$method" "$txs_string" "$(cast to-hex "$block_number")" "$state_block_number"
	else
		if [[ -n "$builders" ]]; then
			printf '{"jsonrpc":"2.0","id":1,"method":"%s","params":[{"txs":[%s],"blockNumber":"%s","minTimestamp":0,"builders":%s}]}' \
				"$method" "$txs_string" "$(cast to-hex "$block_number")" "$builders"
		else
			printf '{"jsonrpc":"2.0","id":1,"method":"%s","params":[{"txs":[%s],"blockNumber":"%s","minTimestamp":0}]}' \
				"$method" "$txs_string" "$(cast to-hex "$block_number")"
		fi
	fi
}

send_bundle_request() {
	local bundle_json="$1"
	local headers=(
		-H "Content-Type: application/json"
	)

	if [[ "$RELAY_URL" == *"flashbots.net"* ]]; then
		local flashbots_signature
		flashbots_signature=$(create_flashbots_signature "$bundle_json" "$FLASHBOTS_SIGNATURE_PK")
		headers+=(-H "X-Flashbots-Signature: $FLASHBOTS_WALLET:$flashbots_signature")
	fi

	curl -sS -X POST "${headers[@]}" -d "$bundle_json" "$RELAY_URL"
}

verify_dependencies() {
	if ! command -v cast >/dev/null 2>&1; then
		echo "Error: cast is required but not installed."
		exit 1
	fi
	if ! command -v python3 >/dev/null 2>&1; then
		echo "Error: python3 is required but not installed."
		exit 1
	fi
}

validate_claim_payload() {
	local victim_wallet="$1"
	python3 - "$CLAIM_PAYLOAD" "$CLAIM_SELECTOR" "$(lower_hex "$victim_wallet")" "$TRANSFER_TOKEN_AMOUNT" <<'PY'
import sys

payload, selector, victim, amount = sys.argv[1:]
payload = payload.lower()
selector = selector.lower()
victim = victim.lower().removeprefix("0x")
amount = int(amount)

if not payload.startswith(selector):
    raise SystemExit("Error: claim payload selector mismatch")

data = bytes.fromhex(payload[2:])
if len(data) < 4 + 32 * 7:
    raise SystemExit("Error: claim payload is too short")

head = data[4:4 + 32 * 7]
words = [int.from_bytes(head[i:i + 32], "big") for i in range(0, len(head), 32)]
proof_offset, signature_offset, claim_amount, released_amount, handler, on_behalf_of, extra_offset = words

if proof_offset != 0xE0:
    raise SystemExit(f"Error: unexpected proof offset {proof_offset:#x}")
if signature_offset != 0x2A0:
    raise SystemExit(f"Error: unexpected signature offset {signature_offset:#x}")
if extra_offset != 0x320:
    raise SystemExit(f"Error: unexpected extra offset {extra_offset:#x}")
if claim_amount != amount:
    raise SystemExit(f"Error: unexpected claim amount {claim_amount}")
if released_amount != amount:
    raise SystemExit(f"Error: unexpected released amount {released_amount}")
if on_behalf_of.to_bytes(32, "big")[-20:].hex() != victim:
    raise SystemExit("Error: claim payload onBehalfOf does not match victim wallet")

print(f"Payload validated. handler={handler:064x}")
PY
}

preflight_checks() {
	local victim_wallet="$1"
	local gas_wallet="$2"

	echo "Running preflight checks..."
	validate_claim_payload "$victim_wallet"

	local victim_balance
	local gas_balance
	victim_balance=$(cast balance "$victim_wallet" --rpc-url "$READ_RPC_URL")
	gas_balance=$(cast balance "$gas_wallet" --rpc-url "$READ_RPC_URL")

	echo "Victim ETH balance: $(cast to-unit "$victim_balance" ether)"
	echo "Gas wallet ETH balance: $(cast to-unit "$gas_balance" ether)"

	local victim_token_balance
	local recipient_token_balance
	victim_token_balance=$(normalize_uint "$(cast call "$TOKEN_CONTRACT" "balanceOf(address)(uint256)" "$victim_wallet" --rpc-url "$READ_RPC_URL")")
	recipient_token_balance=$(normalize_uint "$(cast call "$TOKEN_CONTRACT" "balanceOf(address)(uint256)" "$RECIPIENT_WALLET" --rpc-url "$READ_RPC_URL")")

	echo "Victim ZKP balance before claim: $victim_token_balance"
	echo "Recipient ZKP balance before claim: $recipient_token_balance"

	if [[ "$victim_token_balance" != "0" ]]; then
		echo "Warning: victim already holds ZKP. The transfer step still sends exactly 500 tokens."
	fi

	INITIAL_RECIPIENT_TOKEN_BALANCE="$recipient_token_balance"
	readonly INITIAL_RECIPIENT_TOKEN_BALANCE
}

maybe_simulate_bundle() {
	local txs_string="$1"
	local block_number="$2"

	if [[ "${SIMULATE_BUNDLE:-false}" != "true" ]]; then
		return
	fi

	local simulation_json
	local simulation_response
	simulation_json=$(create_bundle_json "eth_callBundle" "$block_number" "$txs_string")
	echo "Simulation request:"
	echo "$simulation_json"
	simulation_response=$(send_bundle_request "$simulation_json")
	echo "$simulation_response"
	if [[ "$simulation_response" == *'"error"'* && "$simulation_response" == *"rpc method is not whitelisted"* ]]; then
		echo "Warning: relay does not support eth_callBundle on this endpoint, continuing without simulation."
	fi
	echo
}

send_bundle_for_target_blocks() {
	local txs_string="$1"
	local start_block="$2"
	local target_block
	local bundle_json
	local send_response

	for ((offset = 0; offset < SEND_BLOCK_COUNT; offset++)); do
		target_block=$((start_block + offset))
		bundle_json=$(create_bundle_json "eth_sendBundle" "$target_block" "$txs_string")
		echo -e "Bundle JSON for block $target_block:\n$bundle_json"
		echo "$bundle_json" > bundle.json

		send_response=$(send_bundle_request "$bundle_json")
		echo -e "Relay response for block $target_block:\n$send_response"
	done
}

recipient_received_tokens() {
	local current_balance
	current_balance=$(normalize_uint "$(cast call "$TOKEN_CONTRACT" "balanceOf(address)(uint256)" "$RECIPIENT_WALLET" --rpc-url "$READ_RPC_URL")")
	[[ "$current_balance" -ge $((INITIAL_RECIPIENT_TOKEN_BALANCE + TRANSFER_TOKEN_AMOUNT)) ]]
}

ensure_gas_wallet_can_fund_bundle() {
	local gas_wallet="$1"
	local gas_price="$2"
	local gas_to_fill="$3"
	local gas_wallet_balance
	local tx1_gas_cost
	local total_required

	gas_wallet_balance=$(normalize_uint "$(cast balance "$gas_wallet" --rpc-url "$READ_RPC_URL")")
	tx1_gas_cost=$((TRANSFER_ETH_GAS * gas_price))
	total_required=$((gas_to_fill + tx1_gas_cost))

	if [[ "$gas_wallet_balance" -lt "$total_required" ]]; then
		echo "Error: GAS_WALLET balance is insufficient for this bundle."
		echo "Current balance: $(cast to-unit "$gas_wallet_balance" ether) ETH"
		echo "Required for TX1 value + TX1 gas: $(cast to-unit "$total_required" ether) ETH"
		echo "Shortfall: $(cast to-unit "$((total_required - gas_wallet_balance))" ether) ETH"
		exit 1
	fi
}

victim_nonce_advanced() {
	local initial_nonce="$1"
	local current_nonce
	current_nonce=$(cast nonce "$VICTIM_WALLET" --rpc-url "$READ_RPC_URL")
	[[ "$current_nonce" -ge $((initial_nonce + 2)) ]]
}

verify_dependencies

VICTIM_WALLET=$(derive_wallet "$VICTIM_PK")
GAS_WALLET=$(derive_wallet "$GAS_PK")
FLASHBOTS_WALLET=$(derive_wallet "$FLASHBOTS_SIGNATURE_PK")

readonly VICTIM_WALLET
readonly GAS_WALLET
readonly FLASHBOTS_WALLET

EXPECTED_VICTIM_WALLET="${EXPECTED_VICTIM_WALLET:-}"
if [[ -n "$EXPECTED_VICTIM_WALLET" && "$(lower_hex "$VICTIM_WALLET")" != "$(lower_hex "$EXPECTED_VICTIM_WALLET")" ]]; then
	echo "Error: VICTIM_PK does not derive to EXPECTED_VICTIM_WALLET."
	exit 1
fi

preflight_checks "$VICTIM_WALLET" "$GAS_WALLET"

echo "Victim wallet: $VICTIM_WALLET"
echo "Gas wallet: $GAS_WALLET"
echo "Recipient wallet: $RECIPIENT_WALLET"
echo "Airdrop contract: $AIRDROP_CONTRACT"
echo "Token contract: $TOKEN_CONTRACT"

while true; do
	INITIAL_VICTIM_NONCE=$(cast nonce "$VICTIM_WALLET" --rpc-url "$READ_RPC_URL")

	if recipient_received_tokens || victim_nonce_advanced "$INITIAL_VICTIM_NONCE"; then
		echo "Rescue appears to have completed. Stopping."
		exit 0
	fi

	GAS_PRICE=$(cast gas-price --rpc-url "$READ_RPC_URL")
	GAS_PRICE=$(((GAS_PRICE * MAX_FEE_BPS) / 10000))
	BASE_FEE=$(cast base-fee --rpc-url "$READ_RPC_URL")
	BASE_FEE_BUFFER=$(((BASE_FEE * BASE_FEE_BUFFER_BPS) / 10000))
	PRIORITY_GAS_PRICE=$((GAS_PRICE - BASE_FEE))

	if [[ "$PRIORITY_GAS_PRICE" -lt "$MIN_PRIORITY_GAS_PRICE" ]]; then
		PRIORITY_GAS_PRICE="$MIN_PRIORITY_GAS_PRICE"
	fi

	MIN_REQUIRED_GAS_PRICE=$((BASE_FEE + BASE_FEE_BUFFER + PRIORITY_GAS_PRICE))
	if [[ "$GAS_PRICE" -lt "$MIN_REQUIRED_GAS_PRICE" ]]; then
		GAS_PRICE="$MIN_REQUIRED_GAS_PRICE"
	fi

	echo "BASE_FEE: $(cast to-unit "$BASE_FEE" gwei) gwei"
	echo "MAX_FEE_PER_GAS: $(cast to-unit "$GAS_PRICE" gwei) gwei"
	echo "PRIORITY_GAS_PRICE: $(cast to-unit "$PRIORITY_GAS_PRICE" gwei) gwei"

	GAS_TO_FILL=$(mul_div_int "$((GAS_PRICE * (CLAIM_AIRDROP_GAS + TRANSFER_TOKEN_GAS)))" "$GAS_BUFFER_BPS" "10000")
	echo "GAS TO FILL: $(cast to-unit "$GAS_TO_FILL" ether)"
	ensure_gas_wallet_can_fund_bundle "$GAS_WALLET" "$GAS_PRICE" "$GAS_TO_FILL"

	GAS_NONCE=$(cast nonce "$GAS_WALLET" --rpc-url "$READ_RPC_URL")
	VICTIM_NEXT_NONCE=$((INITIAL_VICTIM_NONCE + 1))

	TX1=$(build_transaction "$GAS_PK" "$VICTIM_WALLET" "$GAS_TO_FILL" "$GAS_NONCE" "$TRANSFER_ETH_GAS" "$GAS_PRICE" "$PRIORITY_GAS_PRICE")
	TX2=$(build_transaction "$VICTIM_PK" "$AIRDROP_CONTRACT" 0 "$INITIAL_VICTIM_NONCE" "$CLAIM_AIRDROP_GAS" "$GAS_PRICE" "$PRIORITY_GAS_PRICE" "$CLAIM_PAYLOAD")
	TRANSFER_PAYLOAD=$(cast calldata "transfer(address,uint256)" "$RECIPIENT_WALLET" "$TRANSFER_TOKEN_AMOUNT")
	TX3=$(build_transaction "$VICTIM_PK" "$TOKEN_CONTRACT" 0 "$VICTIM_NEXT_NONCE" "$TRANSFER_TOKEN_GAS" "$GAS_PRICE" "$PRIORITY_GAS_PRICE" "$TRANSFER_PAYLOAD")

	echo "TX1: $TX1"
	echo "TX2: $TX2"
	echo "TX3: $TX3"

	TXS_STRING=$(
		IFS=,
		echo -n "\"$TX1\",\"$TX2\",\"$TX3\""
	)

	SIMULATION_BLOCK_NUMBER=$(($(cast block-number --rpc-url "$READ_RPC_URL") + 1))
	maybe_simulate_bundle "$TXS_STRING" "$SIMULATION_BLOCK_NUMBER"

	SEND_START_BLOCK=$(($(cast block-number --rpc-url "$READ_RPC_URL") + 1))
	send_bundle_for_target_blocks "$TXS_STRING" "$SEND_START_BLOCK"

	echo "Waiting for 8 seconds before next iteration..."
	sleep 8
done
