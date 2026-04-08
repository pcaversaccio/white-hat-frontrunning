#!/usr/bin/env bash

############################################
# Skills are what matters. Not cheap talk. #
############################################

# @license GNU Affero General Public License v3.0 only
# @author pcaversaccio

# Enable strict error handling:
# -E: Inherit `ERR` traps in functions and subshells.
# -e: Exit immediately if a command exits with a non-zero status.
# -u: Treat unset variables as an error and exit.
# -o pipefail: Return the exit status of the first failed command in a pipeline.
set -Eeuo pipefail

# Enable debug mode if the environment variable `DEBUG` is set to `true`.
if [[ "${DEBUG:-false}" == "true" ]]; then
	# Print each command before executing it.
	set -x
fi

# Load environment variables from `.env` file.
if [[ -f .env ]]; then
	set -a
	. ./.env
	set +a
else
	echo ".env file not found"
	exit 1
fi

# Utility function to check if a variable is set without exposing its value.
check_var() {
	if [[ -z "${!1:-}" ]]; then
		echo "Error: $1 is not set in the .env file"
		exit 1
	else
		echo "$1 is set"
	fi
}

vars=(
	READ_RPC_URL
	PRIVATE_RPC_URL
	VICTIM_PK
	GAS_PK
	SAFE_WALLET
	STANDX_HIGHWAY
	DUSD_TOKEN
	WITHDRAW_SELECTOR
	WITHDRAW_AMOUNT
	WITHDRAW_PAYLOAD
)

# Check if the required environment variables are set.
for var in "${vars[@]}"; do
	check_var "$var"
done

MODE="${MODE:-request_withdraw_bundle}"
POLL_INTERVAL_SECONDS="${POLL_INTERVAL_SECONDS:-5}"
SIMULATE_BUNDLE="${SIMULATE_BUNDLE:-true}"
SEND_BLOCK_COUNT="${SEND_BLOCK_COUNT:-3}"
RESCUE_TRANSFER_AMOUNT="${RESCUE_TRANSFER_AMOUNT:-}"
BUNDLE_RPC_URL="${BUNDLE_RPC_URL:-$PRIVATE_RPC_URL}"
MAX_BLOCK_AHEAD="${MAX_BLOCK_AHEAD:-100}"
REQUEST_TX_GAS_BUFFER_BPS="${REQUEST_TX_GAS_BUFFER_BPS:-11000}"
REQUEST_TOPUP_BUFFER_BPS="${REQUEST_TOPUP_BUFFER_BPS:-10500}"
TRANSFER_TX_GAS_BUFFER_BPS="${TRANSFER_TX_GAS_BUFFER_BPS:-11000}"
TRANSFER_TOPUP_BUFFER_BPS="${TRANSFER_TOPUP_BUFFER_BPS:-10500}"

readonly SAFE_WALLET="${SAFE_WALLET}"
readonly STANDX_HIGHWAY="${STANDX_HIGHWAY}"
readonly DUSD_TOKEN="${DUSD_TOKEN}"
readonly WITHDRAW_SELECTOR="${WITHDRAW_SELECTOR}"
readonly WITHDRAW_AMOUNT="${WITHDRAW_AMOUNT}"
readonly MIN_GAS_PRICE_WEI=1000000000
readonly WITHDRAW_PAYLOAD="${WITHDRAW_PAYLOAD}"

echo "Mode: $MODE"
echo "Read RPC URL is set"
echo "Private RPC URL is set"
echo "Bundle RPC URL is set"

# Utility function to derive a wallet address.
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
if " " in value:
    value = value.split()[0]
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

# Utility function to build a legacy transaction.
build_legacy_transaction() {
	local from_pk="$1"
	local to_address="$2"
	local value="$3"
	local nonce="$4"
	local gas_limit="$5"
	local gas_price="$6"
	local data="${7:-}"

	cast mktx --legacy --private-key "$from_pk" \
		--rpc-url "$READ_RPC_URL" \
		"$to_address" $([[ -n "$data" ]] && echo -n "$data") \
		--value "$value" \
		--nonce "$nonce" \
		--gas-price "$gas_price" \
		--gas-limit "$gas_limit"
}

