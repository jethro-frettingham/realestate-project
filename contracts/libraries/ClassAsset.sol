// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/// @title ClassAsset
/// @notice A quote asset picked for a launch is either a static-tier
///         `PropertyClassCoin` (fixed rate, fully-collateralized mint/
///         redeem) or a live-tier `LiveClassCoin` (minted/burned only by
///         its owning `PegPool`, priced by a variable-rate single-sided
///         AMM ask instead of a fixed rate). Both expose an identically-
///         shaped `classTicker()` getter, but only the live-tier coin
///         exposes `pegPool()` — probing for it (a plain staticcall, so a
///         missing function just returns `ok == false` instead of
///         reverting) is how callers tell them apart without needing the
///         coin's own deploy-time tier flag threaded through everywhere
///         that just holds an address.
library ClassAsset {
    /// @return pool The coin's owning PegPool, or address(0) if `coin` is
    ///         a static-tier PropertyClassCoin (or anything else that
    ///         doesn't expose `pegPool()`).
    function pegPoolOf(address coin) internal view returns (address pool) {
        (bool ok, bytes memory data) = coin.staticcall(abi.encodeWithSignature("pegPool()"));
        if (ok && data.length == 32) pool = abi.decode(data, (address));
    }
}
