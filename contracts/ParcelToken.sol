// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "@openzeppelin/contracts/token/ERC20/ERC20.sol";

/// @title ParcelToken
/// @notice The ERC20 minted for a single launch. Fixed supply, minted once
///         to the curve at creation — there is no further mint function,
///         so a launch can never dilute itself after it exists.
/// @dev Reference implementation for the Parcel demo. Unaudited.
contract ParcelToken is ERC20 {
    uint256 public constant TOTAL_SUPPLY = 1_000_000_000 ether;

    /// @param name_   Market name, e.g. "Nana's Storage Shed"
    /// @param symbol_ Market ticker, e.g. "NANASHED"
    /// @param curve   The BondingCurve contract that receives the full supply
    constructor(string memory name_, string memory symbol_, address curve)
        ERC20(name_, symbol_)
    {
        _mint(curve, TOTAL_SUPPLY);
    }
}
