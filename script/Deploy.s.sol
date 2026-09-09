// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "forge-std/Script.sol";
import "../contracts/ParcelFactory.sol";
import "../contracts/TestnetMigrator.sol";
import "../contracts/PropertyClassCoin.sol";

/// @title Deploy
/// @notice Deploys the Parcel stack to Robinhood Chain Testnet: a
///         TestnetMigrator, one PropertyClassCoin per property class (20
///         total) plus USDG (the same fully-collateralized mint/redeem
///         mechanism, just pegged to $1 instead of a property price), and
///         a ParcelFactory. Every peg here is static — fixed at deploy
///         time, no oracle, no keeper. Writes every address to
///         deployments/testnet.json, which assets/app.js reads at runtime.
///
/// Usage (from the repo root, after `forge install` and `cp .env.example
/// .env` with PRIVATE_KEY filled in):
///
///   forge script script/Deploy.s.sol \
///     --rpc-url robinhood_testnet \
///     --broadcast
///
/// See DEPLOY.md for the full walkthrough, including getting testnet ETH.
contract Deploy is Script {
    // Static assumption used only to size starting peg rates in ETH terms —
    // not a live price, and not read by any contract at runtime. Change
    // this and redeploy if you want different starting rates.
    uint256 constant ETH_USD = 3_500 ether;

    // Keep in sync with assets/classes.js.
    string[20] tickers = [
        "COUCH", "TENT", "SHED", "LEAN",
        "VAN", "RV", "TRLR", "TINY", "CTNR",
        "SHTY", "CABN", "CNDO", "HOUS", "DPLX", "TOWN",
        "VILA", "MANR", "FARM", "COMM", "HIRS"
    ];
    string[20] names = [
        "Friend's Couch", "Tent Pad", "Tin Shed / Storage Unit", "Lean-to",
        "Converted Van", "RV / Motorhome", "Single-wide Trailer", "Tiny Home", "Container Home",
        "Shanty", "Cabin", "Condo Unit", "Single-family House", "Duplex", "Townhouse",
        "Villa", "Manor Estate", "Farmland", "Commercial Unit", "High-rise Unit"
    ];
    // Starting USD reference prices — researched Sept 2026, averaged across
    // multiple sources per category where a real market exists. Novelty-tier
    // items (COUCH, TENT, SHED, LEAN, VAN, SHTY) have no real market to
    // research and stay illustrative — just not suspiciously round anymore.
    // Full source list and methodology: see docs.html "Property-class coins".
    //   RV, TINY, TRLR, CTNR, CABN, CNDO, HOUS, FARM, VILA, MANR, COMM —
    //   averaged from 2–4 independent sources each (RV/motorhome pricing
    //   guides, tiny-home cost guides, manufactured-home data, container-home
    //   builders, cabin cost guides, Redfin/NAR/Census/Trading Economics for
    //   housing, USDA/LandSearch/Purdue for farmland, Realtor.com's Luxury
    //   Report for VILA/MANR, commercial per-sqft data for COMM).
    //   DPLX/TOWN/HIRS are derived from HOUS/CNDO with a disclosed multiplier,
    //   not independently sourced. FARM applies a disclosed 3x multiplier to
    //   bare land value since no source prices "land with structures".
    uint256[20] usdPrices = [
        uint256(53 ether), 215 ether, 4_385 ether, 315 ether,
        18_750 ether, 86_077 ether, 71_300 ether, 91_667 ether, 50_000 ether,
        8_150 ether, 150_000 ether, 349_186 ether, 431_378 ether, 733_343 ether, 366_671 ether,
        1_350_000 ether, 3_700_000 ether, 37_176 ether, 65_000 ether, 401_564 ether
    ];

    function run() external {
        uint256 deployerKey = vm.envUint("PRIVATE_KEY");
        address deployer = vm.addr(deployerKey);

        vm.startBroadcast(deployerKey);

        TestnetMigrator migrator = new TestnetMigrator();
        ParcelFactory factory = new ParcelFactory(deployer, address(migrator));

        PropertyClassCoin usdg = new PropertyClassCoin(
            "Parcel USDG (testnet)",
            "USDG",
            1 ether * 1 ether / ETH_USD // 1 USDG == $1, converted to wei at the static ETH_USD rate
        );

        address[20] memory coinAddrs;
        for (uint256 i = 0; i < tickers.length; i++) {
            uint256 weiPerUnit = usdPrices[i] * 1 ether / ETH_USD;
            PropertyClassCoin coin = new PropertyClassCoin(
                string.concat(names[i], " (Parcel)"),
                tickers[i],
                weiPerUnit
            );
            coinAddrs[i] = address(coin);
        }

        vm.stopBroadcast();

        string memory classCoins = "{";
        for (uint256 i = 0; i < tickers.length; i++) {
            classCoins = string.concat(
                classCoins,
                '"', tickers[i], '":"', vm.toString(coinAddrs[i]), '"',
                i < tickers.length - 1 ? "," : ""
            );
        }
        classCoins = string.concat(classCoins, "}");

        string memory json = string.concat(
            "{",
            '"chainId":46630,',
            '"chainName":"Robinhood Chain Testnet",',
            '"rpcUrl":"https://rpc.testnet.chain.robinhood.com",',
            '"explorer":"https://explorer.testnet.chain.robinhood.com",',
            '"faucet":"https://faucet.testnet.chain.robinhood.com",',
            '"deployer":"', vm.toString(deployer), '",',
            '"factory":"', vm.toString(address(factory)), '",',
            '"migrator":"', vm.toString(address(migrator)), '",',
            '"usdg":"', vm.toString(address(usdg)), '",',
            '"ethUsd":3500,',
            '"deployedAt":', vm.toString(block.timestamp), ',',
            '"classCoins":', classCoins,
            "}"
        );
        vm.writeJson(json, "deployments/testnet.json");

        console2.log("TestnetMigrator:", address(migrator));
        console2.log("ParcelFactory:  ", address(factory));
        console2.log("USDG:           ", address(usdg));
        console2.log("Wrote deployments/testnet.json");
    }
}