json_rpc_request() {
	local method="$1"
	local params_json="$2"
	local rpc_url="${3:-$PRIVATE_RPC_URL}"
	curl -sS -X POST \
		-H "Content-Type: application/json" \
		-d "{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"$method\",\"params\":$params_json}" \
		"$rpc_url"
}

# Utility function to create the bundle JSON.
create_bundle_json() {
	local max_block_number="$1"
	local tx1="$2"
	local tx2="$3"

	printf '[{"txs":["%s","%s"],"maxBlockNumber":%s}]' \
		"$tx1" "$tx2" "$max_block_number"
}

maybe_simulate_bundle() {
	local tx1="$1"
	local tx2="$2"
	local block_number="$3"
	local simulation_json
	local simulation_response

	if [[ "$SIMULATE_BUNDLE" != "true" ]]; then
		return
	fi

	simulation_json=$(create_bundle_json "$block_number" "$tx1" "$tx2")
	echo "Simulation skipped: public 48 Club RPC does not expose bundle simulation; proceeding with \`eth_sendBundle\` semantics."
	echo "Bundle preview for up-to block $block_number: $simulation_json"
	simulation_response='{"skipped":true}'
}

send_bundle_for_target_blocks() {
	local tx1="$1"
	local tx2="$2"
	local current_block="$3"
	local max_block_number
	local bundle_json
	local response

	max_block_number=$((current_block + MAX_BLOCK_AHEAD))
	bundle_json=$(create_bundle_json "$max_block_number" "$tx1" "$tx2")
	echo "Bundle request with \`maxBlockNumber\` $max_block_number: $bundle_json"
	response=$(json_rpc_request "eth_sendBundle" "$bundle_json" "$BUNDLE_RPC_URL")
	echo "Bundle response: $response"
}

query_bundle_gas_floor() {
	local response
	local result
	response=$(json_rpc_request "eth_gasPrice" "[]" "$BUNDLE_RPC_URL")
	result=$(
		python3 - "$response" <<'PY'
import json, sys
try:
    payload = json.loads(sys.argv[1])
except Exception:
    print("")
    raise SystemExit(0)
result = payload.get("result")
if isinstance(result, str):
    print(result)
PY
	)
	if [[ -n "$result" ]]; then
		normalize_uint "$result"
	fi
}

validate_withdraw_payload() {
	local victim_wallet="$1"
	python3 - "$WITHDRAW_PAYLOAD" "$WITHDRAW_SELECTOR" "$(lower_hex "$victim_wallet")" "$(lower_hex "$STANDX_HIGHWAY")" "$(lower_hex "$DUSD_TOKEN")" "$WITHDRAW_AMOUNT" <<'PY'
import sys
from datetime import datetime, timezone

payload, selector, victim, standx, token, amount = sys.argv[1:]
payload = payload.lower()
selector = selector.lower()
victim = victim.removeprefix("0x")
standx = standx.removeprefix("0x")
token = token.removeprefix("0x")
amount = int(amount)

if not payload.startswith(selector):
    raise SystemExit("Error: withdraw payload selector mismatch")

data = bytes.fromhex(payload[2:])
args_data = data[4:]
if len(args_data) < 32 * 10:
    raise SystemExit("Error: withdraw payload is too short")

words = [
    int.from_bytes(args_data[i:i + 32], "big")
    for i in range(0, len(args_data), 32)
    if len(args_data[i:i + 32]) == 32
]
token_addr = words[0].to_bytes(32, "big")[-20:].hex()
withdraw_amount = words[1]
withdraw_mode = words[2]
route_offset = words[3]
deadline = words[4]
slot = words[5]
owner = words[6].to_bytes(32, "big")[-20:].hex()
standx_addr = words[7].to_bytes(32, "big")[-20:].hex()
sig_offset = words[8]

if token_addr != token:
    raise SystemExit("Error: withdraw payload token mismatch")
if withdraw_amount != amount:
    raise SystemExit(f"Error: withdraw payload amount mismatch ({withdraw_amount})")
if owner != victim:
    raise SystemExit("Error: withdraw payload victim mismatch")
if standx_addr != standx:
    raise SystemExit("Error: withdraw payload StandX highway mismatch")
if sig_offset % 32 != 0:
    raise SystemExit(f"Error: unexpected signature offset alignment {sig_offset:#x}")
if sig_offset + 32 > len(args_data):
    raise SystemExit("Error: withdraw payload signature offset is out of bounds")

sig_len = int.from_bytes(args_data[sig_offset:sig_offset + 32], "big")
if sig_offset + 32 + sig_len > len(args_data):
    raise SystemExit("Error: withdraw payload signature bytes are truncated")

now_ts = int(datetime.now(timezone.utc).timestamp())
deadline_utc = datetime.fromtimestamp(deadline, timezone.utc).isoformat()
if deadline <= now_ts:
    raise SystemExit(
        "Error: withdraw payload deadline has expired "
        f"({deadline_utc}). Capture a fresh withdraw payload from the wallet popup and try again."
    )

print(
    f"Payload validated. mode={withdraw_mode} route_offset={route_offset} "
    f"deadline={deadline} ({deadline_utc}) slot={slot} sig_len={sig_len}"
)
PY
}

