// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/// @title IUniswapV4Migrator
/// @notice The shape a BondingCurve needs from a migration adapter. This
///         repo does not include a real Uniswap v4 integration — a
///         production `migrator` would implement this interface against
///         v4's PoolManager and hook system so migrated pools launch with
///         the same fee the creator chose, enforced by a fee-locking hook,
///         and with liquidity sent to a burn address or a non-custodial
///         locker so it can never be withdrawn.
interface IUniswapV4Migrator {
    /// @param token       The ParcelToken being migrated
    /// @param tokenAmount The reserved 200,000,000 tokens, to seed the pool
    /// @param feeBps      The trading fee to lock into the pool (100–300)
    /// The ETH raised on the curve is sent as msg.value alongside the call.
    function createAndSeedPool(
        address token,
        uint256 tokenAmount,
        uint16 feeBps
    ) external payable;
}
