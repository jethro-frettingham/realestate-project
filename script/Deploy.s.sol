// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "forge-std/Script.sol";
import "../contracts/ParcelFactory.sol";
import "../contracts/TestnetMigrator.sol";
import "../contracts/ParcelBuyback.sol";

/// @title Deploy
/// @notice Deploys the Parcel stack to Robinhood Chain Testnet: a
///         TestnetMigrator, the $PARCEL buyback token/treasury, and a
///         ParcelFactory. Launches are ETH-native, so there's no per-class
///         coin, no USDG mock, and no oracle to seed. Writes every address
///         to deployments/testnet.json, which assets/app.js reads at
///         runtime.
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
    function run() external {
        uint256 deployerKey = vm.envUint("PRIVATE_KEY");
        address deployer = vm.addr(deployerKey);

        vm.startBroadcast(deployerKey);

        TestnetMigrator migrator = new TestnetMigrator();
        ParcelBuyback buyback = new ParcelBuyback(deployer);
        ParcelFactory factory = new ParcelFactory(address(buyback), deployer, address(migrator));

        vm.stopBroadcast();

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
            '"parcelBuyback":"', vm.toString(address(buyback)), '",',
            '"deployedAt":', vm.toString(block.timestamp),
            "}"
        );
        vm.writeJson(json, "deployments/testnet.json");

        console2.log("TestnetMigrator:", address(migrator));
        console2.log("ParcelBuyback:  ", address(buyback));
        console2.log("ParcelFactory:  ", address(factory));
        console2.log("Wrote deployments/testnet.json");
    }
}
