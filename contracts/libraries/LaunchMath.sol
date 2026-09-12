// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {FullMath} from "@uniswap/v4-core/src/libraries/FullMath.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import "@openzeppelin/contracts/utils/math/Math.sol";

/// @title LaunchMath
/// @notice Converts a target market cap (in raw quote-asset units) into a
///         v4 sqrtPriceX96 / tick, and aligns ticks to a pool's spacing.
///         Kept separate from `Launchpad` so the market-cap math has its
///         own focused unit tests independent of pool-interaction plumbing.
library LaunchMath {
    uint256 internal constant Q192 = 1 << 192;

    /// @notice sqrtPriceX96 for the pool state where `capQuoteRaw` of the
    ///         quote asset equals `totalSupplyRaw` of the token at the
    ///         target market cap — i.e. price-per-token = capQuoteRaw / totalSupplyRaw,
    ///         both in raw (18-decimal) units.
    /// @param tokenIsCurrency1 True if the launch token sorts above the
    ///        quote asset's address (token is currency1 of the pool).
    function sqrtPriceX96AtCap(uint256 capQuoteRaw, uint256 totalSupplyRaw, bool tokenIsCurrency1)
        internal
        pure
        returns (uint160)
    {
        // v4 pool price is defined as currency1 / currency0.
        (uint256 num, uint256 den) = tokenIsCurrency1
            ? (totalSupplyRaw, capQuoteRaw) // price = token/quote = supply/cap
            : (capQuoteRaw, totalSupplyRaw); // price = quote/token = cap/supply
        uint256 ratioX192 = FullMath.mulDiv(num, Q192, den);
        return uint160(Math.sqrt(ratioX192));
    }

    /// @notice Largest multiple of `spacing` that is <= `tick`.
    function floorToSpacing(int24 tick, int24 spacing) internal pure returns (int24) {
        int24 r = tick % spacing;
        if (r < 0) r += spacing;
        return tick - r;
    }

    /// @notice Smallest multiple of `spacing` that is >= `tick`.
    function ceilToSpacing(int24 tick, int24 spacing) internal pure returns (int24) {
        int24 f = floorToSpacing(tick, spacing);
        return f == tick ? f : f + spacing;
    }

    /// @notice Clamps `tick` to v4's usable range for `spacing`.
    function clampUsable(int24 tick, int24 spacing) internal pure returns (int24) {
        int24 lo = TickMath.minUsableTick(spacing);
        int24 hi = TickMath.maxUsableTick(spacing);
        if (tick < lo) return lo;
        if (tick > hi) return hi;
        return tick;
    }
}
