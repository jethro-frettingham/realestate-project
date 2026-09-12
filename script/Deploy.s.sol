// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "forge-std/Script.sol";
import {DeployCommon} from "./DeployCommon.sol";

/// @title Deploy (Robinhood Chain Testnet)
/// @notice Deploys the full V6-shaped Parcel stack: FeeHook, Launchpad,
///         LaunchRouter, Buyback, the platform token (bootstrapped as its
///         own launch), USDG stand-in, and all 20 property-class coins.
///         Writes every address to deployments/testnet.json.
///
/// Usage (from the repo root, after `forge install` and `cp .env.example
/// .env` with PRIVATE_KEY filled in):
///
///   POOL_MANAGER=0x... forge script script/Deploy.s.sol \
///     --rpc-url robinhood_testnet --broadcast
///
/// POOL_MANAGER must be Uniswap v4's PoolManager address on Robinhood
/// Chain Testnet. This repo does not hardcode a guess for it — look it up
/// yourself (the testnet explorer, or Uniswap's own deployments docs)
/// rather than trusting an unverified address here; getting this wrong
/// means the deploy either reverts harmlessly or, worse, points at
/// something that isn't actually the real PoolManager.
///
/// PLATFORM_FIRST_BUY_WEI (optional, default 0.01 ether) is spent from the
/// deployer's own funds as the platform token's bootstrap first buy.
///
/// LIVE_TIER_UPDATER (optional, defaults to the deployer) is the address
/// authorized to reposition the 14 live-tier PegPools later. Since that
/// role is set immutably at each PegPool's construction and `initialize()`
/// must be called by that same address, this MUST equal PRIVATE_KEY's own
/// address unless you're broadcasting this script as that other account.
contract Deploy is Script, DeployCommon {
    function run() external {
        address poolManager = vm.envAddress("POOL_MANAGER");
        uint256 firstBuy = vm.envOr("PLATFORM_FIRST_BUY_WEI", uint256(0.01 ether));
        address deployer = vm.addr(vm.envUint("PRIVATE_KEY"));
        address liveTierUpdater = vm.envOr("LIVE_TIER_UPDATER", deployer);

        Deployed memory d = _deploy(poolManager, firstBuy, deployer, address(0), liveTierUpdater);

        string memory classCoins = _tickerMapJson(d.classCoins);
        string memory pegPools = _tickerMapJson(d.pegPools);

        string memory json = string.concat(
            "{",
            '"chainId":46630,',
            '"chainName":"Robinhood Chain Testnet",',
            '"rpcUrl":"https://rpc.testnet.chain.robinhood.com",',
            '"explorer":"https://explorer.testnet.chain.robinhood.com",',
            '"faucet":"https://faucet.testnet.chain.robinhood.com",',
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
            '"ethUsd":3500,',
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
        vm.writeJson(json, "deployments/testnet.json");

        console2.log("Launchpad:   ", d.launchpad);
        console2.log("LaunchRouter:", d.launchRouter);
        console2.log("Buyback:     ", d.buyback);
        console2.log("PlatformToken:", d.platformToken);
        console2.log("Wrote deployments/testnet.json");
    }
}
