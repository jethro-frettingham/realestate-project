// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "./interfaces/IUniswapV4Migrator.sol";

/// @title TestnetMigrator
/// @notice Stands in for a real Uniswap v4 migration on Robinhood Chain
///         Testnet. It does not create a pool — it just pulls the raised
///         pair coin and the reserved 200,000,000 tokens out of the curve
///         and holds them, so `BondingCurve._migrate()` has something real
///         to call and a launch's sellout doesn't revert.
///
///         This means a migrated market has no trading venue on testnet —
///         there is nowhere to buy or sell it after sellout. That's an
///         accurate limitation to demo, not a bug: swap this contract for
///         a real `IUniswapV4Migrator` implementation once Uniswap v4 (or
///         an equivalent AMM) has a deployment on the target chain.
/// @dev Testnet only. Funds sent here are not recoverable through this
///      contract — there's no withdraw function, on purpose, so it can't
///      be mistaken for something safe to point at mainnet funds.
contract TestnetMigrator is IUniswapV4Migrator {
    using SafeERC20 for IERC20;

    event Held(address indexed token, address indexed pairCoin, uint256 pairAmount, uint256 tokenAmount, uint16 feeBps);

    function createAndSeedPool(
        address token,
        address pairCoin,
        uint256 pairAmount,
        uint256 tokenAmount,
        uint16 feeBps
    ) external override {
        IERC20(token).safeTransferFrom(msg.sender, address(this), tokenAmount);
        IERC20(pairCoin).safeTransferFrom(msg.sender, address(this), pairAmount);
        emit Held(token, pairCoin, pairAmount, tokenAmount, feeBps);
    }
}
