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
    uint256[20] usdPrices = [
        uint256(50 ether), 200 ether, 4_200 ether, 300 ether,
        18_000 ether, 45_000 ether, 60_000 ether, 55_000 ether, 35_000 ether,
        8_000 ether, 90_000 ether, 250_000 ether, 420_000 ether, 650_000 ether, 480_000 ether,
        1_200_000 ether, 3_500_000 ether, 15_000 ether, 900_000 ether, 380_000 ether
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
