// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "forge-std/Test.sol";
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
import {PropertyClassCoin} from "../contracts/PropertyClassCoin.sol";
import {ParcelToken} from "../contracts/ParcelToken.sol";
import {PegPool} from "../contracts/PegPool.sol";
import {HookMiner} from "../script/HookMiner.sol";

/// @title Fork tests against the real Robinhood Chain mainnet PoolManager
/// @notice Unlike Launchpad.t.sol / PegPool.t.sol (which deploy a fresh
///         local PoolManager and need no network access), these tests
///         fork real mainnet state and talk to the actual deployed
///         PoolManager at the address DeployMainnet.s.sol hardcodes. This
///         is read-only simulation — forge forks state into a local,
///         throwaway EVM; nothing here is broadcast to the real chain or
///         costs real gas. It exists to catch anything a freshly-deployed
///         local PoolManager wouldn't: a different Uniswap version, owner,
///         or protocol-fee configuration than the vendored v4-core source
///         assumes.
/// @dev Needs network access to https://rpc.mainnet.chain.robinhood.com.
///      Run explicitly: `forge test --match-path test/Fork.t.sol -vv`.
///      Not part of the default `forge test` run's expectations — if the
///      RPC is unreachable, `vm.createSelectFork` itself fails loudly
///      rather than silently skipping.
contract ForkTest is Test {
    using StateLibrary for IPoolManager;
    using PoolIdLibrary for PoolKey;

    // Same address DeployMainnet.s.sol hardcodes — cross-checked against
    // the CME reference page used to scope this migration during planning.
    address constant REAL_POOL_MANAGER = 0x8366a39CC670B4001A1121B8F6A443A643e40951;
    string constant MAINNET_RPC = "https://rpc.mainnet.chain.robinhood.com";

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
        vm.createSelectFork(MAINNET_RPC);
        // Confirms the fork actually landed on Robinhood Chain, not some
        // default/empty state — chain id 4663.
        assertEq(block.chainid, 4663, "fork did not land on Robinhood Chain mainnet");

        openCapWei = 5_000 ether * 1 ether / ETH_USD;
        migrateCapWei = 35_000 ether * 1 ether / ETH_USD;

        poolManager = IPoolManager(REAL_POOL_MANAGER);
        assertGt(address(poolManager).code.length, 0, "no code at the real PoolManager address");

        Buyback bb = new Buyback(poolManager, deployer);
        buyback = bb;

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
    }

    function test_fork_createLaunchAgainstRealPoolManager() public {
        vm.prank(creator);
        (uint256 launchId, address token) =
            launchpad.createLaunch{value: 1 ether}("Nana's Shed", "NANASHED", address(0), 300, "ipfs://x", 0);

        assertGt(IERC20(token).balanceOf(creator), 0);
        assertLt(IERC20(token).balanceOf(address(launchpad)), 1e12);

        Launchpad.Launch memory l = launchpad.getLaunch(launchId);
        assertEq(l.creator, creator);
    }

    /// @notice The same key regression as Launchpad.t.sol, re-verified
    ///         against real mainnet PoolManager bytecode: selling must
    ///         keep working after price crosses the cap tick.
    function test_fork_sellWorksAfterCrossingCapTick() public {
        (uint256 launchId, address token) = _createEthLaunch(1 ether);
        Launchpad.Launch memory l = launchpad.getLaunch(launchId);
        PoolId id = l.poolKey.toId();

        (, int24 tickAtStart,,) = poolManager.getSlot0(id);
        vm.prank(trader);
        uint256 bought = router.buy{value: 50 ether}(launchId, 0);
        (, int24 tickAfterBuy,,) = poolManager.getSlot0(id);
        assertTrue(tickAfterBuy != tickAtStart);
        assertTrue(l.tokenIsCurrency1 ? tickAfterBuy < l.capTick : tickAfterBuy > l.capTick, "did not cross the cap");

        vm.startPrank(trader);
        IERC20(token).approve(address(router), bought);
        uint256 quoteOut = router.sell(launchId, bought / 2, 0);
        vm.stopPrank();
        assertGt(quoteOut, 0);
    }

    function test_fork_feesAndRewardsAgainstRealPoolManager() public {
        (uint256 launchId, address token) = _createEthLaunch(1 ether);
        vm.prank(trader);
        router.buy{value: 5 ether}(launchId, 0);

        launchpad.collectFees(launchId);

        uint256 earned = ParcelToken(payable(token)).earned(creator);
        assertGt(earned, 0);
        vm.prank(creator);
        uint256 claimed = ParcelToken(payable(token)).claimRewards();
        assertEq(claimed, earned);
    }

    /// @notice PegPool's ask/reprice mechanics against the real
    ///         PoolManager, including the zero-liquidity reprice swap.
    function test_fork_pegPoolLifecycle() public {
        PegPool pegPool = new PegPool(poolManager, deployer, "Test House", "THOUS");
        pegPool.initialize(100 ether);

        vm.prank(trader);
        uint256 coinOut = pegPool.buy{value: 1 ether}(0);
        assertGt(coinOut, 0);

        pegPool.harvest();
        assertGt(pegPool.ethReserves(), 0);

        pegPool.reposition(120 ether);
        (, int24 tick,,) = poolManager.getSlot0(pegPool.poolId());
        assertEq(tick, pegPool.feedTick());
    }

    function _createEthLaunch(uint256 firstBuy) internal returns (uint256 launchId, address token) {
        vm.prank(creator);
        (launchId, token) = launchpad.createLaunch{value: firstBuy}("Nana's Shed", "NANASHED", address(0), 300, "ipfs://x", 0);
    }
}
