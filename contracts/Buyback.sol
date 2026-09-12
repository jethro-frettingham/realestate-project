// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {IUnlockCallback} from "@uniswap/v4-core/src/interfaces/callback/IUnlockCallback.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {BalanceDelta, BalanceDeltaLibrary} from "@uniswap/v4-core/src/types/BalanceDelta.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";

/// @title Buyback
/// @notice The $CME-equivalent buyback-and-burn target. Accumulates the
///         30% buyback cut of every market's trading fees as plain ETH
///         (`Launchpad.collectFees` sends it here); anyone can call
///         `executeBuyback()` to swap the accumulated ETH for the platform
///         token through its own Uniswap v4 pool and burn the proceeds.
///         Permissionless on purpose: CME runs this from an off-chain
///         keeper, but there's no reason it has to be — the swap-and-burn
///         needs no judgment call, so anyone can trigger it and there's
///         nothing to trust a keeper wallet with.
/// @dev Reference implementation. Unaudited.
contract Buyback is IUnlockCallback {
    using BalanceDeltaLibrary for BalanceDelta;

    error NotPoolManager();
    error NothingToBuy();
    error NotDeployer();
    error AlreadySet();

    address public constant BURN_ADDRESS = 0x000000000000000000000000000000000000dEaD;

    IPoolManager public immutable poolManager;
    address public immutable deployer;
    PoolKey public platformPoolKey; // ETH/token pool for the platform token
    IERC20 public platformToken;
    bool public platformSet;

    event BuybackExecuted(uint256 ethIn, uint256 tokensBurned);
    event PlatformPoolSet(address token);

    // `platformPoolKey`/`platformToken` can't be constructor args: the
    // platform token is itself launched *through* `Launchpad` (reusing the
    // normal launch mechanism), which doesn't exist until after `Buyback`
    // does — `Launchpad`'s constructor takes `buyback`'s address. This
    // one-time setter, called once by the deploy script right after the
    // platform token's launch transaction, breaks that cycle. It cannot be
    // called again once set, and `deployer` has no other privilege here —
    // it can't touch funds, only wire up this one address pointer.
    constructor(IPoolManager poolManager_, address deployer_) {
        poolManager = poolManager_;
        deployer = deployer_;
    }

    /// @dev `platformPoolKey_` must be an ETH pool (currency0 == address(0))
    ///      — address(0) always sorts below any real token address, so
    ///      every ETH-paired v4 pool has ETH as currency0 by construction.
    function setPlatformPool(PoolKey calldata platformPoolKey_, address platformToken_) external {
        if (msg.sender != deployer) revert NotDeployer();
        if (platformSet) revert AlreadySet();
        require(Currency.unwrap(platformPoolKey_.currency0) == address(0), "Buyback: not an ETH pool");
        require(Currency.unwrap(platformPoolKey_.currency1) == platformToken_, "Buyback: token mismatch");
        platformPoolKey = platformPoolKey_;
        platformToken = IERC20(platformToken_);
        platformSet = true;
        emit PlatformPoolSet(platformToken_);
    }

    receive() external payable {}

    /// @notice Swaps every ETH balance this contract holds for the
    ///         platform token and burns it. Callable by anyone, anytime.
    function executeBuyback() external returns (uint256 ethIn, uint256 tokensBurned) {
        if (!platformSet) revert NothingToBuy();
        ethIn = address(this).balance;
        if (ethIn == 0) revert NothingToBuy();
        bytes memory result = poolManager.unlock(abi.encode(ethIn));
        tokensBurned = abi.decode(result, (uint256));
        emit BuybackExecuted(ethIn, tokensBurned);
    }

    function unlockCallback(bytes calldata data) external returns (bytes memory) {
        if (msg.sender != address(poolManager)) revert NotPoolManager();
        uint256 ethIn = abi.decode(data, (uint256));

        // ETH is always currency0 in a token/ETH pool (address(0) sorts
        // below any real token address), so this is always a zeroForOne
        // exact-input swap: ETH in, platform token out.
        IPoolManager.SwapParams memory params = IPoolManager.SwapParams({
            zeroForOne: true,
            amountSpecified: -int256(ethIn),
            sqrtPriceLimitX96: TickMath.MIN_SQRT_PRICE + 1
        });

        BalanceDelta delta = poolManager.swap(platformPoolKey, params, "");

        // amount0 is negative (we paid ETH in), amount1 is positive (token out).
        int128 amount0 = delta.amount0();
        int128 amount1 = delta.amount1();
        uint256 tokensOut = uint256(uint128(amount1));

        // Native currency settlement needs no `sync` first (see PoolManager.sync's docs).
        poolManager.settle{value: uint256(uint128(-amount0))}();
        poolManager.take(platformPoolKey.currency1, address(this), tokensOut);

        IERC20(Currency.unwrap(platformPoolKey.currency1)).transfer(BURN_ADDRESS, tokensOut);

        return abi.encode(tokensOut);
    }
}
