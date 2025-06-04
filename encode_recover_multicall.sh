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

# Example payload that calls 2 ERC-20 contract addresses and transfers 5 tokens with decimals 6 to `RECIPIENT`.
readonly RECIPIENT="0x9F3f11d72d96910df008Cfe3aBA40F361D2EED03"
readonly AMOUNT="5000000"
transfer_calldata=$(cast calldata "transfer(address,uint256)" "$RECIPIENT" "$AMOUNT")
readonly CALLS="[(0x08210F9170F89Ab7658F0B5E3fF39b0E03C594D4,false,0,"$transfer_calldata"),(0x1c7D4B196Cb0C7B01d743Fbc6116a902379C7238,false,0,"$transfer_calldata")]"

# See https://github.com/pcaversaccio/snekmate/blob/6ec0070fc33c783d68ecc568ecfdbb6f7c2b685d/src/snekmate/utils/multicall.vy#L99-L135.
# Encode the `data` struct:
#   _DYNARRAY_BOUND: constant(uint8) = max_value(uint8)
#   data: DynArray[multicall.BatchValue, multicall._DYNARRAY_BOUND]
#   struct BatchValue:
#       target: address
#       allow_failure: bool
#       value: uint256
#       calldata: Bytes[1_024]
encoded_calldata=$(cast calldata "recover_multicall((address,bool,uint256,bytes)[])" "$CALLS")

# Save the rescue calldata to a file.
echo "$encoded_calldata" >encoded_calldata.txt

# Output the result.
echo "Rescue calldata: $encoded_calldata"
