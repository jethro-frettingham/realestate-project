// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {IUnlockCallback} from "@uniswap/v4-core/src/interfaces/callback/IUnlockCallback.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {BalanceDelta, BalanceDeltaLibrary} from "@uniswap/v4-core/src/types/BalanceDelta.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {StateLibrary} from "@uniswap/v4-core/src/libraries/StateLibrary.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import {LiveClassCoin} from "./LiveClassCoin.sol";
import {LaunchMath} from "./libraries/LaunchMath.sol";
import {LiquidityAmounts} from "./libraries/LiquidityAmounts.sol";

/// @title PegPool
/// @notice A live-tier property class's peg, mirroring CME's own
///         description of how it keeps a coin at a reference price: a
///         single-sided Uniswap v4 position holding protocol-minted coin,
///         offered one tick-range above the reference rate, so "a buyer
///         never pays below the oracle." Real, composable AMM liquidity —
///         any router can buy this coin.
///
///         The naive alternative — a mutable-rate mint/redeem contract
///         like `PropertyClassCoin` but with an updatable rate — is
///         unsound: if the rate ever rises, a contract redeeming at a
///         flat rate from a pool of ETH collected at *lower*, older rates
///         can be short. This sidesteps that by never promising a fixed
///         redemption: `sell()` pays out of `ethReserves`, which only ever
///         holds ETH this pool has actually withdrawn from the ask
///         position — not merely "collected" in the sense of having been
///         paid in (that ETH sits inside the ask's own v4 liquidity until
///         someone pulls it out). `harvest()` is the permissionless pull:
///         anyone can call it to move a buy's ETH out of the position and
///         into `ethReserves`, any time, not just at a reprice. `sell()`
///         can never promise more than `ethReserves` actually holds. That's
///         a deliberate simplification of CME's fully two-sided AMM peg
///         (their bid is also just "every dollar the ask has collected,"
///         so this preserves the same solvency invariant without needing a
///         second dynamic position).
///
///         Repriced by `updater` (an ops key/multisig) whenever the
///         reference index publishes a new number — realistically
///         monthly-ish, not a 60s keeper, since none of these sources
///         (Redfin, USDA, RV pricing guides, ...) publish faster than
///         that.
/// @dev Reference implementation. Unaudited — the zero-liquidity reprice
///      trick this relies on is covered by test/PegPool.t.sol against a
///      real PoolManager, not asserted from reading the math alone.
contract PegPool is IUnlockCallback {
    using PoolIdLibrary for PoolKey;
    using BalanceDeltaLibrary for BalanceDelta;
    using StateLibrary for IPoolManager;

    error NotPoolManager();
    error NotUpdater();
    error ZeroAmount();
    error NotInitialized();
    error AlreadyInitialized();
    error InsufficientReserves();
    error Slippage();
    error TransferFailed();

    int24 public constant TICK_SPACING = 60;
    uint24 public constant FEE = 3_000; // 0.3%, static — no dynamic-fee hook needed
    uint256 public constant ASK_TARGET_SIZE = 100_000 ether; // matches CME's "$100k of coin"

    enum Action {
        SEED_ASK,
        BUY,
        REPOSITION,
        HARVEST
    }

    IPoolManager public immutable poolManager;
    LiveClassCoin public immutable coin;
    address public immutable updater;
    PoolKey public poolKey; // currency0 = ETH, currency1 = coin, always

    bool public initialized;
    uint256 public weiPerUnit; // current reference rate: wei of ETH per 1 whole coin
    int24 public feedTick; // pool inits/repriced to exactly this tick
    int24 public askLowerTick; // ask range is [askLowerTick, feedTick]
    uint256 public ethReserves; // ETH collected from buys, available to pay sellers

    event Initialized(uint256 weiPerUnit, int24 feedTick);
    event Repositioned(uint256 weiPerUnit, int24 feedTick);
    event Bought(address indexed trader, uint256 ethIn, uint256 coinOut);
    event Sold(address indexed trader, uint256 coinIn, uint256 ethOut);

    constructor(IPoolManager poolManager_, address updater_, string memory name_, string memory symbol_) {
        poolManager = poolManager_;
        updater = updater_;
        coin = new LiveClassCoin(name_, symbol_, address(this));
    }

    /// @notice The pool's id — a convenience so callers don't need to
    ///         reassemble `PoolKey` from `poolKey()`'s decomposed tuple
    ///         getter just to hash it.
    function poolId() external view returns (PoolId) {
        return poolKey.toId();
    }

    /// @notice Opens the pool at `weiPerUnit_` and seeds the initial ask.
    ///         One-time; `reposition()` handles every update after this.
    function initialize(uint256 weiPerUnit_) external {
        if (msg.sender != updater) revert NotUpdater();
        if (initialized) revert AlreadyInitialized();
        if (weiPerUnit_ == 0) revert ZeroAmount();
        initialized = true;

        poolKey = PoolKey({
            currency0: Currency.wrap(address(0)),
            currency1: Currency.wrap(address(coin)),
            fee: FEE,
            tickSpacing: TICK_SPACING,
            hooks: IHooks(address(0))
        });

        weiPerUnit = weiPerUnit_;
        feedTick = _tickForRate(weiPerUnit_);
        askLowerTick = feedTick - TICK_SPACING;

        poolManager.initialize(poolKey, TickMath.getSqrtPriceAtTick(feedTick));
        poolManager.unlock(abi.encode(Action.SEED_ASK, abi.encode(ASK_TARGET_SIZE)));
        emit Initialized(weiPerUnit_, feedTick);
    }

    /// @notice Repriced by `updater` when the reference index publishes a
    ///         new number: withdraws the current ask, moves the (now
    ///         liquidity-free) pool's price to the new rate, and places a
    ///         fresh ask there.
    function reposition(uint256 newWeiPerUnit) external {
        if (msg.sender != updater) revert NotUpdater();
        if (!initialized) revert NotInitialized();
        if (newWeiPerUnit == 0) revert ZeroAmount();
        poolManager.unlock(abi.encode(Action.REPOSITION, abi.encode(newWeiPerUnit)));
    }

    /// @notice Buy coin with ETH against the ask. Naturally capped at
    ///         whatever the ask currently holds — buying past it just
    ///         refunds the unused ETH rather than reverting.
    function buy(uint256 minCoinOut) external payable returns (uint256 coinOut) {
        if (msg.value == 0) revert ZeroAmount();
        coinOut = abi.decode(poolManager.unlock(abi.encode(Action.BUY, abi.encode(msg.value, msg.sender))), (uint256));
        if (coinOut < minCoinOut) revert Slippage();
    }

    /// @notice Pulls any ETH sitting in the ask position (from buys since
    ///         the last harvest or reprice) into `ethReserves`, and
    ///         re-seeds the ask back to its full target size. Callable by
    ///         anyone, any time — this is what actually makes a buy's ETH
    ///         available for sellers to draw on.
    function harvest() external {
        if (!initialized) revert NotInitialized();
        poolManager.unlock(abi.encode(Action.HARVEST, ""));
    }

    /// @notice Sell coin back for ETH, always at the current reference
    ///         rate — capped by `ethReserves`, i.e. exactly what's been
    ///         harvested from the ask so far. Reverts rather than
    ///         partial-filling if that's not enough; try a smaller amount,
    ///         or call `harvest()` first if a buy hasn't been pulled in yet.
    function sell(uint256 coinIn, uint256 minEthOut) external returns (uint256 ethOut) {
        if (coinIn == 0) revert ZeroAmount();
        ethOut = coinIn * weiPerUnit / 1 ether;
        if (ethOut < minEthOut) revert Slippage();
        if (ethOut > ethReserves) revert InsufficientReserves();
        ethReserves -= ethOut;
        coin.burn(msg.sender, coinIn);
        (bool sent,) = msg.sender.call{value: ethOut}("");
        if (!sent) revert TransferFailed();
        emit Sold(msg.sender, coinIn, ethOut);
    }

    function unlockCallback(bytes calldata data) external returns (bytes memory) {
        if (msg.sender != address(poolManager)) revert NotPoolManager();
        (Action action, bytes memory payload) = abi.decode(data, (Action, bytes));
        if (action == Action.SEED_ASK) {
            uint256 amount = abi.decode(payload, (uint256));
            _seedAsk(amount);
            return "";
        } else if (action == Action.BUY) {
            (uint256 ethIn, address trader) = abi.decode(payload, (uint256, address));
            return abi.encode(_buy(ethIn, trader));
        } else if (action == Action.REPOSITION) {
            uint256 newWeiPerUnit = abi.decode(payload, (uint256));
            _reposition(newWeiPerUnit);
            return "";
        } else {
            _removeCurrentAsk();
            // Snap price back to feedTick before reseeding — _seedAsk
            // assumes a single-sided (all-coin) position, which only
            // holds when the current tick sits exactly at the range's
            // upper bound, not wherever a buy left it mid-range.
            _moveToTick(feedTick);
            _seedAsk(ASK_TARGET_SIZE);
            return "";
        }
    }

    /// @dev `targetSize` is the ask's total desired coin inventory — this
    ///      mints only the shortfall against whatever balance the contract
    ///      already holds (e.g. coin recovered by `_reposition` from the
    ///      old ask), so recovered inventory is always reused, never
    ///      stranded.
    function _seedAsk(uint256 targetSize) internal {
        uint256 have = coin.balanceOf(address(this));
        if (targetSize > have) coin.mint(address(this), targetSize - have);

        uint160 sqrtLower = TickMath.getSqrtPriceAtTick(askLowerTick);
        uint160 sqrtUpper = TickMath.getSqrtPriceAtTick(feedTick);
        uint128 liquidity = LiquidityAmounts.getLiquidityForAmount1(sqrtLower, sqrtUpper, targetSize);

        (BalanceDelta delta,) = poolManager.modifyLiquidity(
            poolKey,
            IPoolManager.ModifyLiquidityParams({
                tickLower: askLowerTick,
                tickUpper: feedTick,
                liquidityDelta: int256(uint256(liquidity)),
                salt: bytes32(0)
            }),
            ""
        );
        uint256 owed = uint256(uint128(-delta.amount1()));
        poolManager.sync(poolKey.currency1);
        if (!IERC20(address(coin)).transfer(address(poolManager), owed)) revert TransferFailed();
        poolManager.settle();
    }

    function _buy(uint256 ethIn, address trader) internal returns (uint256 coinOut) {
        BalanceDelta delta = poolManager.swap(
            poolKey,
            IPoolManager.SwapParams({
                zeroForOne: true,
                amountSpecified: -int256(ethIn),
                sqrtPriceLimitX96: TickMath.getSqrtPriceAtTick(askLowerTick) + 1
            }),
            ""
        );
        uint256 actualEthIn = uint256(uint128(-delta.amount0()));
        coinOut = uint256(uint128(delta.amount1()));

        poolManager.settle{value: actualEthIn}();
        poolManager.take(poolKey.currency1, trader, coinOut);

        if (actualEthIn < ethIn) {
            (bool sent,) = trader.call{value: ethIn - actualEthIn}("");
            if (!sent) revert TransferFailed();
        }
        // Note: actualEthIn is NOT added to ethReserves here — it's sitting
        // inside the ask's own v4 liquidity now, not held by this contract.
        // harvest() (or the next reposition) is what actually pulls it out.
        emit Bought(trader, actualEthIn, coinOut);
    }

    /// @dev Removes all liquidity from the current ask range (a mix of
    ///      coin and ETH if it's been partially bought through) and takes
    ///      both into this contract's own balances — real ETH into
    ///      `ethReserves`, coin into `coin.balanceOf(address(this))` for
    ///      `_seedAsk` to reuse. No-op if the ask is already empty.
    function _removeCurrentAsk() internal {
        (uint128 liquidity,,) = _positionInfo(askLowerTick, feedTick);
        if (liquidity == 0) return;
        (BalanceDelta delta,) = poolManager.modifyLiquidity(
            poolKey,
            IPoolManager.ModifyLiquidityParams({
                tickLower: askLowerTick,
                tickUpper: feedTick,
                liquidityDelta: -int256(uint256(liquidity)),
                salt: bytes32(0)
            }),
            ""
        );
        int128 ethOwed = delta.amount0();
        int128 coinOwed = delta.amount1();
        if (ethOwed > 0) {
            poolManager.take(poolKey.currency0, address(this), uint256(uint128(ethOwed)));
            ethReserves += uint256(uint128(ethOwed));
        }
        if (coinOwed > 0) {
            poolManager.take(poolKey.currency1, address(this), uint256(uint128(coinOwed)));
        }
    }

    function _reposition(uint256 newWeiPerUnit) internal {
        _removeCurrentAsk();

        weiPerUnit = newWeiPerUnit;
        int24 newFeedTick = _tickForRate(newWeiPerUnit);
        _moveToTick(newFeedTick);
        feedTick = newFeedTick;
        askLowerTick = newFeedTick - TICK_SPACING;

        // Re-seed the ask at the new range, reusing any coin recovered above.
        _seedAsk(ASK_TARGET_SIZE);
        emit Repositioned(newWeiPerUnit, newFeedTick);
    }

    /// @dev Moves the pool's current price to `targetTick`. Only ever
    ///      called with zero active liquidity in range (after
    ///      `_removeCurrentAsk`), in which case a swap moves slot0 to the
    ///      target without needing any real amount in or out — verified
    ///      against a real PoolManager in test/PegPool.t.sol, not just
    ///      inferred from reading the swap math.
    function _moveToTick(int24 targetTick) internal {
        int24 current = _currentTick();
        if (targetTick == current) return;
        bool movingDown = targetTick < current;
        poolManager.swap(
            poolKey,
            IPoolManager.SwapParams({
                zeroForOne: movingDown,
                amountSpecified: -1,
                sqrtPriceLimitX96: TickMath.getSqrtPriceAtTick(targetTick)
            }),
            ""
        );
    }

    function _tickForRate(uint256 weiPerUnit_) internal pure returns (int24) {
        return LaunchMath.floorToSpacing(
            TickMath.getTickAtSqrtPrice(LaunchMath.sqrtPriceX96AtCap(weiPerUnit_, 1 ether, true)), TICK_SPACING
        );
    }

    function _currentTick() internal view returns (int24 tick) {
        (, tick,,) = poolManager.getSlot0(poolKey.toId());
    }

    function _positionInfo(int24 tickLower, int24 tickUpper)
        internal
        view
        returns (uint128 liquidity, uint256 feeGrowthInside0X128, uint256 feeGrowthInside1X128)
    {
        return poolManager.getPositionInfo(poolKey.toId(), address(this), tickLower, tickUpper, bytes32(0));
    }

    // Accepts ETH from PoolManager.take() during reposition, and stray refunds.
    receive() external payable {}
}
