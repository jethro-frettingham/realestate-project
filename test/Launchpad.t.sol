// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "forge-std/Test.sol";
import {PoolManager} from "@uniswap/v4-core/src/PoolManager.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";
import {StateLibrary} from "@uniswap/v4-core/src/libraries/StateLibrary.sol";
import {PoolId, PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import {FeeHook} from "../contracts/FeeHook.sol";
import {Launchpad} from "../contracts/Launchpad.sol";
import {LaunchRouter} from "../contracts/LaunchRouter.sol";
import {Buyback} from "../contracts/Buyback.sol";
import {ParcelToken} from "../contracts/ParcelToken.sol";
import {PropertyClassCoin} from "../contracts/PropertyClassCoin.sol";
import {PegPool} from "../contracts/PegPool.sol";
import {HookMiner} from "../script/HookMiner.sol";

/// @dev Deploys a REAL v4-core PoolManager (not a mock) so these tests
///      exercise actual Uniswap v4 settlement, liquidity, and swap
///      mechanics end to end — no network access needed since v4-core is
///      fully open source and runs the same locally as on any real chain.
contract LaunchpadTest is Test {
    using StateLibrary for IPoolManager;
    using PoolIdLibrary for PoolKey;

    IPoolManager poolManager;
    FeeHook feeHook;
    Launchpad launchpad;
    LaunchRouter router;
    Buyback buyback;

    address deployer = address(this);
    address protocolTreasury = makeAddr("protocolTreasury");
    address trader = makeAddr("trader");
    address creator = makeAddr("creator");

    uint256 constant ETH_USD = 3_500 ether;
    uint256 openCapWei;
    uint256 migrateCapWei;

    function setUp() public {
        openCapWei = 5_000 ether * 1 ether / ETH_USD;
        migrateCapWei = 35_000 ether * 1 ether / ETH_USD;

        poolManager = IPoolManager(address(new PoolManager(address(this))));

        Buyback bb = new Buyback(poolManager, deployer);
        buyback = bb;

        // +1: FeeHook itself consumes the next nonce slot (CREATE2 still
        // increments a contract account's nonce), so Launchpad lands one
        // slot after the nonce we read here.
        address predictedLaunchpad = vm.computeCreateAddress(deployer, vm.getNonce(deployer) + 1);
        (, bytes32 salt) = HookMiner.find(
            deployer, Hooks.AFTER_INITIALIZE_FLAG, type(FeeHook).creationCode, abi.encode(poolManager, predictedLaunchpad)
        );
        feeHook = new FeeHook{salt: salt}(poolManager, predictedLaunchpad);

        launchpad = new Launchpad(poolManager, feeHook, address(buyback), protocolTreasury, openCapWei, migrateCapWei);
        require(address(launchpad) == predictedLaunchpad, "setup: address mismatch");

        router = new LaunchRouter(poolManager, launchpad);

        vm.deal(trader, 1_000 ether);
        vm.deal(creator, 1_000 ether);
        vm.deal(deployer, 1_000 ether);
    }

    function _createEthLaunch(uint256 firstBuy) internal returns (uint256 launchId, address token) {
        vm.prank(creator);
        (launchId, token) = launchpad.createLaunch{value: firstBuy}("Nana's Shed", "NANASHED", address(0), 300, "ipfs://x", 0);
    }

    function test_createLaunch_seedsPoolAndPaysFirstBuyer() public {
        (uint256 launchId, address token) = _createEthLaunch(1 ether);

        // Effectively the full supply left the token contract (deposited
        // into the pool as liquidity) — only integer-rounding dust from the
        // amount-to-liquidity conversion can remain, vanishingly small next
        // to an 18-decimal, billion-token supply.
        assertLt(IERC20(token).balanceOf(address(launchpad)), 1e12);
        assertGt(IERC20(token).balanceOf(creator), 0);

        Launchpad.Launch memory l = launchpad.getLaunch(launchId);
        assertEq(l.creator, creator);
        assertEq(l.quoteAsset, address(0));
    }

    /// @notice The key regression: selling must keep working after the
    ///         price has moved past the cap tick into the reserve range —
    ///         there is no migration cliff, unlike the old virtual curve.
    function test_sellWorksAfterCrossingCapTick() public {
        (uint256 launchId, address token) = _createEthLaunch(1 ether);

        Launchpad.Launch memory l = launchpad.getLaunch(launchId);
        PoolId id = _poolId(l);
        (, int24 tickAtStart,,) = poolManager.getSlot0(id);

        // Buy enough to push price well past the cap tick into the reserve range.
        vm.prank(trader);
        uint256 bought = router.buy{value: 50 ether}(launchId, 0);
        assertGt(bought, 0);

        (, int24 tickAfterBuy,,) = poolManager.getSlot0(id);
        assertTrue(_pastCap(l, tickAfterBuy), "price did not cross the cap tick");
        assertTrue(tickAfterBuy != tickAtStart);

        // Selling must still succeed here — this would have reverted with
        // `BondingCurve: migrated` under the old design.
        vm.startPrank(trader);
        IERC20(token).approve(address(router), bought);
        uint256 quoteOut = router.sell(launchId, bought / 2, 0);
        vm.stopPrank();

        assertGt(quoteOut, 0);
    }

    function test_collectFeesPaysHoldersBuybackAndProtocol() public {
        (uint256 launchId, address token) = _createEthLaunch(1 ether);

        vm.prank(trader);
        router.buy{value: 5 ether}(launchId, 0);

        uint256 protocolBefore = protocolTreasury.balance;
        uint256 buybackBefore = address(buyback).balance;

        launchpad.collectFees(launchId);

        assertGt(protocolTreasury.balance, protocolBefore, "protocol got nothing");
        assertGt(address(buyback).balance, buybackBefore, "buyback got nothing");

        uint256 earned = ParcelToken(payable(token)).earned(creator);
        assertGt(earned, 0, "creator (a holder) accrued no reward");

        uint256 before = creator.balance;
        vm.prank(creator);
        uint256 claimed = ParcelToken(payable(token)).claimRewards();
        assertEq(claimed, earned);
        assertEq(creator.balance, before + claimed);
    }

    function test_buybackSwapsAndBurnsPlatformToken() public {
        // Bootstrap a platform-token launch, same as the deploy script does.
        vm.prank(deployer);
        (, address platformToken) = launchpad.createLaunch{value: 2 ether}("Parcel", "PARCEL", address(0), 300, "", 0);
        Launchpad.Launch memory pl = launchpad.getLaunch(0);
        buyback.setPlatformPool(pl.poolKey, platformToken);

        // Fund Buyback the way collectFees would.
        (uint256 launchId,) = _createEthLaunch(1 ether);
        vm.prank(trader);
        router.buy{value: 5 ether}(launchId, 0);
        launchpad.collectFees(launchId);

        uint256 ethHeld = address(buyback).balance;
        assertGt(ethHeld, 0);

        (uint256 ethIn, uint256 burned) = buyback.executeBuyback();
        assertEq(ethIn, ethHeld);
        assertGt(burned, 0);
        assertEq(IERC20(platformToken).balanceOf(buyback.BURN_ADDRESS()), burned);
    }

    function test_classedLaunch_tradesAgainstClassCoin() public {
        // 1 HOUS costs 100 ETH at this rate — arbitrary for the test.
        PropertyClassCoin hous = new PropertyClassCoin("House", "HOUS", 100 ether);

        vm.prank(creator);
        (uint256 launchId, address token) =
            launchpad.createLaunch{value: 10 ether}("Nana's House", "NANAHOUS", address(hous), 200, "ipfs://x", 0);

        Launchpad.Launch memory l = launchpad.getLaunch(launchId);
        assertEq(l.quoteAsset, address(hous));
        assertEq(l.propertyClass, "HOUS");
        assertGt(IERC20(token).balanceOf(creator), 0);

        // Buy and sell should both work entirely in ETH from the trader's
        // side — the class coin is minted/burned under the hood.
        vm.prank(trader);
        uint256 bought = router.buy{value: 5 ether}(launchId, 0);
        assertGt(bought, 0);

        uint256 traderEthBefore = trader.balance;
        vm.startPrank(trader);
        IERC20(token).approve(address(router), bought);
        uint256 houscOut = router.sell(launchId, bought, 0);
        vm.stopPrank();

        assertGt(houscOut, 0);
        // Seller receives the class coin itself, not ETH — matches CME's
        // "sellers can hold or redeem it themselves" behavior.
        assertEq(trader.balance, traderEthBefore);
        assertEq(IERC20(address(hous)).balanceOf(trader), houscOut);
    }

    /// @notice The live-tier equivalent of test_classedLaunch_tradesAgainstClassCoin:
    ///         picking a PegPool-backed coin (House) as the quote asset
    ///         instead of a fixed-rate PropertyClassCoin. Buying routes the
    ///         trader's ETH through PegPool.buy() (a real swap against its
    ///         single-sided ask, not a 1:1 mint) before swapping into the
    ///         launch's own pool; selling is unchanged — the trader still
    ///         just receives the class coin directly.
    function test_liveTierLaunch_tradesAgainstPegPoolCoin() public {
        PegPool pegPool = new PegPool(poolManager, deployer, "House", "HOUS");
        pegPool.initialize(100 ether); // 1 HOUS costs 100 ETH — arbitrary for the test
        address hous = address(pegPool.coin());

        vm.prank(creator);
        (uint256 launchId, address token) =
            launchpad.createLaunch{value: 10 ether}("Nana's House", "NANAHOUS", hous, 200, "ipfs://x", 0);

        Launchpad.Launch memory l = launchpad.getLaunch(launchId);
        assertEq(l.quoteAsset, hous);
        assertEq(l.propertyClass, "HOUS");
        assertGt(IERC20(token).balanceOf(creator), 0);

        vm.prank(trader);
        uint256 bought = router.buy{value: 5 ether}(launchId, 0);
        assertGt(bought, 0);

        uint256 traderEthBefore = trader.balance;
        vm.startPrank(trader);
        IERC20(token).approve(address(router), bought);
        uint256 housOut = router.sell(launchId, bought, 0);
        vm.stopPrank();

        assertGt(housOut, 0);
        assertEq(trader.balance, traderEthBefore);
        assertEq(IERC20(hous).balanceOf(trader), housOut);

        // collectFees() must also work through the live-tier path: harvest()
        // then sell() to turn the buyback cut into ETH, same as a static
        // coin's redeem() but against PegPool's variable-rate ask instead.
        launchpad.collectFees(launchId);
    }

    function _poolId(Launchpad.Launch memory l) internal pure returns (PoolId) {
        return l.poolKey.toId();
    }

    function _pastCap(Launchpad.Launch memory l, int24 currentTick) internal pure returns (bool) {
        return l.tokenIsCurrency1 ? currentTick < l.capTick : currentTick > l.capTick;
    }
}
