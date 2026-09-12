// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {FullMath} from "@uniswap/v4-core/src/libraries/FullMath.sol";
import {FixedPoint96} from "@uniswap/v4-core/src/libraries/FixedPoint96.sol";

/// @title LiquidityAmounts
/// @notice Converts a token amount into the `liquidity` units Uniswap v4
///         positions are denominated in, for a single-sided range (current
///         price sits exactly at one edge of the range). Ported from the
///         standard Uniswap v3/v4 periphery formulas — this repo vendors
///         v4-core only, not periphery, so these two helpers are
///         reimplemented locally rather than pulled in as a dependency.
library LiquidityAmounts {
    /// @notice Liquidity for a given amount of currency0, valid when the
    ///         current price is at or below sqrtRatioAX96 (position is
    ///         entirely currency0).
    function getLiquidityForAmount0(uint160 sqrtRatioAX96, uint160 sqrtRatioBX96, uint256 amount0)
        internal
        pure
        returns (uint128 liquidity)
    {
        if (sqrtRatioAX96 > sqrtRatioBX96) (sqrtRatioAX96, sqrtRatioBX96) = (sqrtRatioBX96, sqrtRatioAX96);
        uint256 intermediate = FullMath.mulDiv(sqrtRatioAX96, sqrtRatioBX96, FixedPoint96.Q96);
        liquidity = uint128(FullMath.mulDiv(amount0, intermediate, sqrtRatioBX96 - sqrtRatioAX96));
    }

    /// @notice Liquidity for a given amount of currency1, valid when the
    ///         current price is at or above sqrtRatioBX96 (position is
    ///         entirely currency1).
    function getLiquidityForAmount1(uint160 sqrtRatioAX96, uint160 sqrtRatioBX96, uint256 amount1)
        internal
        pure
        returns (uint128 liquidity)
    {
        if (sqrtRatioAX96 > sqrtRatioBX96) (sqrtRatioAX96, sqrtRatioBX96) = (sqrtRatioBX96, sqrtRatioAX96);
        liquidity = uint128(FullMath.mulDiv(amount1, FixedPoint96.Q96, sqrtRatioBX96 - sqrtRatioAX96));
    }
}
