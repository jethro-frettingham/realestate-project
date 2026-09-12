// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "forge-std/Script.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {Buyback} from "../contracts/Buyback.sol";

/// @title SetPlatformPool — one-time follow-up after $CASTLE launches on Pons
/// @notice DeployMainnet.s.sol deploys Buyback without a platform token
///         (`bootstrapPlatformToken = false`, see its own doc comment):
///         $CASTLE launches externally on Pons rather than through this
///         Launchpad, and Pons's own bonding curve isn't a real Uniswap v4
///         pool — there's nothing to point Buyback at until $CASTLE
///         actually graduates on Pons to its real, permanently-locked v4
///         pool. Run this exactly once after that graduation happens.
///
///         `Buyback.setPlatformPool()` can only be called once
///         (`AlreadySet` reverts on a second attempt) and only by the
///         address that deployed Buyback (`deployer`, immutable) — this
///         must be broadcast from that same PRIVATE_KEY.
///
/// Where to get the four pool values below: read them off Pons's own
/// launch/graduation transaction or contract for $CASTLE (block explorer,
/// or Pons's API/docs) — this script only wires Buyback to a pool that
/// already exists, it does not create one.
///
/// Usage:
///   BUYBACK=0x... PLATFORM_TOKEN=0x... POOL_FEE=... POOL_TICK_SPACING=... \
///   POOL_HOOKS=0x... PRIVATE_KEY=0x... \
///   forge script script/SetPlatformPool.s.sol --rpc-url robinhood_mainnet --broadcast
contract SetPlatformPool is Script {
    function run() external {
        address buybackAddr = vm.envAddress("BUYBACK");
        address platformToken = vm.envAddress("PLATFORM_TOKEN");
        uint24 fee = uint24(vm.envUint("POOL_FEE"));
        int24 tickSpacing = int24(vm.envInt("POOL_TICK_SPACING"));
        address hooks = vm.envOr("POOL_HOOKS", address(0));

        PoolKey memory key = PoolKey({
            currency0: Currency.wrap(address(0)), // ETH always sorts first
            currency1: Currency.wrap(platformToken),
            fee: fee,
            tickSpacing: tickSpacing,
            hooks: IHooks(hooks)
        });

        vm.startBroadcast(vm.envUint("PRIVATE_KEY"));
        Buyback(payable(buybackAddr)).setPlatformPool(key, platformToken);
        vm.stopBroadcast();

        console2.log("Buyback platform pool set.");
        console2.log("Buyback:      ", buybackAddr);
        console2.log("PlatformToken:", platformToken);
    }
}