get_dusd_balance() {
	local wallet="$1"
	normalize_uint "$(cast call "$DUSD_TOKEN" "balanceOf(address)(uint256)" "$wallet" --rpc-url "$READ_RPC_URL")"
}

estimate_withdraw_gas() {
	cast estimate --rpc-url "$READ_RPC_URL" --from "$VICTIM_WALLET" "$STANDX_HIGHWAY" "$WITHDRAW_PAYLOAD"
}

estimate_native_topup_gas() {
	local from_address="$1"
	local to_address="$2"
	local value="$3"
	cast estimate --rpc-url "$READ_RPC_URL" --from "$from_address" "$to_address" --value "$value"
}

estimate_transfer_gas() {
	local payload="$1"
	cast estimate --rpc-url "$READ_RPC_URL" --from "$VICTIM_WALLET" "$DUSD_TOKEN" "$payload"
}

ensure_gas_wallet_can_fund() {
	local gas_wallet="$1"
	local gas_price="$2"
	local gas_to_fill="$3"
	local gas_limit="$4"
	local gas_wallet_balance
	local tx_cost
	local total_required

	gas_wallet_balance=$(normalize_uint "$(cast balance "$gas_wallet" --rpc-url "$READ_RPC_URL")")
	tx_cost=$((gas_limit * gas_price))
	total_required=$((gas_to_fill + tx_cost))

	if [[ "$gas_wallet_balance" -lt "$total_required" ]]; then
		echo "Error: \`GAS_WALLET\` balance is insufficient."
		echo "Current balance: $(cast to-unit "$gas_wallet_balance" ether) BNB"
		echo "Required: $(cast to-unit "$total_required" ether) BNB"
		echo "Shortfall: $(cast to-unit "$((total_required - gas_wallet_balance))" ether) BNB"
		exit 1
	fi
}

submit_bundle_pair() {
	local topup_tx="$1"
	local action_tx="$2"
	local label="$3"
	local simulation_block
	local current_block

	echo "Preparing private bundle for $label..."
	simulation_block=$(($(cast block-number --rpc-url "$READ_RPC_URL") + 1))
	maybe_simulate_bundle "$topup_tx" "$action_tx" "$simulation_block"

	current_block=$(cast block-number --rpc-url "$READ_RPC_URL")
	send_bundle_for_target_blocks "$topup_tx" "$action_tx" "$current_block"
}

