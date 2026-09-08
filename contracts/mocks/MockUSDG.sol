// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "@openzeppelin/contracts/token/ERC20/ERC20.sol";

/// @title MockUSDG
/// @notice Testnet-only stand-in for USDG. Real USDG isn't deployed on
///         Robinhood Chain Testnet, so PropertyClassCoin mint/redeem needs
///         something to hold — anyone can mint this freely, which is the
///         point: it should never be treated as having value.
/// @dev Do not deploy this to mainnet. It is intentionally open-mint.
contract MockUSDG is ERC20 {
    constructor() ERC20("Mock USDG (testnet)", "mUSDG") {}

    /// @notice Mint testnet USDG to yourself, e.g. before minting property
    ///         class coins or making a launch's first buy.
    function faucet(uint256 amount) external {
        _mint(msg.sender, amount);
    }
}
