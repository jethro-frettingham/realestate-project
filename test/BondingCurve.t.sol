// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "forge-std/Test.sol";
import "../contracts/BondingCurve.sol";
import "../contracts/PriceOracle.sol";
import "../contracts/interfaces/IUniswapV4Migrator.sol";
import "@openzeppelin/contracts/token/ERC20/ERC20.sol";

/// @dev Minimal ERC20 standing in for the pair coin (e.g. SHED) in tests.
contract MockPairCoin is ERC20 {
    constructor() ERC20("Mock SHED", "SHED") {
        _mint(msg.sender, 1_000_000 ether);
    }
}

/// @dev No-op migrator so curve-sellout tests don't need a real v4 pool.
contract MockMigrator is IUniswapV4Migrator {
    event Seeded(address token, address pairCoin, uint256 pairAmount, uint256 tokenAmount, uint16 feeBps);

    function createAndSeedPool(
        address token,
        address pairCoin,
        uint256 pairAmount,
        uint256 tokenAmount,
        uint16 feeBps
    ) external override {
        ERC20(token).transferFrom(msg.sender, address(this), 0); // pulls nothing; allowance already set
        emit Seeded(token, pairCoin, pairAmount, tokenAmount, feeBps);
    }
}

contract BondingCurveTest is Test {
    PriceOracle oracle;
    MockPairCoin pairCoin;
    MockMigrator migrator;
    BondingCurve curve;

    address creator = address(0xC12EA70A);
    address trader = address(0x7EADE12);
    address treasury = address(0x7EA5121);
    address reporter = address(0x0BE0121);

    function setUp() public {
        oracle = new PriceOracle(address(this));
        oracle.setReporter(reporter, true);
        vm.prank(reporter);
        oracle.report("SHED", 4_200 ether); // $4,200 index price for one SHED unit

        pairCoin = new MockPairCoin();
        migrator = new MockMigrator();

        curve = new BondingCurve(
            "Nana's Storage Shed",
            "NANASHED",
            address(pairCoin),
            "SHED",
            address(oracle),
            creator,
            200, // 2% fee
            treasury,
            address(migrator)
        );

        pairCoin.transfer(trader, 10_000 ether);
    }

    function test_opensNearFiveThousandDollarCap() public view {
        // spot price * total supply, expressed in pair-coin units, should
        // sit close to $5,000 / $4,200-per-SHED at t=0.
        uint256 spotPricePair = curve.virtualPairReserve() * 1e18 / curve.virtualTokenReserve();
        uint256 impliedCapPair = spotPricePair * curve.TOTAL_SUPPLY() / 1e18;
        uint256 expectedCapPair = (uint256(5_000 ether) * 1e18) / uint256(4_200 ether);
        assertApproxEqRel(impliedCapPair, expectedCapPair, 0.01e18); // within 1%
    }

    function test_buyIncreasesPriceAndPaysFee() public {
        vm.startPrank(trader);
        pairCoin.approve(address(curve), 1_000 ether);
        uint256 out1 = curve.buy(500 ether, 0);
        uint256 out2 = curve.buy(500 ether, 0);
        vm.stopPrank();

        // Same pair-coin input later on the curve buys fewer tokens.
        assertGt(out1, out2);
        assertGt(curve.protocolFeesOwed(), 0);
        assertGt(curve.creatorFeesOwed(), 0);
    }

    function test_creatorCanClaimFees() public {
        vm.startPrank(trader);
        pairCoin.approve(address(curve), 1_000 ether);
        curve.buy(1_000 ether, 0);
        vm.stopPrank();

        uint256 owed = curve.creatorFeesOwed();
        assertGt(owed, 0);

        vm.prank(creator);
        curve.claimCreatorFees();
        assertEq(pairCoin.balanceOf(creator), owed);
        assertEq(curve.creatorFeesOwed(), 0);
    }
}