request_withdraw_bundle() {
	local gas_price
	local bundle_gas_floor
	local gas_to_fill
	local withdraw_gas_limit
	local estimated_topup_gas
	local topup_gas_limit
	local gas_nonce
	local victim_nonce
	local topup_tx
	local withdraw_tx
	local estimated_withdraw_gas

	gas_price=$(cast gas-price --rpc-url "$READ_RPC_URL")
	bundle_gas_floor=$(query_bundle_gas_floor || true)
	if [[ -n "${bundle_gas_floor:-}" && "$bundle_gas_floor" -gt "$gas_price" ]]; then
		gas_price="$bundle_gas_floor"
	fi
	if [[ "$gas_price" -lt "$MIN_GAS_PRICE_WEI" ]]; then
		gas_price="$MIN_GAS_PRICE_WEI"
	fi
	estimated_withdraw_gas=$(estimate_withdraw_gas)
	withdraw_gas_limit=$(mul_div_int "$estimated_withdraw_gas" "$REQUEST_TX_GAS_BUFFER_BPS" "10000")
	gas_to_fill=$((withdraw_gas_limit * gas_price))
	gas_to_fill=$(mul_div_int "$gas_to_fill" "$REQUEST_TOPUP_BUFFER_BPS" "10000")
	estimated_topup_gas=$(estimate_native_topup_gas "$GAS_WALLET" "$VICTIM_WALLET" "$gas_to_fill")
	topup_gas_limit=$(mul_div_int "$estimated_topup_gas" "120" "100")
	echo "Withdraw request gas price: $(cast to-unit "$gas_price" gwei) gwei"
	if [[ -n "${bundle_gas_floor:-}" ]]; then
		echo "Bundle gas floor: $(cast to-unit "$bundle_gas_floor" gwei) gwei"
	fi
	echo "Estimated top-up gas: $estimated_topup_gas"
	echo "Top-up gas limit: $topup_gas_limit"
	echo "Estimated withdraw gas: $estimated_withdraw_gas"
	echo "Withdraw tx gas limit: $withdraw_gas_limit"
	echo "Withdraw request gas top-up: $(cast to-unit "$gas_to_fill" ether) BNB"

	ensure_gas_wallet_can_fund "$GAS_WALLET" "$gas_price" "$gas_to_fill" "$topup_gas_limit"

	gas_nonce=$(cast nonce "$GAS_WALLET" --rpc-url "$READ_RPC_URL")
	victim_nonce=$(cast nonce "$VICTIM_WALLET" --rpc-url "$READ_RPC_URL")

	topup_tx=$(build_legacy_transaction "$GAS_PK" "$VICTIM_WALLET" "$gas_to_fill" "$gas_nonce" "$topup_gas_limit" "$gas_price")
	withdraw_tx=$(build_legacy_transaction "$VICTIM_PK" "$STANDX_HIGHWAY" 0 "$victim_nonce" "$withdraw_gas_limit" "$gas_price" "$WITHDRAW_PAYLOAD")

	echo "Top-up tx: $topup_tx"
	echo "Withdraw tx: $withdraw_tx"
	submit_bundle_pair "$topup_tx" "$withdraw_tx" "withdraw request"
}

