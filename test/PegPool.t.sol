// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "forge-std/Test.sol";
import {PoolManager} from "@uniswap/v4-core/src/PoolManager.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {StateLibrary} from "@uniswap/v4-core/src/libraries/StateLibrary.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {SqrtPriceMath} from "@uniswap/v4-core/src/libraries/SqrtPriceMath.sol";
import {PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import {PegPool} from "../contracts/PegPool.sol";

/// @dev Same approach as Launchpad.t.sol: a real, locally-deployed
///      PoolManager, not a mock, so the zero-liquidity reprice trick
///      `PegPool._reposition` relies on is actually exercised, not just
///      asserted from reading the swap math.
contract PegPoolTest is Test {
    using StateLibrary for IPoolManager;
    using PoolIdLibrary for PoolKey;

    IPoolManager poolManager;
    PegPool pegPool;
    address updater = makeAddr("updater");
    address buyer = makeAddr("buyer");

    uint256 constant INITIAL_RATE = 100 ether; // 1 THOUS = 100 ETH

    function setUp() public {
        poolManager = IPoolManager(address(new PoolManager(address(this))));
        pegPool = new PegPool(poolManager, updater, "Test House", "THOUS");

        vm.prank(updater);
        pegPool.initialize(INITIAL_RATE);

        vm.deal(buyer, 1_000 ether);
    }

    function test_initialize_seedsAskAndSetsFeedTick() public {
        assertTrue(pegPool.initialized());
        assertEq(pegPool.weiPerUnit(), INITIAL_RATE);

        (, int24 tick,,) = poolManager.getSlot0(pegPool.poolId());
        assertEq(tick, pegPool.feedTick());

        IERC20 coin = IERC20(address(pegPool.coin()));
        // Nearly all of ASK_TARGET_SIZE went into the pool as liquidity;
        // only integer-rounding dust stays in the contract's own balance.
        assertLt(coin.balanceOf(address(pegPool)), 1e12);
    }

    function test_buy_getsCoinAtApproximatelyTheReferenceRate() public {
        vm.prank(buyer);
        uint256 coinOut = pegPool.buy{value: 1 ether}(0);

        assertGt(coinOut, 0);
        assertEq(IERC20(address(pegPool.coin())).balanceOf(buyer), coinOut);
        // ~1/100 of a coin for 1 ETH at a 100 ETH/coin rate, within a few
        // percent (the ask has a small tick range, so there's some slippage).
        assertApproxEqRel(coinOut, 0.01 ether, 0.05e18);
        // Not in ethReserves yet — it's sitting inside the ask's own v4
        // liquidity until someone calls harvest().
        assertEq(pegPool.ethReserves(), 0);
        pegPool.harvest();
        assertApproxEqRel(pegPool.ethReserves(), 1 ether, 0.01e18);
    }

    function test_buy_pastAskInventoryRefundsLeftoverEth() public {
        // Compute the ask's exact ETH capacity from its real liquidity
        // (a concentrated position's capacity isn't simply size × price —
        // it depends on the exact tick range too), then buy well past it.
        (uint128 liquidity,,) = poolManager.getPositionInfo(
            pegPool.poolId(), address(pegPool), pegPool.askLowerTick(), pegPool.feedTick(), bytes32(0)
        );
        uint256 maxEthIn = SqrtPriceMath.getAmount0Delta(
            TickMath.getSqrtPriceAtTick(pegPool.askLowerTick()), TickMath.getSqrtPriceAtTick(pegPool.feedTick()), liquidity, true
        );
        uint256 buyAmount = maxEthIn * 2;

        vm.deal(buyer, buyAmount + 1 ether);
        uint256 before = buyer.balance;
        vm.prank(buyer);
        uint256 coinOut = pegPool.buy{value: buyAmount}(0);

        assertGt(coinOut, 0);
        uint256 spent = before - buyer.balance;
        assertLt(spent, buyAmount, "no refund happened");
        assertApproxEqRel(spent, maxEthIn, 0.01e18, "should have spent ~exactly the ask's capacity");
    }

    function test_sell_paysFromHarvestedReserves() public {
        vm.prank(buyer);
        uint256 coinOut = pegPool.buy{value: 2 ether}(0);
        pegPool.harvest();
        uint256 reservesBefore = pegPool.ethReserves();
        assertApproxEqRel(reservesBefore, 2 ether, 0.01e18);

        // Sell back only part of it — comfortably within reserves.
        uint256 sellAmount = coinOut / 4;
        vm.startPrank(buyer);
        uint256 before = buyer.balance;
        uint256 ethOut = pegPool.sell(sellAmount, 0);
        vm.stopPrank();

        assertEq(ethOut, sellAmount * INITIAL_RATE / 1 ether);
        assertEq(buyer.balance, before + ethOut);
        assertEq(pegPool.ethReserves(), reservesBefore - ethOut);
    }

    /// @notice The core solvency invariant: a buy's ETH sits inside the
    ///         ask position, not this contract's own reserves, until
    ///         someone harvests it — so selling against un-harvested ETH
    ///         must revert rather than pay out from thin air.
    function test_sell_revertsBeforeAnyHarvest() public {
        vm.prank(buyer);
        uint256 coinOut = pegPool.buy{value: 2 ether}(0);
        assertEq(pegPool.ethReserves(), 0);

        vm.prank(buyer);
        vm.expectRevert(PegPool.InsufficientReserves.selector);
        pegPool.sell(coinOut, 0);
    }

    function test_reposition_movesFeedTickAndStaysTradeable() public {
        vm.prank(buyer);
        pegPool.buy{value: 1 ether}(0);

        vm.prank(updater);
        pegPool.reposition(150 ether); // the class got more expensive

        assertEq(pegPool.weiPerUnit(), 150 ether);
        (, int24 tick,,) = poolManager.getSlot0(pegPool.poolId());
        assertEq(tick, pegPool.feedTick());

        // Still tradeable at the new rate, both directions.
        vm.prank(buyer);
        uint256 coinOut = pegPool.buy{value: 1 ether}(0);
        assertGt(coinOut, 0);
        pegPool.harvest(); // pull this buy's ETH into ethReserves so the sell below can draw on it

        vm.startPrank(buyer);
        IERC20(address(pegPool.coin())).approve(address(pegPool), coinOut);
        uint256 ethOut = pegPool.sell(coinOut, 0);
        vm.stopPrank();
        assertApproxEqRel(ethOut, coinOut * 150 ether / 1 ether, 0.001e18);
    }

    function test_onlyUpdaterCanInitializeOrReposition() public {
        PegPool fresh = new PegPool(poolManager, updater, "Test Farm", "TFARM");
        vm.expectRevert(PegPool.NotUpdater.selector);
        fresh.initialize(1 ether);

        vm.expectRevert(PegPool.NotUpdater.selector);
        pegPool.reposition(1 ether);
    }
}
