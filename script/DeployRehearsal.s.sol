// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "forge-std/Script.sol";
import {PoolManager} from "@uniswap/v4-core/src/PoolManager.sol";
import {DeployCommon} from "./DeployCommon.sol";

/// @title DeployRehearsal — LOCAL TESTING ONLY, never for a real deploy
/// @notice Unlike DeployMainnet.s.sol (which points at the real, already
///         deployed Uniswap v4 PoolManager on Robinhood Chain mainnet via a
///         forked RPC), this script deploys its OWN fresh PoolManager on a
///         plain, non-forked local anvil instance. It exists solely to
///         escape a recurring instability in the fork-a-live-RPC rehearsal
///         approach: anvil periodically loses the ability to fetch certain
///         account state from the public fork RPC as real-world time
///         passes, causing gas estimation and/or transactions to hang or
///         revert with no clear reason. A plain local chain has no live RPC
///         dependency at all, so that entire failure class can't happen.
///
///         Also deploys a stand-in USDG (a fixed-rate PropertyClassCoin),
///         the same way the testnet script does, since the real USDG
///         contract obviously doesn't exist on a fresh local chain either.
///
///         Writes deployments/mainnet.json (chain id 4663, matching the
///         real mainnet script) rather than testnet.json, purely so a
///         wallet that already has "Robinhood Chain" (4663) configured for
///         this rehearsal doesn't need to be reconfigured again — this
///         does NOT mean the output is a real mainnet deployment.
///
/// Usage:
///   anvil --port 8545 --chain-id 4663   (no --fork-url)
///   PRIVATE_KEY=... PROTOCOL_TREASURY=... forge script script/DeployRehearsal.s.sol \
///     --rpc-url http://127.0.0.1:8545 --broadcast
contract DeployRehearsal is Script, DeployCommon {
    function run() external {
        uint256 firstBuy = vm.envOr("PLATFORM_FIRST_BUY_WEI", uint256(0.05 ether));
        address protocolTreasury = vm.envAddress("PROTOCOL_TREASURY");
        address deployer = vm.addr(vm.envUint("PRIVATE_KEY"));
        address liveTierUpdater = vm.envOr("LIVE_TIER_UPDATER", deployer);

        vm.startBroadcast(vm.envUint("PRIVATE_KEY"));
        PoolManager poolManager = new PoolManager(deployer);
        vm.stopBroadcast();

        Deployed memory d = _deploy(address(poolManager), firstBuy, protocolTreasury, address(0), liveTierUpdater, true);

        string memory classCoins = _tickerMapJson(d.classCoins);
        string memory pegPools = _tickerMapJson(d.pegPools);

        string memory json = string.concat(
            "{",
            '"_LOCAL_REHEARSAL_ONLY":"Fully local rehearsal deploy (own PoolManager, no forked RPC). Never commit this file.",',
            '"chainId":4663,',
            '"chainName":"Robinhood Chain",',
            '"rpcUrl":"http://127.0.0.1:8545",',
            '"explorer":"https://robinhoodchain.blockscout.com",',
            '"ethUsd":3500,',
            '"deployedBlock":',
            vm.toString(d.deployedBlock),
            ",",
            '"deployer":"',
            vm.toString(d.deployer),
            '",',
            '"poolManager":"',
            vm.toString(d.poolManager),
            '",',
            '"feeHook":"',
            vm.toString(d.feeHook),
            '",',
            '"launchpad":"',
            vm.toString(d.launchpad),
            '",',
            '"launchRouter":"',
            vm.toString(d.launchRouter),
            '",',
            '"buyback":"',
            vm.toString(d.buyback),
            '",',
            '"usdg":"',
            vm.toString(d.usdg),
            '",',
            '"platformToken":"',
            vm.toString(d.platformToken),
            '",',
            '"platformLaunchId":',
            vm.toString(d.platformLaunchId),
            ",",
            '"deployedAt":',
            vm.toString(block.timestamp),
            ",",
            '"classCoins":',
            classCoins,
            ",",
            '"pegPools":',
            pegPools,
            "}"
        );
        vm.writeJson(json, "deployments/mainnet.json");

        console2.log("PoolManager:  ", address(poolManager));
        console2.log("Launchpad:    ", d.launchpad);
        console2.log("LaunchRouter: ", d.launchRouter);
        console2.log("Buyback:      ", d.buyback);
        console2.log("PlatformToken:", d.platformToken);
        console2.log("Wrote deployments/mainnet.json (LOCAL REHEARSAL)");
    }
}
