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
import {LPFeeLibrary} from "@uniswap/v4-core/src/libraries/LPFeeLibrary.sol";
import {StateLibrary} from "@uniswap/v4-core/src/libraries/StateLibrary.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import {ParcelToken} from "./ParcelToken.sol";
import {PropertyClassCoin} from "./PropertyClassCoin.sol";
import {FeeHook} from "./FeeHook.sol";
import {LaunchMath} from "./libraries/LaunchMath.sol";
import {LiquidityAmounts} from "./libraries/LiquidityAmounts.sol";

/// @title Launchpad
/// @notice Singleton launchpad, mirroring CME's own description of its
///         current (V6) design: "a market is a plain Uniswap v4 pool with
///         real liquidity from the block it is created... nothing
///         migrates." A launch mints the full 1,000,000,000 token supply
///         directly into a v4 pool as two concentrated liquidity ranges —
///         800,000,000 tokens from the opening price to the cap price (the
///         "curve"), and 200,000,000 tokens above the cap (the reserve),
///         so the pool keeps quoting with no cliff once the cap is
///         crossed. There is no migration step and no `migrated` lock:
///         sells work identically before and after the price crosses the
///         cap tick, because it's the same real AMM liquidity throughout.
///
///         Picking a property class makes that class's coin the market's
///         quote asset for its entire life (instead of ETH) — `LaunchRouter`
///         mints/burns the class coin under the hood so buying and selling
///         is still just "connect wallet, send ETH" from the trader's side.
///
///         `Launchpad` owns every market's liquidity positions directly
///         under Uniswap v4's singleton accounting. There is no withdraw
///         function anywhere in this contract, on purpose — the liquidity
///         is non-custodial forever, the same invariant this repo's
///         original `TestnetMigrator` called out as required before it's
///         safe to point at mainnet funds.
/// @dev Reference implementation. Unaudited — needs real test coverage
///      (including against a locally-deployed real `PoolManager`, not a
///      mock) and ideally a third-party audit before mainnet funds.
contract Launchpad is IUnlockCallback {
    using PoolIdLibrary for PoolKey;
    using BalanceDeltaLibrary for BalanceDelta;
    using StateLibrary for IPoolManager;

    error NotPoolManager();
    error FeeOutOfRange();
    error FirstBuyRequired();
    error Slippage();
    error TransferFailed();

    uint256 public constant TOTAL_SUPPLY = 1_000_000_000 ether;
    uint256 public constant CURVE_SUPPLY = 800_000_000 ether;
    uint256 public constant RESERVE_SUPPLY = 200_000_000 ether;
    int24 public constant TICK_SPACING = 60;

    uint16 public constant HOLDER_BPS = 4_000; // 40%
    uint16 public constant BUYBACK_BPS = 3_000; // 30%
    uint16 public constant PROTOCOL_BPS = 3_000; // 30%
    uint16 public constant BPS_DENOM = 10_000;

    bytes32 private constant CURVE_SALT = bytes32(uint256(1));
    bytes32 private constant RESERVE_SALT = bytes32(uint256(2));

    enum Action {
        SEED_AND_BUY,
        COLLECT_FEES
    }

    struct Launch {
        address token;
        address quoteAsset; // address(0) = ETH
        address creator;
        uint16 feeBps;
        string propertyClass;
        string metadataURI;
        uint64 createdAt;
        PoolKey poolKey;
        bool tokenIsCurrency1;
        int24 openTick;
        int24 capTick;
        int24 farTick;
    }

    IPoolManager public immutable poolManager;
    FeeHook public immutable feeHook;
    address public immutable buyback;
    address public immutable protocolTreasury;
    uint256 public immutable openCapWei; // sized at deploy time to a $5,000 opening cap
    uint256 public immutable migrateCapWei; // sized at deploy time to a $35,000 cap

    Launch[] public launches;
    mapping(address => uint256[]) public launchesByCreator;

    event LaunchCreated(
        uint256 indexed launchId,
        address indexed creator,
        address token,
        address quoteAsset,
        string propertyClass,
        uint16 feeBps,
        string metadataURI
    );
    event FeesCollected(uint256 indexed launchId, uint256 holderCut, uint256 buybackCut, uint256 protocolCut);
    event Trade(
        uint256 indexed launchId, address indexed trader, bool isBuy, uint256 quoteIn, uint256 tokensOut, uint256 quoteOut, uint256 tokensIn
    );

    constructor(
        IPoolManager poolManager_,
        FeeHook feeHook_,
        address buyback_,
        address protocolTreasury_,
        uint256 openCapWei_,
        uint256 migrateCapWei_
    ) {
        poolManager = poolManager_;
        feeHook = feeHook_;
        buyback = buyback_;
        protocolTreasury = protocolTreasury_;
        openCapWei = openCapWei_;
        migrateCapWei = migrateCapWei_;
    }

    function launchCount() external view returns (uint256) {
        return launches.length;
    }

    function launchesOf(address creator) external view returns (uint256[] memory) {
        return launchesByCreator[creator];
    }

    function getLaunch(uint256 launchId) external view returns (Launch memory) {
        return launches[launchId];
    }

    /// @notice Live pool price/tick for a market — one view call, so the
    ///         front end doesn't need to replicate v4's storage-slot math
    ///         to read `Slot0` itself.
    function getPoolState(uint256 launchId) external view returns (uint160 sqrtPriceX96, int24 tick) {
        PoolId id = launches[launchId].poolKey.toId();
        (sqrtPriceX96, tick,,) = poolManager.getSlot0(id);
    }

    /// @param quoteAsset_ address(0) for a plain-ETH market, or a
    ///        `PropertyClassCoin` address to pick a property class.
    function createLaunch(
        string calldata name_,
        string calldata symbol_,
        address quoteAsset_,
        uint16 feeBps,
        string calldata metadataURI,
        uint256 minTokensOut
    ) external payable returns (uint256 launchId, address tokenAddr) {
        if (feeBps < 100 || feeBps > 300) revert FeeOutOfRange();
        if (msg.value == 0) revert FirstBuyRequired();

        ParcelToken token = new ParcelToken(name_, symbol_, address(this), quoteAsset_, address(poolManager));
        tokenAddr = address(token);

        string memory propertyClass_ = quoteAsset_ == address(0) ? "" : PropertyClassCoin(quoteAsset_).classTicker();

        bool tokenIsCurrency1 = quoteAsset_ < tokenAddr;
        PoolKey memory key = PoolKey({
            currency0: tokenIsCurrency1 ? Currency.wrap(quoteAsset_) : Currency.wrap(tokenAddr),
            currency1: tokenIsCurrency1 ? Currency.wrap(tokenAddr) : Currency.wrap(quoteAsset_),
            fee: LPFeeLibrary.DYNAMIC_FEE_FLAG,
            tickSpacing: TICK_SPACING,
            hooks: IHooks(address(feeHook))
        });

        uint256 openCap = _capInQuoteUnits(quoteAsset_, openCapWei);
        uint256 migrateCap = _capInQuoteUnits(quoteAsset_, migrateCapWei);

        int24 openTickRaw =
            TickMath.getTickAtSqrtPrice(LaunchMath.sqrtPriceX96AtCap(openCap, TOTAL_SUPPLY, tokenIsCurrency1));
        int24 capTickRaw =
            TickMath.getTickAtSqrtPrice(LaunchMath.sqrtPriceX96AtCap(migrateCap, TOTAL_SUPPLY, tokenIsCurrency1));

        int24 openTick;
        int24 capTick;
        int24 farTick;
        if (tokenIsCurrency1) {
            // price falls as market cap rises: openTick > capTick > farTick
            openTick = LaunchMath.ceilToSpacing(openTickRaw, TICK_SPACING);
            capTick = LaunchMath.floorToSpacing(capTickRaw, TICK_SPACING);
            if (capTick >= openTick) capTick = openTick - TICK_SPACING;
            farTick = LaunchMath.clampUsable(TickMath.minUsableTick(TICK_SPACING), TICK_SPACING);
        } else {
            openTick = LaunchMath.floorToSpacing(openTickRaw, TICK_SPACING);
            capTick = LaunchMath.ceilToSpacing(capTickRaw, TICK_SPACING);
            if (capTick <= openTick) capTick = openTick + TICK_SPACING;
            farTick = LaunchMath.clampUsable(TickMath.maxUsableTick(TICK_SPACING), TICK_SPACING);
        }

        PoolId id = key.toId();
        feeHook.setPendingFee(id, uint24(feeBps) * 100);
        poolManager.initialize(key, TickMath.getSqrtPriceAtTick(openTick));

        launchId = launches.length;
        launches.push(
            Launch({
                token: tokenAddr,
                quoteAsset: quoteAsset_,
                creator: msg.sender,
                feeBps: feeBps,
                propertyClass: propertyClass_,
                metadataURI: metadataURI,
                createdAt: uint64(block.timestamp),
                poolKey: key,
                tokenIsCurrency1: tokenIsCurrency1,
                openTick: openTick,
                capTick: capTick,
                farTick: farTick
            })
        );
        launchesByCreator[msg.sender].push(launchId);

        uint256 tokensOut = abi.decode(
            poolManager.unlock(abi.encode(Action.SEED_AND_BUY, abi.encode(launchId, msg.value, msg.sender))),
            (uint256)
        );
        if (tokensOut < minTokensOut) revert Slippage();

        emit LaunchCreated(launchId, msg.sender, tokenAddr, quoteAsset_, propertyClass_, feeBps, metadataURI);
    }

    /// @notice Permissionless: pulls accrued LP fees for a market's two
    ///         positions and routes them 40% holders / 30% buyback / 30%
    ///         protocol. Anyone can call this, anytime — no keeper.
    function collectFees(uint256 launchId) external {
        poolManager.unlock(abi.encode(Action.COLLECT_FEES, abi.encode(launchId)));
    }

    function unlockCallback(bytes calldata data) external returns (bytes memory) {
        if (msg.sender != address(poolManager)) revert NotPoolManager();
        (Action action, bytes memory payload) = abi.decode(data, (Action, bytes));
        if (action == Action.SEED_AND_BUY) {
            return abi.encode(_seedAndBuy(payload));
        } else {
            _collectFees(payload);
            return "";
        }
    }

    // ---------------------------------------------------------------
    // Internal: pool seeding + first buy
    // ---------------------------------------------------------------

    function _seedAndBuy(bytes memory payload) internal returns (uint256 tokensOut) {
        (uint256 launchId, uint256 firstBuyIn, address buyer) = abi.decode(payload, (uint256, uint256, address));
        Launch storage l = launches[launchId];
        PoolKey memory key = l.poolKey;
        bool t1 = l.tokenIsCurrency1;

        (int24 curveLower, int24 curveUpper) = t1 ? (l.capTick, l.openTick) : (l.openTick, l.capTick);
        uint128 curveLiquidity = _liquidityFor(curveLower, curveUpper, CURVE_SUPPLY, t1);

        (int24 reserveLower, int24 reserveUpper) = t1 ? (l.farTick, l.capTick) : (l.capTick, l.farTick);
        uint128 reserveLiquidity = _liquidityFor(reserveLower, reserveUpper, RESERVE_SUPPLY, t1);

        (BalanceDelta d1,) = poolManager.modifyLiquidity(
            key,
            IPoolManager.ModifyLiquidityParams({
                tickLower: curveLower,
                tickUpper: curveUpper,
                liquidityDelta: int256(uint256(curveLiquidity)),
                salt: CURVE_SALT
            }),
            ""
        );
        (BalanceDelta d2,) = poolManager.modifyLiquidity(
            key,
            IPoolManager.ModifyLiquidityParams({
                tickLower: reserveLower,
                tickUpper: reserveUpper,
                liquidityDelta: int256(uint256(reserveLiquidity)),
                salt: RESERVE_SALT
            }),
            ""
        );

        // Gross token debt from seeding both ranges — settled in full
        // below, independent of the swap. The swap's own token *output* is
        // a separate credit that `take()` pulls out afterward; netting the
        // two together before settling would double-count that credit and
        // leave the buyer's tokens stranded in the manager.
        int128 tokenLiquidityDeltaRaw = t1 ? (d1 + d2).amount1() : (d1 + d2).amount0();
        uint256 tokenLiquidityDebt = uint256(uint128(-tokenLiquidityDeltaRaw));

        uint256 actualQuoteIn = 0;
        uint256 mintedQuote = 0;
        if (firstBuyIn > 0) {
            mintedQuote = l.quoteAsset == address(0)
                ? firstBuyIn
                : PropertyClassCoin(l.quoteAsset).mint{value: firstBuyIn}(0);

            bool zeroForOne = t1;
            BalanceDelta swapDelta = poolManager.swap(
                key,
                IPoolManager.SwapParams({
                    zeroForOne: zeroForOne,
                    amountSpecified: -int256(mintedQuote),
                    sqrtPriceLimitX96: zeroForOne ? TickMath.MIN_SQRT_PRICE + 1 : TickMath.MAX_SQRT_PRICE - 1
                }),
                ""
            );
            int128 tokenOutDelta = t1 ? swapDelta.amount1() : swapDelta.amount0();
            int128 quoteInDelta = t1 ? swapDelta.amount0() : swapDelta.amount1();
            tokensOut = uint256(uint128(tokenOutDelta));
            actualQuoteIn = uint256(uint128(-quoteInDelta));

            if (actualQuoteIn < mintedQuote) {
                uint256 leftover = mintedQuote - actualQuoteIn;
                if (l.quoteAsset == address(0)) {
                    (bool sent,) = buyer.call{value: leftover}("");
                    if (!sent) revert TransferFailed();
                } else {
                    if (!IERC20(l.quoteAsset).transfer(buyer, leftover)) revert TransferFailed();
                }
            }
        }

        // Settle the full gross token debt from seeding both ranges.
        if (tokenLiquidityDebt > 0) {
            Currency tokenCurrency = t1 ? key.currency1 : key.currency0;
            poolManager.sync(tokenCurrency);
            if (!IERC20(l.token).transfer(address(poolManager), tokenLiquidityDebt)) revert TransferFailed();
            poolManager.settle();
        }

        // Settle the quote side owed from the buy, and pay the buyer their tokens.
        if (firstBuyIn > 0) {
            Currency quoteCurrency = t1 ? key.currency0 : key.currency1;
            if (l.quoteAsset == address(0)) {
                poolManager.settle{value: actualQuoteIn}();
            } else {
                poolManager.sync(quoteCurrency);
                if (!IERC20(l.quoteAsset).transfer(address(poolManager), actualQuoteIn)) revert TransferFailed();
                poolManager.settle();
            }
            Currency tokenCurrency = t1 ? key.currency1 : key.currency0;
            poolManager.take(tokenCurrency, buyer, tokensOut);
            emit Trade(launchId, buyer, true, actualQuoteIn, tokensOut, 0, 0);
        }
    }

    function _liquidityFor(int24 lower, int24 upper, uint256 tokenAmount, bool tokenIsCurrency1)
        internal
        pure
        returns (uint128)
    {
        uint160 sqrtLower = TickMath.getSqrtPriceAtTick(lower);
        uint160 sqrtUpper = TickMath.getSqrtPriceAtTick(upper);
        return tokenIsCurrency1
            ? LiquidityAmounts.getLiquidityForAmount1(sqrtLower, sqrtUpper, tokenAmount)
            : LiquidityAmounts.getLiquidityForAmount0(sqrtLower, sqrtUpper, tokenAmount);
    }

    // ---------------------------------------------------------------
    // Internal: fee collection + distribution
    // ---------------------------------------------------------------

    function _collectFees(bytes memory payload) internal {
        uint256 launchId = abi.decode(payload, (uint256));
        Launch storage l = launches[launchId];
        PoolKey memory key = l.poolKey;
        bool t1 = l.tokenIsCurrency1;

        (int24 curveLower, int24 curveUpper) = t1 ? (l.capTick, l.openTick) : (l.openTick, l.capTick);
        (int24 reserveLower, int24 reserveUpper) = t1 ? (l.farTick, l.capTick) : (l.capTick, l.farTick);

        (BalanceDelta d1,) = poolManager.modifyLiquidity(
            key,
            IPoolManager.ModifyLiquidityParams({tickLower: curveLower, tickUpper: curveUpper, liquidityDelta: 0, salt: CURVE_SALT}),
            ""
        );
        (BalanceDelta d2,) = poolManager.modifyLiquidity(
            key,
            IPoolManager.ModifyLiquidityParams({tickLower: reserveLower, tickUpper: reserveUpper, liquidityDelta: 0, salt: RESERVE_SALT}),
            ""
        );
        BalanceDelta fees = d1 + d2;

        int128 tokenFee = t1 ? fees.amount1() : fees.amount0();
        int128 quoteFee = t1 ? fees.amount0() : fees.amount1();
        uint256 quoteTotal = quoteFee > 0 ? uint256(uint128(quoteFee)) : 0;

        if (tokenFee > 0) {
            uint256 tokenFeeAmt = uint256(uint128(tokenFee));
            bool zeroForOneSell = !t1;
            BalanceDelta sellDelta = poolManager.swap(
                key,
                IPoolManager.SwapParams({
                    zeroForOne: zeroForOneSell,
                    amountSpecified: -int256(tokenFeeAmt),
                    sqrtPriceLimitX96: zeroForOneSell ? TickMath.MIN_SQRT_PRICE + 1 : TickMath.MAX_SQRT_PRICE - 1
                }),
                ""
            );
            int128 quoteFromSale = t1 ? sellDelta.amount0() : sellDelta.amount1();
            if (quoteFromSale > 0) quoteTotal += uint256(uint128(quoteFromSale));
        }

        if (quoteTotal == 0) return;

        Currency quoteCurrency = t1 ? key.currency0 : key.currency1;
        poolManager.take(quoteCurrency, address(this), quoteTotal);
        _distributeFees(launchId, l, quoteCurrency, quoteTotal);
    }

    function _distributeFees(uint256 launchId, Launch storage l, Currency quoteCurrency, uint256 total) internal {
        uint256 holderCut = total * HOLDER_BPS / BPS_DENOM;
        uint256 buybackCut = total * BUYBACK_BPS / BPS_DENOM;
        uint256 protocolCut = total - holderCut - buybackCut;
        address quoteAddr = Currency.unwrap(quoteCurrency);

        if (quoteAddr == address(0)) {
            ParcelToken(payable(l.token)).notifyRewardAmount{value: holderCut}(holderCut);
            (bool sentBuyback,) = buyback.call{value: buybackCut}("");
            if (!sentBuyback) revert TransferFailed();
            (bool sentProtocol,) = protocolTreasury.call{value: protocolCut}("");
            if (!sentProtocol) revert TransferFailed();
        } else {
            if (!IERC20(quoteAddr).approve(l.token, holderCut)) revert TransferFailed();
            ParcelToken(payable(l.token)).notifyRewardAmount(holderCut);

            // Class coins are fully collateralized 1:1 at their fixed rate,
            // so redeeming is always safe — this is how the buyback cut of
            // a classed market's fees becomes ETH, matching CME's own "the
            // token share is sold for the coin" treatment but for the
            // quote-asset leg instead.
            uint256 ethForBuyback = PropertyClassCoin(quoteAddr).redeem(buybackCut, 0);
            (bool sentBuyback,) = buyback.call{value: ethForBuyback}("");
            if (!sentBuyback) revert TransferFailed();

            if (!IERC20(quoteAddr).transfer(protocolTreasury, protocolCut)) revert TransferFailed();
        }

        emit FeesCollected(launchId, holderCut, buybackCut, protocolCut);
    }

    function _capInQuoteUnits(address quoteAsset_, uint256 capWei) internal view returns (uint256) {
        if (quoteAsset_ == address(0)) return capWei;
        uint256 weiPerUnit = PropertyClassCoin(quoteAsset_).weiPerUnit();
        return capWei * 1 ether / weiPerUnit;
    }

    // Accepts ETH from PropertyClassCoin.redeem() during fee distribution,
    // and from the manager during `take`/refund flows.
    receive() external payable {}
}
