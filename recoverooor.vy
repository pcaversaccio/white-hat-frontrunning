# pragma version ~=0.4.2
# pragma nonreentrancy off
"""
@title Multi-Token Recovery Contract
@custom:contract-name recoverooor
@license GNU Affero General Public License v3.0 only
@author pcaversaccio
@notice These functions support (batch) recovery of both native assets
        and tokens across any standard (e.g., ERC-20, ERC-721, ERC-1155).
        When using EIP-7702 (https://eips.ethereum.org/EIPS/eip-7702),
        you can delegate to this contract and safely invoke and broadcast
        the appropriate recovery function from a trusted `OWNER` account.
        For batch recovery of native assets alongside multiple token transfers
        in a single transaction, use the `recover_multicall` function.
@custom:security This contract is untested and has not undergone a security audit.
                 Use with caution!
"""


# @dev We import the `IERC20`, `IERC721`, and `IERC1155` interfaces to
# enable easy recovery of these token types when EIP-7702 delegation is
# used.
from ethereum.ercs import IERC20
from ethereum.ercs import IERC721
from snekmate.tokens.interfaces import IERC1155


# @dev We import the `multicall` module.
# @notice Please note that the `multicall` module is stateless and therefore
# does not require the `initializes` keyword for initialisation.
from snekmate.utils import multicall


# @dev Stores the upper bound for batch calls.
_BATCH_SIZE: constant(uint8) = 128


# @dev Sets the trusted `OWNER` account.
# @notice We use an `immutable` variable instead of storage, since writes to storage
# in the constructor do not persist when using this contract as an implementation.
OWNER: public(immutable(address))


@deploy
def __init__(owner_: address):
    """
    @dev Transfers the ownership of the contract to a
         (trusted) account `owner_`.
    @param owner_ The 20-byte address of the owner.
    """
    OWNER = owner_


@external
def recover_eth():
    """
    @dev Transfers the full ether balance to a (trusted)
         account `OWNER`.
    """
    self._check_owner()
    # We force the full ether balance into the `OWNER` address.
    # For the `selfdestruct` behaviour, see: https://eips.ethereum.org/EIPS/eip-6780.
    selfdestruct(OWNER)


@external
def recover_erc20(tokens: DynArray[IERC20, _BATCH_SIZE]):
    """
    @dev Transfers the full ERC-20 balances of the specified
         contract addresses to a (trusted) account `OWNER`.
    @param tokens The 20-byte array of ERC-20 token contract
           addresses that are being transferred.
    """
    self._check_owner()
    for token: IERC20 in tokens:
        assert extcall token.transfer(
            OWNER, staticcall token.balanceOf(self), default_return_value=True
        ), "recoverooor: erc-20 transfer operation did not succeed"


@external
def recover_erc721(
    tokens: DynArray[IERC721, _BATCH_SIZE], token_ids: DynArray[DynArray[uint256, _BATCH_SIZE], _BATCH_SIZE]
):
    """
    @dev Transfers all ERC-721 `token_ids` of the specified
         contract addresses to a (trusted) account `OWNER`.
    @param tokens The 20-byte array of ERC-721 token contract
           addresses that are being transferred. Note that the
           length must match the 32-byte `token_ids` array.
    @param token_ids The 32-byte array of ERC-721 `token_ids`
           for each ERC-721 contract that are being transferred.
           Note that the length must match the 20-byte `tokens`
           array.
    """
    self._check_owner()
    assert len(tokens) == len(token_ids), "recoverooor: `tokens` and `token_ids` length mismatch"
    idx: uint256 = empty(uint256)
    for token: IERC721 in tokens:
        ids: DynArray[uint256, _BATCH_SIZE] = token_ids[idx]
        for id: uint256 in ids:
            extcall token.transferFrom(self, OWNER, id)
        idx = unsafe_add(idx, 1)


@external
def recover_erc1155(
    tokens: DynArray[IERC1155, _BATCH_SIZE],
    ids: DynArray[DynArray[uint256, _BATCH_SIZE], _BATCH_SIZE],
    amounts: DynArray[DynArray[uint256, _BATCH_SIZE], _BATCH_SIZE],
):
    """
    @dev Transfers all `amounts` for the token type `ids` of the
         specified ERC-1155 contract addresses `tokens` to a (trusted)
         account `OWNER`.
    @param tokens The 20-byte array of ERC-1155 token contract
           addresses that are being transferred. Note that the
           length must match the 32-byte `ids` and `amounts` arrays.
    @param ids The 32-byte array of token identifiers. Note that the
           length must match the 20-byte `tokens` arrays. Furthermore,
           note that for each array entry the order and length must
           match the 32-byte `amounts` array.
    @param amounts The 32-byte array of token amounts that are
           being transferred. Note that the length must match the
           20-byte `tokens` arrays. Furthermore, note that for each
           array entry the order and length must match the 32-byte
           `ids` array.
    """
    self._check_owner()
    assert len(tokens) == len(ids), "recoverooor: `tokens` and `ids` length mismatch"
    assert len(tokens) == len(amounts), "recoverooor: `tokens` and `amounts` length mismatch"
    idx: uint256 = empty(uint256)
    for token: IERC1155 in tokens:
        assert len(ids[idx]) == len(amounts[idx]), "recoverooor: `ids` and `amounts` length mismatch"
        extcall token.safeBatchTransferFrom(self, OWNER, ids[idx], amounts[idx], b"")
        idx = unsafe_add(idx, 1)


@external
@payable
def recover_multicall(
    data: DynArray[multicall.BatchValue, multicall._DYNARRAY_BOUND]
) -> DynArray[multicall.Result, multicall._DYNARRAY_BOUND]:
    """
    @dev Aggregates function calls with a `msg.value`, ensuring
         that each function returns successfully if required. Since
         this function uses `CALL`, the `msg.sender` will be the
         `recoverooor` contract itself.
    @notice This function is fully customisable and does not enforce
            any transfers to a (trusted) `OWNER` account, although this
            is still the recommended approach.
    @param data The array of `BatchValue` structs.
    @return DynArray The array of `Result` structs.
    """
    self._check_owner()
    return multicall._multicall_value(data)


@internal
def _check_owner():
    """
    @dev Throws if the sender is not the owner.
    """
    assert msg.sender == OWNER, "recoverooor: caller is not the owner"
