// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {IUnlockCallback} from "@uniswap/v4-core/src/interfaces/callback/IUnlockCallback.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {BalanceDelta, BalanceDeltaLibrary} from "@uniswap/v4-core/src/types/BalanceDelta.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import {Launchpad} from "./Launchpad.sol";
import {PropertyClassCoin} from "./PropertyClassCoin.sol";
import {PegPool} from "./PegPool.sol";
import {ClassAsset} from "./libraries/ClassAsset.sol";

/// @title LaunchRouter
/// @notice The trading entry point for a market after it's created —
///         mirrors CME's "Launch router (V6)": wraps a plain ETH buy/sell
///         into the underlying pool swap, minting/burning the property
///         class coin under the hood when one was picked, so trading is
///         always just "connect wallet, send ETH, get tokens" regardless
///         of what the market's pool actually quotes against. Every swap
///         here works identically whether the market's price is inside
///         the curve range or the reserve range above the cap — there is
///         no migration state to check.
/// @dev Reference implementation. Unaudited.
contract LaunchRouter is IUnlockCallback {
    using BalanceDeltaLibrary for BalanceDelta;

    error NotPoolManager();
    error ZeroAmount();
    error Slippage();
    error TransferFailed();

    event Trade(
        uint256 indexed launchId, address indexed trader, bool isBuy, uint256 quoteIn, uint256 tokensOut, uint256 quoteOut, uint256 tokensIn
    );

    IPoolManager public immutable poolManager;
    Launchpad public immutable launchpad;

    constructor(IPoolManager poolManager_, Launchpad launchpad_) {
        poolManager = poolManager_;
        launchpad = launchpad_;
    }

    /// @notice Buy `launchId`'s token with ETH. If the market picked a
    ///         property class, the ETH is converted into that class coin
    ///         first (a fixed-rate mint for a static-tier coin, a swap
    ///         against the ask for a live-tier one), then swapped — the
    ///         trader never touches the coin.
    function buy(uint256 launchId, uint256 minTokensOut) external payable returns (uint256 tokensOut) {
        if (msg.value == 0) revert ZeroAmount();
        Launchpad.Launch memory l = launchpad.getLaunch(launchId);

        uint256 amountIn = _acquireQuoteAsset(l.quoteAsset, msg.value);

        (uint256 actualQuoteIn, uint256 tokensOut_) = abi.decode(
            poolManager.unlock(abi.encode(true, l.poolKey, l.tokenIsCurrency1, l.token, l.quoteAsset, amountIn, msg.sender)),
            (uint256, uint256)
        );
        tokensOut = tokensOut_;
        if (tokensOut < minTokensOut) revert Slippage();
        emit Trade(launchId, msg.sender, true, actualQuoteIn, tokensOut, 0, 0);
    }

    /// @notice Sell `tokenAmountIn` of `launchId`'s token back for its
    ///         quote asset (ETH, or the property class coin if one was
    ///         picked — sellers can hold or redeem that coin themselves).
    function sell(uint256 launchId, uint256 tokenAmountIn, uint256 minQuoteOut) external returns (uint256 quoteOut) {
        if (tokenAmountIn == 0) revert ZeroAmount();
        Launchpad.Launch memory l = launchpad.getLaunch(launchId);

        if (!IERC20(l.token).transferFrom(msg.sender, address(this), tokenAmountIn)) revert TransferFailed();

        quoteOut = abi.decode(
            poolManager.unlock(
                abi.encode(false, l.poolKey, l.tokenIsCurrency1, l.token, l.quoteAsset, tokenAmountIn, msg.sender)
            ),
            (uint256)
        );
        if (quoteOut < minQuoteOut) revert Slippage();
        emit Trade(launchId, msg.sender, false, 0, 0, quoteOut, tokenAmountIn);
    }

    function unlockCallback(bytes calldata data) external returns (bytes memory) {
        if (msg.sender != address(poolManager)) revert NotPoolManager();
        (bool isBuy, PoolKey memory key, bool t1, address token, address quoteAsset_, uint256 amountIn, address trader)
        = abi.decode(data, (bool, PoolKey, bool, address, address, uint256, address));

        if (isBuy) {
            (uint256 actualQuoteIn, uint256 tokensOut) = _buy(key, t1, quoteAsset_, amountIn, trader);
            return abi.encode(actualQuoteIn, tokensOut);
        } else {
            return abi.encode(_sell(key, t1, token, amountIn, trader));
        }
    }

    function _buy(PoolKey memory key, bool t1, address quoteAsset_, uint256 amountIn, address trader)
        internal
        returns (uint256 actualQuoteIn, uint256 tokensOut)
    {
        bool zeroForOne = t1;
        BalanceDelta delta = poolManager.swap(
            key,
            IPoolManager.SwapParams({
                zeroForOne: zeroForOne,
                amountSpecified: -int256(amountIn),
                sqrtPriceLimitX96: zeroForOne ? TickMath.MIN_SQRT_PRICE + 1 : TickMath.MAX_SQRT_PRICE - 1
            }),
            ""
        );
        int128 tokenOutDelta = t1 ? delta.amount1() : delta.amount0();
        int128 quoteInDelta = t1 ? delta.amount0() : delta.amount1();
        tokensOut = uint256(uint128(tokenOutDelta));
        actualQuoteIn = uint256(uint128(-quoteInDelta));

        Currency quoteCurrency = t1 ? key.currency0 : key.currency1;
        if (quoteAsset_ == address(0)) {
            poolManager.settle{value: actualQuoteIn}();
            if (actualQuoteIn < amountIn) {
                (bool sent,) = trader.call{value: amountIn - actualQuoteIn}("");
                if (!sent) revert TransferFailed();
            }
        } else {
            poolManager.sync(quoteCurrency);
            if (!IERC20(quoteAsset_).transfer(address(poolManager), actualQuoteIn)) revert TransferFailed();
            poolManager.settle();
            if (actualQuoteIn < amountIn) {
                if (!IERC20(quoteAsset_).transfer(trader, amountIn - actualQuoteIn)) revert TransferFailed();
            }
        }

        Currency tokenCurrency = t1 ? key.currency1 : key.currency0;
        poolManager.take(tokenCurrency, trader, tokensOut);
    }

    function _sell(PoolKey memory key, bool t1, address token, uint256 tokenAmountIn, address trader)
        internal
        returns (uint256 quoteOut)
    {
        bool zeroForOne = !t1;
        BalanceDelta delta = poolManager.swap(
            key,
            IPoolManager.SwapParams({
                zeroForOne: zeroForOne,
                amountSpecified: -int256(tokenAmountIn),
                sqrtPriceLimitX96: zeroForOne ? TickMath.MIN_SQRT_PRICE + 1 : TickMath.MAX_SQRT_PRICE - 1
            }),
            ""
        );
        int128 quoteOutDelta = t1 ? delta.amount0() : delta.amount1();
        int128 tokenInDelta = t1 ? delta.amount1() : delta.amount0();
        quoteOut = uint256(uint128(quoteOutDelta));
        uint256 actualTokenIn = uint256(uint128(-tokenInDelta));

        Currency tokenCurrency = t1 ? key.currency1 : key.currency0;
        poolManager.sync(tokenCurrency);
        if (!IERC20(token).transfer(address(poolManager), actualTokenIn)) revert TransferFailed();
        poolManager.settle();
        if (actualTokenIn < tokenAmountIn) {
            if (!IERC20(token).transfer(trader, tokenAmountIn - actualTokenIn)) revert TransferFailed();
        }

        Currency quoteCurrency = t1 ? key.currency0 : key.currency1;
        poolManager.take(quoteCurrency, trader, quoteOut);
    }

    /// @dev Converts `ethIn` into `quoteAsset_`: a fixed-rate mint for a
    ///      static-tier coin, or a swap against the ask for a live-tier
    ///      one. The live-tier path can leave some ETH unspent (the ask
    ///      might not hold enough inventory to absorb all of `ethIn` at
    ///      the current tick) — PegPool.buy() refunds that straight back
    ///      to whoever calls it, which is this contract, so it's forwarded
    ///      on to the trader here rather than getting stranded.
    function _acquireQuoteAsset(address quoteAsset_, uint256 ethIn) internal returns (uint256) {
        if (quoteAsset_ == address(0)) return ethIn;
        address pegPool = ClassAsset.pegPoolOf(quoteAsset_);
        if (pegPool == address(0)) return PropertyClassCoin(quoteAsset_).mint{value: ethIn}(0);

        uint256 balBefore = address(this).balance - ethIn;
        uint256 coinOut = PegPool(payable(pegPool)).buy{value: ethIn}(0);
        uint256 refund = address(this).balance - balBefore;
        if (refund > 0) {
            (bool sent,) = msg.sender.call{value: refund}("");
            if (!sent) revert TransferFailed();
        }
        return coinOut;
    }

    // Accepts refunded ETH mid-callback (e.g. leftover native quote) before forwarding it on.
    receive() external payable {}
}
