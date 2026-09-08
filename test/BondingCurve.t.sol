// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "forge-std/Test.sol";
import "../contracts/BondingCurve.sol";
import "../contracts/PropertyClassCoin.sol";
import "../contracts/interfaces/IUniswapV4Migrator.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";

/// @dev Records what it was asked to seed instead of creating a real pool,
///      so migration tests can assert on exactly what each pool received.
contract MockMigrator is IUniswapV4Migrator {
    struct Seeded { address token; address quoteAsset; uint256 quoteAmount; uint256 tokenAmount; uint16 feeBps; }
    Seeded[] public seeded;

    function createAndSeedPool(
        address token,
        address quoteAsset,
        uint256 quoteAmount,
        uint256 tokenAmount,
        uint16 feeBps
    ) external payable override {
        IERC20(token).transferFrom(msg.sender, address(this), tokenAmount);
        uint256 heldQuote = msg.value;
        if (quoteAsset != address(0)) {
            IERC20(quoteAsset).transferFrom(msg.sender, address(this), quoteAmount);
            heldQuote = quoteAmount;
        }
        seeded.push(Seeded(token, quoteAsset, heldQuote, tokenAmount, feeBps));
    }

    function seededCount() external view returns (uint256) {
        return seeded.length;
    }
}

contract BondingCurveTest is Test {
    MockMigrator migrator;
    BondingCurve curve;

    address creator = address(0xC12EA70A);
    address trader = address(0x7EADE12);
    address protocolTreasury = address(0x7EA5121);

    function setUp() public {
        migrator = new MockMigrator();

        curve = new BondingCurve(
            "Nana's Storage Shed",
            "NANASHED",
            address(0), // no property class picked
            creator,
            200, // 2% fee
            protocolTreasury,
            address(migrator)
        );

        vm.deal(trader, 1000 ether);
    }

    function test_opensAtExpectedImpliedCap() public view {
        uint256 spotPrice = curve.virtualEthReserve() * 1e18 / curve.virtualTokenReserve();
        uint256 impliedCap = spotPrice * curve.TOTAL_SUPPLY() / 1e18;
        assertApproxEqRel(impliedCap, 2.795 ether, 0.01e18); // within 1%
    }

    function test_buyRequiresNoApprovalOrPriorToken() public {
        vm.prank(trader);
        uint256 tokensOut = curve.buy{value: 1 ether}(0);
        assertGt(tokensOut, 0);
        assertEq(IERC20(address(curve.token())).balanceOf(trader), tokensOut);
    }

    function test_buySplitsFeeCreatorAndProtocolOnly() public {
        vm.startPrank(trader);
        uint256 out1 = curve.buy{value: 0.5 ether}(0);
        uint256 out2 = curve.buy{value: 0.5 ether}(0);
        vm.stopPrank();

        assertGt(out1, out2);
        assertGt(curve.creatorFeesOwed(), 0);
        assertGt(curve.protocolFeesOwed(), 0);

        uint256 grossFee = curve.creatorFeesOwed() + curve.protocolFeesOwed();
        uint256 expectedFee = 1 ether * 200 / 10_000; // 2% of the 1 ETH total sent
        assertApproxEqAbs(grossFee, expectedFee, 2);
    }

    function test_sellReturnsEth() public {
        vm.startPrank(trader);
        uint256 tokensOut = curve.buy{value: 1 ether}(0);
        IERC20(address(curve.token())).approve(address(curve), tokensOut);
        uint256 ethOut = curve.sell(tokensOut, 0);
        vm.stopPrank();

        assertGt(ethOut, 0);
        assertLt(ethOut, 1 ether);
    }

    function test_overshootingBuyCapsAndRefunds() public {
        vm.prank(trader);
        curve.buy{value: 8 ether}(0);
        assertFalse(curve.migrated());

        uint256 remaining = curve.CURVE_SUPPLY() - curve.tokensSold();
        assertGt(remaining, 0);

        uint256 before = trader.balance;
        vm.prank(trader);
        uint256 tokensOut = curve.buy{value: 5 ether}(0);

        assertEq(tokensOut, remaining);
        assertTrue(curve.migrated());
        assertLt(before - trader.balance, 5 ether);
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

    function test_noClassPickedMigratesToSinglePool() public {
        vm.prank(trader);
        curve.buy{value: 20 ether}(0); // way more than needed to sell out

        assertTrue(curve.migrated());
        assertEq(migrator.seededCount(), 1);
        (, address quoteAsset, , uint256 tokenAmount, ) = migrator.seeded(0);
        assertEq(quoteAsset, address(0)); // plain ETH pool
        assertEq(tokenAmount, curve.RESERVE_SUPPLY()); // gets the whole reserved supply
    }
}

contract BondingCurvePeggedTest is Test {
    MockMigrator migrator;
    PropertyClassCoin hous;
    BondingCurve curve;

    address creator = address(0xC12EA70A);
    address trader = address(0x7EADE12);
    address protocolTreasury = address(0x7EA5121);

    function setUp() public {
        migrator = new MockMigrator();
        // $420,000 at an assumed $3,500/ETH == 120 ETH per whole HOUS unit.
        hous = new PropertyClassCoin("Single-family House (Parcel)", "HOUS", 120 ether);

        curve = new BondingCurve(
            "Kappa",
            "KAPPA",
            address(hous), // property class picked
            creator,
            200,
            protocolTreasury,
            address(migrator)
        );

        vm.deal(trader, 1000 ether);
    }

    function test_propertyClassLabelMirrorsCoinTicker() public view {
        assertEq(curve.propertyClass(), "HOUS");
    }

    function test_buyingStillJustTakesEthNoHousInvolved() public {
        // The whole point: buyers never touch the pair coin directly.
        vm.prank(trader);
        uint256 tokensOut = curve.buy{value: 1 ether}(0);
        assertGt(tokensOut, 0);
        assertEq(hous.balanceOf(trader), 0); // never minted to the buyer
    }

    function test_classPickedMigratesToTwoPools() public {
        vm.prank(trader);
        curve.buy{value: 20 ether}(0); // sell out

        assertTrue(curve.migrated());
        assertEq(migrator.seededCount(), 2);

        (, address asset0, , uint256 tokens0, ) = migrator.seeded(0);
        (, address asset1, uint256 quote1, uint256 tokens1, ) = migrator.seeded(1);

        assertEq(asset0, address(0));        // pool 1: plain ETH
        assertEq(asset1, address(hous));     // pool 2: genuinely HOUS-backed
        assertGt(quote1, 0);                 // real HOUS was minted and sent, not zero

        // Reserved supply split (roughly) down the middle across the two pools.
        assertEq(tokens0 + tokens1, curve.RESERVE_SUPPLY());
        assertApproxEqAbs(tokens0, tokens1, 1); // integer-division remainder only
    }
}
