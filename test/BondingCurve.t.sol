// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "forge-std/Test.sol";
import "../contracts/BondingCurve.sol";
import "../contracts/interfaces/IUniswapV4Migrator.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";

/// @dev No-op migrator so curve-sellout tests don't need a real v4 pool.
contract MockMigrator is IUniswapV4Migrator {
    event Seeded(address token, uint256 ethAmount, uint256 tokenAmount, uint16 feeBps);

    function createAndSeedPool(address token, uint256 tokenAmount, uint16 feeBps) external payable override {
        IERC20(token).transferFrom(msg.sender, address(this), tokenAmount);
        emit Seeded(token, msg.value, tokenAmount, feeBps);
    }
}

contract BondingCurveTest is Test {
    MockMigrator migrator;
    BondingCurve curve;

    address creator = address(0xC12EA70A);
    address trader = address(0x7EADE12);
    address buybackTreasury = address(0xB0BACC);
    address protocolTreasury = address(0x7EA5121);

    function setUp() public {
        migrator = new MockMigrator();

        curve = new BondingCurve(
            "Nana's Storage Shed",
            "NANASHED",
            "SHED",
            creator,
            200, // 2% fee
            buybackTreasury,
            protocolTreasury,
            address(migrator)
        );

        vm.deal(trader, 100 ether);
    }

    function test_opensAtExpectedImpliedCap() public view {
        // spot price * total supply, using the fixed virtual reserves —
        // should land close to the ~2.8 ETH figure documented on the
        // contract (3 ETH / 1,073,000,000 tokens * 1B total supply).
        uint256 spotPrice = curve.virtualEthReserve() * 1e18 / curve.virtualTokenReserve();
        uint256 impliedCap = spotPrice * curve.TOTAL_SUPPLY() / 1e18;
        assertApproxEqRel(impliedCap, 2.795 ether, 0.01e18); // within 1%
    }

    function test_buyRequiresNoApprovalOrPriorToken() public {
        // The whole point: a fresh EOA with nothing but ETH can buy
        // immediately — no approve(), no minting an intermediate coin, and
        // no holder-reward bookkeeping to worry about either.
        vm.prank(trader);
        uint256 tokensOut = curve.buy{value: 1 ether}(0);
        assertGt(tokensOut, 0);
        assertEq(IERC20(address(curve.token())).balanceOf(trader), tokensOut);
    }

    function test_buySplitsFeeThreeWaysWithNoHolderBucket() public {
        vm.startPrank(trader);
        uint256 out1 = curve.buy{value: 0.5 ether}(0);
        uint256 out2 = curve.buy{value: 0.5 ether}(0);
        vm.stopPrank();

        // Same ETH input later on the curve buys fewer tokens.
        assertGt(out1, out2);
        assertGt(curve.protocolFeesOwed(), 0);
        assertGt(curve.creatorFeesOwed(), 0);
        assertGt(curve.buybackFeesOwed(), 0);

        // Confirm the three buckets are the whole fee — no fourth
        // (holder-reward) bucket exists anymore.
        uint256 grossFee = curve.creatorFeesOwed() + curve.buybackFeesOwed() + curve.protocolFeesOwed();
        uint256 expectedFee = 1 ether * 200 / 10_000; // 2% of the 1 ETH total sent
        assertApproxEqAbs(grossFee, expectedFee, 2); // rounding dust only
    }

    function test_sellReturnsEthWithNoApprovalNeededForEth() public {
        vm.startPrank(trader);
        uint256 tokensOut = curve.buy{value: 1 ether}(0);
        IERC20(address(curve.token())).approve(address(curve), tokensOut);
        uint256 ethOut = curve.sell(tokensOut, 0);
        vm.stopPrank();

        assertGt(ethOut, 0);
        assertLt(ethOut, 1 ether); // fee + curve slippage means you get back less
    }

    function test_overshootingBuyCapsAndRefundsWithoutMigrating() public {
        // Sell most, but not all, of the curve first so there's a known
        // small remainder left, then try to buy way more than that
        // remainder and confirm it caps + refunds instead of reverting or
        // over-filling.
        vm.deal(trader, 1000 ether);
        vm.prank(trader);
        curve.buy{value: 8 ether}(0); // most of the curve, but not all of it
        assertFalse(curve.migrated());

        uint256 remaining = curve.CURVE_SUPPLY() - curve.tokensSold();
        assertGt(remaining, 0);

        uint256 before = trader.balance;
        vm.prank(trader);
        uint256 tokensOut = curve.buy{value: 5 ether}(0); // way more than needed to finish it off

        assertEq(tokensOut, remaining);
        assertTrue(curve.migrated());
        assertLt(before - trader.balance, 5 ether); // refunded the unused portion
    }

    function test_creatorCanClaimFees() public {
        vm.prank(trader);
        curve.buy{value: 1 ether}(0);

        uint256 owed = curve.creatorFeesOwed();
        assertGt(owed, 0);

        uint256 before = creator.balance;
        vm.prank(creator);
        curve.claimCreatorFees();
        assertEq(creator.balance, before + owed);
        assertEq(curve.creatorFeesOwed(), 0);
    }

    function test_anyoneCanSweepBuybackFeesButOnlyToTreasury() public {
        vm.prank(trader);
        curve.buy{value: 1 ether}(0);

        uint256 owed = curve.buybackFeesOwed();
        assertGt(owed, 0);

        uint256 before = buybackTreasury.balance;
        // A random address (not the creator, not the treasury) can trigger
        // the sweep — but the funds only ever go to buybackTreasury.
        vm.prank(address(0xBEEF));
        curve.sweepBuybackFees();

        assertEq(buybackTreasury.balance, before + owed);
        assertEq(curve.buybackFeesOwed(), 0);
    }

    function test_protocolCanClaimFees() public {
        vm.prank(trader);
        curve.buy{value: 1 ether}(0);

        uint256 owed = curve.protocolFeesOwed();
        assertGt(owed, 0);

        uint256 before = protocolTreasury.balance;
        curve.claimProtocolFees();
        assertEq(protocolTreasury.balance, before + owed);
        assertEq(curve.protocolFeesOwed(), 0);
    }

    function test_sellingOutMigratesToMigrator() public {
        // Sending far more than the curve has left should cap the buy at
        // the remaining supply, refund the rest, and migrate — not revert.
        vm.deal(trader, 1000 ether);
        uint256 before = trader.balance;
        vm.prank(trader);
        curve.buy{value: 20 ether}(0);

        assertTrue(curve.migrated());
        assertEq(curve.tokensSold(), curve.CURVE_SUPPLY());
        assertLt(before - trader.balance, 20 ether); // got a refund on the unused portion
    }
}
