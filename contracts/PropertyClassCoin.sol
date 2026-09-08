// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "@openzeppelin/contracts/token/ERC20/ERC20.sol";

/// @title PropertyClassCoin
/// @notice A statically-pegged property-class coin (SHED, HOUS, VILA, ...).
///         The peg is a fixed, immutable ETH-per-unit rate set once at
///         deployment — there is no oracle, no keeper, nothing that
///         updates it. It's fully collateralized by construction: mint()
///         only ever issues coin backed by the exact ETH just deposited,
///         and redeem() only ever burns coin for the exact ETH that backs
///         it. The peg can't run short or break because it never holds
///         anything it isn't immediately entitled to pay back.
/// @dev Reference implementation for the Parcel demo. Unaudited. A real
///      deployment would want a live price feed behind this instead of a
///      fixed rate — see docs.html for why this one is intentionally
///      static for now.
contract PropertyClassCoin is ERC20 {
    uint256 public immutable weiPerUnit; // wei of ETH backing 1 whole coin (1e18 units)
    string public classTicker;

    event Minted(address indexed who, uint256 ethIn, uint256 coinOut);
    event Redeemed(address indexed who, uint256 coinIn, uint256 ethOut);

    constructor(string memory name_, string memory symbol_, uint256 weiPerUnit_) ERC20(name_, symbol_) {
        require(weiPerUnit_ > 0, "PropertyClassCoin: zero rate");
        weiPerUnit = weiPerUnit_;
        classTicker = symbol_;
    }

    /// @notice Mint coin by sending ETH, always at the fixed rate.
    function mint(uint256 minCoinOut) external payable returns (uint256 coinOut) {
        require(msg.value > 0, "PropertyClassCoin: zero amount");
        coinOut = msg.value * 1e18 / weiPerUnit;
        require(coinOut >= minCoinOut, "PropertyClassCoin: slippage");
        _mint(msg.sender, coinOut);
        emit Minted(msg.sender, msg.value, coinOut);
    }

    /// @notice Burn coin for ETH, always at the fixed rate.
    function redeem(uint256 coinIn, uint256 minEthOut) external returns (uint256 ethOut) {
        require(coinIn > 0, "PropertyClassCoin: zero amount");
        ethOut = coinIn * weiPerUnit / 1e18;
        require(ethOut >= minEthOut, "PropertyClassCoin: slippage");
        _burn(msg.sender, coinIn);
        (bool sent, ) = msg.sender.call{value: ethOut}("");
        require(sent, "PropertyClassCoin: ETH transfer failed");
        emit Redeemed(msg.sender, coinIn, ethOut);
    }
}
