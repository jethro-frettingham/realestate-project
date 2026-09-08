// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "forge-std/Script.sol";
import "../contracts/PriceOracle.sol";
import "../contracts/PropertyClassCoin.sol";
import "../contracts/ParcelFactory.sol";
import "../contracts/TestnetMigrator.sol";
import "../contracts/mocks/MockUSDG.sol";

/// @title Deploy
/// @notice Deploys the full Parcel stack to Robinhood Chain Testnet:
///         MockUSDG, PriceOracle (seeded with a starting index price for
///         every class in assets/classes.js), one PropertyClassCoin per
///         class, TestnetMigrator, and ParcelFactory. Writes every address
///         to deployments/testnet.json, which assets/app.js reads at
///         runtime — so a fresh deploy is picked up by the site with no
///         manual editing.
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
    // Keep this in sync with assets/classes.js. Prices are a rough
    // starting index (18dp, USD) — anything reported here is a testnet
    // placeholder, not a real comp.
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
    uint256[20] startPrices = [
        uint256(50 ether), 200 ether, 4_200 ether, 300 ether,
        18_000 ether, 45_000 ether, 60_000 ether, 55_000 ether, 35_000 ether,
        8_000 ether, 90_000 ether, 250_000 ether, 420_000 ether, 650_000 ether, 480_000 ether,
        1_200_000 ether, 3_500_000 ether, 15_000 ether, 900_000 ether, 380_000 ether
    ];

    function run() external {
        uint256 deployerKey = vm.envUint("PRIVATE_KEY");
        address deployer = vm.addr(deployerKey);

        vm.startBroadcast(deployerKey);

        MockUSDG usdg = new MockUSDG();

        PriceOracle oracle = new PriceOracle(deployer);
        oracle.setReporter(deployer, true);

        TestnetMigrator migrator = new TestnetMigrator();

        ParcelFactory factory = new ParcelFactory(address(oracle), deployer, address(migrator));

        address[20] memory coinAddrs;
        for (uint256 i = 0; i < tickers.length; i++) {
            oracle.report(tickers[i], startPrices[i]);

            string memory coinName = string.concat(names[i], " Index");
            PropertyClassCoin coin = new PropertyClassCoin(
                coinName,
                tickers[i],
                address(usdg),
                address(oracle),
                tickers[i]
            );
            coinAddrs[i] = address(coin);
        }

        vm.stopBroadcast();

        _writeDeploymentJson(deployer, address(usdg), address(oracle), address(migrator), address(factory), coinAddrs);

        console2.log("MockUSDG:      ", address(usdg));
        console2.log("PriceOracle:   ", address(oracle));
        console2.log("TestnetMigrator:", address(migrator));
        console2.log("ParcelFactory: ", address(factory));
        console2.log("Wrote deployments/testnet.json");
    }

    function _writeDeploymentJson(
        address deployer,
        address usdg,
        address oracle,
        address migrator,
        address factory,
        address[20] memory coinAddrs
    ) internal {
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
            '"factory":"', vm.toString(factory), '",',
            '"oracle":"', vm.toString(oracle), '",',
            '"usdg":"', vm.toString(usdg), '",',
            '"migrator":"', vm.toString(migrator), '",',
            '"deployedAt":', vm.toString(block.timestamp), ',',
            '"classCoins":', classCoins,
            "}"
        );

        vm.writeJson(json, "deployments/testnet.json");
    }
}
