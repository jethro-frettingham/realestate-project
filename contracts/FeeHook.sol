// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {BalanceDelta} from "@uniswap/v4-core/src/types/BalanceDelta.sol";
import {BeforeSwapDelta, BeforeSwapDeltaLibrary} from "@uniswap/v4-core/src/types/BeforeSwapDelta.sol";
import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";

/// @title FeeHook
/// @notice Mirrors CME's own description of its V6 fee hook: "stamps each
///         new pool with the creator's fee, nothing else." Every market
///         pool is created with a dynamic-fee flag; this hook sets the
///         one-time initial fee in `afterInitialize` (the pattern
///         `LPFeeLibrary` itself documents for a non-zero initial dynamic
///         fee) and never touches it again — there's no other hook logic.
/// @dev Only `afterInitialize` is enabled — enforced both by the mined
///      CREATE2 address (only the AFTER_INITIALIZE_FLAG bit set) and by
///      the constructor-time `Hooks.validateHookPermissions` self-check,
///      so a bad salt fails to deploy instead of silently deploying a
///      hook v4 will never call.
contract FeeHook is IHooks {
    using PoolIdLibrary for PoolKey;

    error NotLaunchpad();
    error NotPoolManager();

    IPoolManager public immutable poolManager;
    address public immutable launchpad;

    // Set by `launchpad` immediately before it calls `poolManager.initialize`
    // for that same pool, inside the same transaction — no other address
    // can front-run this slot for a given poolId because only `launchpad`
    // can write it and it does so atomically with the initialize call.
    mapping(PoolId => uint24) public pendingFeeHundredthsOfBip;

    constructor(IPoolManager poolManager_, address launchpad_) {
        poolManager = poolManager_;
        launchpad = launchpad_;
        Hooks.validateHookPermissions(
            IHooks(address(this)),
            Hooks.Permissions({
                beforeInitialize: false,
                afterInitialize: true,
                beforeAddLiquidity: false,
                afterAddLiquidity: false,
                beforeRemoveLiquidity: false,
                afterRemoveLiquidity: false,
                beforeSwap: false,
                afterSwap: false,
                beforeDonate: false,
                afterDonate: false,
                beforeSwapReturnDelta: false,
                afterSwapReturnDelta: false,
                afterAddLiquidityReturnDelta: false,
                afterRemoveLiquidityReturnDelta: false
            })
        );
    }

    /// @notice Called by `launchpad` right before `poolManager.initialize`
    ///         for the same pool, in the same transaction.
    function setPendingFee(PoolId id, uint24 feeHundredthsOfBip) external {
        if (msg.sender != launchpad) revert NotLaunchpad();
        pendingFeeHundredthsOfBip[id] = feeHundredthsOfBip;
    }

    function afterInitialize(address, PoolKey calldata key, uint160, int24) external override returns (bytes4) {
        if (msg.sender != address(poolManager)) revert NotPoolManager();
        PoolId id = key.toId();
        uint24 fee = pendingFeeHundredthsOfBip[id];
        delete pendingFeeHundredthsOfBip[id];
        if (fee > 0) {
            poolManager.updateDynamicLPFee(key, fee);
        }
        return IHooks.afterInitialize.selector;
    }

    // ---- Everything below is a required-but-unused IHooks implementation.
    //      None of these can ever be called: the deployed address only has
    //      the AFTER_INITIALIZE_FLAG bit set, so v4 never invokes them.

    function beforeInitialize(address, PoolKey calldata, uint160) external pure override returns (bytes4) {
        return IHooks.beforeInitialize.selector;
    }

    function beforeAddLiquidity(address, PoolKey calldata, IPoolManager.ModifyLiquidityParams calldata, bytes calldata)
        external
        pure
        override
        returns (bytes4)
    {
        return IHooks.beforeAddLiquidity.selector;
    }

    function afterAddLiquidity(
        address,
        PoolKey calldata,
        IPoolManager.ModifyLiquidityParams calldata,
        BalanceDelta,
        BalanceDelta,
        bytes calldata
    ) external pure override returns (bytes4, BalanceDelta) {
        return (IHooks.afterAddLiquidity.selector, BalanceDelta.wrap(0));
    }

    function beforeRemoveLiquidity(
        address,
        PoolKey calldata,
        IPoolManager.ModifyLiquidityParams calldata,
        bytes calldata
    ) external pure override returns (bytes4) {
        return IHooks.beforeRemoveLiquidity.selector;
    }

    function afterRemoveLiquidity(
        address,
        PoolKey calldata,
        IPoolManager.ModifyLiquidityParams calldata,
        BalanceDelta,
        BalanceDelta,
        bytes calldata
    ) external pure override returns (bytes4, BalanceDelta) {
        return (IHooks.afterRemoveLiquidity.selector, BalanceDelta.wrap(0));
    }

    function beforeSwap(address, PoolKey calldata, IPoolManager.SwapParams calldata, bytes calldata)
        external
        pure
        override
        returns (bytes4, BeforeSwapDelta, uint24)
    {
        return (IHooks.beforeSwap.selector, BeforeSwapDeltaLibrary.ZERO_DELTA, 0);
    }

    function afterSwap(address, PoolKey calldata, IPoolManager.SwapParams calldata, BalanceDelta, bytes calldata)
        external
        pure
        override
        returns (bytes4, int128)
    {
        return (IHooks.afterSwap.selector, 0);
    }

    function beforeDonate(address, PoolKey calldata, uint256, uint256, bytes calldata)
        external
        pure
        override
        returns (bytes4)
    {
        return IHooks.beforeDonate.selector;
    }

    function afterDonate(address, PoolKey calldata, uint256, uint256, bytes calldata)
        external
        pure
        override
        returns (bytes4)
    {
        return IHooks.afterDonate.selector;
    }
}
