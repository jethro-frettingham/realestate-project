// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "./PriceOracle.sol";

/// @title PropertyClassCoin
/// @notice One per property class (SHED, VILA, HOUS, ...). Freely mintable
///         against USDG at the oracle's index price and burnable back to
///         USDG at the same price, which is what keeps it trading at the
///         class's index — the single-sided pool the docs page refers to.
///         BondingCurve and, after migration, the Uniswap v4 pool both
///         trade the launch token against this coin.
/// @dev Reference implementation for the Parcel demo. Unaudited. A real
///      deployment should rate-limit or fee mint/redeem to resist oracle-
///      lag arbitrage, and should confirm USDG reserves cover redemptions
///      rather than assuming it via a simple balance check.
contract PropertyClassCoin is ERC20 {
    using SafeERC20 for IERC20;

    IERC20 public immutable usdg;
    PriceOracle public immutable oracle;
    string public classTicker; // e.g. "SHED" — key into the oracle

    constructor(
        string memory name_,
        string memory symbol_,
        address usdg_,
        address oracle_,
        string memory classTicker_
    ) ERC20(name_, symbol_) {
        usdg = IERC20(usdg_);
        oracle = PriceOracle(oracle_);
        classTicker = classTicker_;
    }

    /// @notice Mint coin by depositing USDG at the current index price.
    function mint(uint256 usdgIn) external returns (uint256 coinOut) {
        uint256 usdPerUnit = oracle.currentPrice(classTicker); // 18dp
        coinOut = usdgIn * 1e18 / usdPerUnit;
        usdg.safeTransferFrom(msg.sender, address(this), usdgIn);
        _mint(msg.sender, coinOut);
    }

    /// @notice Redeem coin for USDG at the current index price.
    function redeem(uint256 coinIn) external returns (uint256 usdgOut) {
        uint256 usdPerUnit = oracle.currentPrice(classTicker);
        usdgOut = coinIn * usdPerUnit / 1e18;
        _burn(msg.sender, coinIn);
        usdg.safeTransfer(msg.sender, usdgOut);
    }
}
