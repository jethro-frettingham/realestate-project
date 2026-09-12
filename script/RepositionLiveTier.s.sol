// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "forge-std/Script.sol";

interface IPegPool {
    function reposition(uint256 newWeiPerUnit) external;
}

/// @title RepositionLiveTier — manual price update for one live-tier class
/// @notice Run this by hand whenever one of the 14 live-tier classes' real-
///         world reference index (Redfin/NAR/Census for housing, USDA/
///         LandSearch/Purdue for farmland, RV pricing guides, ...)
///         publishes a new number. There is no automated feed for these —
///         see DEPLOY.md's "Operating the live-tier PegPools" section for
///         why: none of these sources publish faster than monthly, so a
///         live oracle would be solving a problem that doesn't exist here.
///
///         Looks up the class's PegPool address from a deployment JSON
///         (so you never have to paste a raw contract address by hand)
///         and calls reposition() with the converted rate. Reverts with a
///         clear message if PRIVATE_KEY isn't the pool's LIVE_TIER_UPDATER
///         (PegPool.sol's own check), if TICKER isn't a live-tier class,
///         or if the deployment file has no PegPool for it.
///
/// Usage:
///   TICKER=HOUS USD_PRICE=445000 ETH_USD=3500 \
///   PRIVATE_KEY=$LIVE_TIER_UPDATER_KEY \
///     forge script script/RepositionLiveTier.s.sol \
///     --rpc-url robinhood_mainnet --broadcast
///
/// TICKER: one of the 14 live-tier tickers — RV, TRLR, TINY, CTNR, CABN,
/// CNDO, HOUS, DPLX, TOWN, VILA, MANR, FARM, COMM, HIRS. The 6 static-tier
/// classes (COUCH, TENT, SHED, LEAN, VAN, SHTY) have no PegPool — their
/// rate is fixed forever at deploy time, there's nothing to reposition.
///
/// USD_PRICE: the new reference price in whole dollars (e.g. 445000 for
/// $445,000), not wei — this script does the conversion.
///
/// ETH_USD: today's actual ETH/USD price, NOT the static assumption baked
/// into the original deploy. Get this from wherever you'd check any other
/// price right now (Coinbase, CoinGecko, ...) — unlike the property
/// indices, this one genuinely moves by the hour, so it's supplied fresh
/// on every run rather than read back from the deployment file.
///
/// DEPLOYMENT_FILE (optional): which deployment JSON to read the PegPool
/// address from. Defaults to deployments/mainnet.json — pass
/// DEPLOYMENT_FILE=deployments/testnet.json to reposition a testnet pool
/// instead.
contract RepositionLiveTier is Script {
    function run() external {
        string memory ticker = vm.envString("TICKER");
        uint256 usdPrice = vm.envUint("USD_PRICE");
        uint256 ethUsd = vm.envUint("ETH_USD");
        string memory deploymentFile = vm.envOr("DEPLOYMENT_FILE", string("deployments/mainnet.json"));

        string memory json = vm.readFile(deploymentFile);
        address pegPool = vm.parseJsonAddress(json, string.concat(".pegPools.", ticker));
        require(
            pegPool != address(0),
            "RepositionLiveTier: no PegPool for that ticker in this deployment file (check TICKER spelling, or it's a static-tier class with no PegPool)"
        );

        uint256 weiPerUnit = usdPrice * 1 ether / ethUsd;

        vm.startBroadcast(vm.envUint("PRIVATE_KEY"));
        IPegPool(pegPool).reposition(weiPerUnit);
        vm.stopBroadcast();

        console2.log("Repositioned:  ", ticker);
        console2.log("PegPool:       ", pegPool);
        console2.log("New USD price: ", usdPrice);
        console2.log("New wei/unit:  ", weiPerUnit);
    }
}