watch_and_rescue_bundle() {
	local current_balance
	local rescue_amount
	local gas_price
	local bundle_gas_floor
	local gas_to_fill
	local transfer_gas_limit
	local estimated_topup_gas
	local topup_gas_limit
	local gas_nonce
	local victim_nonce
	local topup_tx
	local transfer_tx
	local transfer_payload
	local estimated_transfer_gas

	current_balance=$(get_dusd_balance "$VICTIM_WALLET")
	echo "Current DUSD balance in victim wallet at startup: $current_balance"

	while true; do
		current_balance=$(get_dusd_balance "$VICTIM_WALLET")
		echo "Current DUSD balance in victim wallet: $current_balance"

		if [[ "$current_balance" -gt 0 ]]; then
			if [[ -n "$RESCUE_TRANSFER_AMOUNT" ]]; then
				rescue_amount="$RESCUE_TRANSFER_AMOUNT"
			else
				rescue_amount="$current_balance"
			fi

			if [[ "$rescue_amount" -gt "$current_balance" ]]; then
				echo "Error: \`RESCUE_TRANSFER_AMOUNT\` exceeds current DUSD balance."
				exit 1
			fi

			gas_price=$(cast gas-price --rpc-url "$READ_RPC_URL")
			bundle_gas_floor=$(query_bundle_gas_floor || true)
			if [[ -n "${bundle_gas_floor:-}" && "$bundle_gas_floor" -gt "$gas_price" ]]; then
				gas_price="$bundle_gas_floor"
			fi
			if [[ "$gas_price" -lt "$MIN_GAS_PRICE_WEI" ]]; then
				gas_price="$MIN_GAS_PRICE_WEI"
			fi
			transfer_payload=$(cast calldata "transfer(address,uint256)" "$SAFE_WALLET" "$rescue_amount")
			estimated_transfer_gas=$(estimate_transfer_gas "$transfer_payload")
			transfer_gas_limit=$(mul_div_int "$estimated_transfer_gas" "$TRANSFER_TX_GAS_BUFFER_BPS" "10000")
			gas_to_fill=$((transfer_gas_limit * gas_price))
			gas_to_fill=$(mul_div_int "$gas_to_fill" "$TRANSFER_TOPUP_BUFFER_BPS" "10000")
			estimated_topup_gas=$(estimate_native_topup_gas "$GAS_WALLET" "$VICTIM_WALLET" "$gas_to_fill")
			topup_gas_limit=$(mul_div_int "$estimated_topup_gas" "120" "100")
			echo "Detected incoming DUSD. Rescue amount: $rescue_amount"
			echo "Transfer gas price: $(cast to-unit "$gas_price" gwei) gwei"
			if [[ -n "${bundle_gas_floor:-}" ]]; then
				echo "Bundle gas floor: $(cast to-unit "$bundle_gas_floor" gwei) gwei"
			fi
			echo "Estimated top-up gas: $estimated_topup_gas"
			echo "Top-up gas limit: $topup_gas_limit"
			echo "Estimated transfer gas: $estimated_transfer_gas"
			echo "Transfer gas limit: $transfer_gas_limit"
			echo "Transfer gas top-up: $(cast to-unit "$gas_to_fill" ether) BNB"

			ensure_gas_wallet_can_fund "$GAS_WALLET" "$gas_price" "$gas_to_fill" "$topup_gas_limit"

			gas_nonce=$(cast nonce "$GAS_WALLET" --rpc-url "$READ_RPC_URL")
			victim_nonce=$(cast nonce "$VICTIM_WALLET" --rpc-url "$READ_RPC_URL")

			topup_tx=$(build_legacy_transaction "$GAS_PK" "$VICTIM_WALLET" "$gas_to_fill" "$gas_nonce" "$topup_gas_limit" "$gas_price")
			transfer_tx=$(build_legacy_transaction "$VICTIM_PK" "$DUSD_TOKEN" 0 "$victim_nonce" "$transfer_gas_limit" "$gas_price" "$transfer_payload")

			echo "Top-up tx: $topup_tx"
			echo "Transfer tx: $transfer_tx"
			submit_bundle_pair "$topup_tx" "$transfer_tx" "DUSD rescue"
			exit 0
		fi

		echo "Waiting ${POLL_INTERVAL_SECONDS}s for DUSD arrival..."
		sleep "$POLL_INTERVAL_SECONDS"
	done
}

verify_dependencies() {
	if ! command -v cast >/dev/null 2>&1; then
		echo "Error: \`cast\` is required but not installed."
		exit 1
	fi
	if ! command -v python3 >/dev/null 2>&1; then
		echo "Error: \`python3\` is required but not installed."
		exit 1
	fi
}

verify_dependencies

if [[ "$MODE" == *"_bundle" && "$BUNDLE_RPC_URL" == "https://rpc.48.club" ]]; then
	echo "Error: bundle modes require 48 Club's Puissant endpoint, not the privacy RPC."
	echo "Set \`BUNDLE_RPC_URL=\"https://puissant-bsc.48.club\"\` in .env and try again."
	exit 1
fi

VICTIM_WALLET=$(derive_wallet "$VICTIM_PK")
GAS_WALLET=$(derive_wallet "$GAS_PK")

readonly VICTIM_WALLET
readonly GAS_WALLET

EXPECTED_VICTIM_WALLET="${EXPECTED_VICTIM_WALLET:-}"
if [[ -n "$EXPECTED_VICTIM_WALLET" && "$(lower_hex "$VICTIM_WALLET")" != "$(lower_hex "$EXPECTED_VICTIM_WALLET")" ]]; then
	echo "Error: \`VICTIM_PK\` does not derive to \`EXPECTED_VICTIM_WALLET\`."
	exit 1
fi

validate_withdraw_payload "$VICTIM_WALLET"

echo "Victim wallet: $VICTIM_WALLET"
echo "Gas wallet: $GAS_WALLET"
echo "Safe wallet: $SAFE_WALLET"
echo "StandX highway: $STANDX_HIGHWAY"
echo "DUSD token: $DUSD_TOKEN"

case "$MODE" in
request_withdraw_bundle)
	request_withdraw_bundle
	;;
watch_and_rescue_bundle)
	watch_and_rescue_bundle
	;;
*)
	echo "Error: \`MODE\` must be either \`request_withdraw_bundle\` or \`watch_and_rescue_bundle\`."
	exit 1
	;;
esac
