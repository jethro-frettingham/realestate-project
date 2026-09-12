// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "forge-std/Script.sol";
import {DeployCommon} from "./DeployCommon.sol";

/// @title DeployMainnet (Robinhood Chain mainnet)
/// @notice Same stack as script/Deploy.s.sol, pointed at Robinhood Chain
///         mainnet (chain id 4663) instead of testnet, using the real
///         Uniswap v4 PoolManager and the real USDG stablecoin.
///
/// !!! THIS SPENDS REAL ETH AND DEPLOYS UNAUDITED CONTRACTS TO MAINNET !!!
/// Do not run --broadcast against this without:
///   1. Running the full test suite, including a local-fork lifecycle
///      test (see the migration plan's Verification section).
///   2. Independently re-verifying POOL_MANAGER and USDG below against
///      Uniswap's and Paxos's own docs — they were sourced from web
///      searches during planning, cross-checked against a pasted
///      reference page for POOL_MANAGER but not independently confirmed
///      for USDG.
///   3. A real security review. Nothing in this repo has had one.
///
/// Usage:
///   PROTOCOL_TREASURY=0x... forge script script/DeployMainnet.s.sol \
///     --rpc-url robinhood_mainnet --broadcast
///
/// LIVE_TIER_UPDATER (optional, defaults to the deployer) is the address
/// authorized to reposition the 14 live-tier PegPools later — for a real
/// deployment this should almost certainly be a multisig you set up ahead
/// of time, not a single EOA. Since that role is set immutably at each
/// PegPool's construction and `initialize()` must be called by that same
/// address, this MUST equal PRIVATE_KEY's own address unless you're
/// broadcasting this script as that other account.
contract DeployMainnet is Script, DeployCommon {
    // Verified against Robinhood Chain's own Uniswap v4 deployment docs
    // AND cross-checked against the CME reference page used to scope this
    // migration (both list the same address).
    address internal constant POOL_MANAGER = 0x8366a39CC670B4001A1121B8F6A443A643e40951;

    // Paxos's Global Dollar (USDG), native to Robinhood Chain. Sourced
    // from a single web search during planning — RE-VERIFY this against
    // docs.paxos.com/guides/stablecoin/usdg/mainnet or Robinhood's own
    // docs before broadcasting. Never deploy a stand-in "USDG" on mainnet.
    address internal constant USDG = 0x5fc5360D0400a0Fd4f2af552ADD042D716F1d168;

    function run() external {
        uint256 firstBuy = vm.envOr("PLATFORM_FIRST_BUY_WEI", uint256(0.05 ether));
        address protocolTreasury = vm.envAddress("PROTOCOL_TREASURY");
        address deployer = vm.addr(vm.envUint("PRIVATE_KEY"));
        address liveTierUpdater = vm.envOr("LIVE_TIER_UPDATER", deployer);

        Deployed memory d = _deploy(POOL_MANAGER, firstBuy, protocolTreasury, USDG, liveTierUpdater);

        string memory classCoins = _tickerMapJson(d.classCoins);
        string memory pegPools = _tickerMapJson(d.pegPools);

        string memory json = string.concat(
            "{",
            '"chainId":4663,',
            '"chainName":"Robinhood Chain",',
            '"rpcUrl":"https://rpc.mainnet.chain.robinhood.com",',
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

        console2.log("Launchpad:    ", d.launchpad);
        console2.log("LaunchRouter: ", d.launchRouter);
        console2.log("Buyback:      ", d.buyback);
        console2.log("PlatformToken:", d.platformToken);
        console2.log("Wrote deployments/mainnet.json");
    }
}
