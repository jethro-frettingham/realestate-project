// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "forge-std/Script.sol";
import "../contracts/ParcelFactory.sol";
import "../contracts/TestnetMigrator.sol";

/// @title Deploy
/// @notice Deploys the Parcel stack to Robinhood Chain Testnet: a
///         TestnetMigrator and a ParcelFactory. That's it — launches are
///         ETH-native, so there's no per-class coin, no USDG mock, and no
///         oracle to seed. Writes both addresses to deployments/testnet.json,
///         which assets/app.js reads at runtime.
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
        ParcelFactory factory = new ParcelFactory(deployer, address(migrator));

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
            '"deployedAt":', vm.toString(block.timestamp),
            "}"
        );
        vm.writeJson(json, "deployments/testnet.json");

        console2.log("TestnetMigrator:", address(migrator));
        console2.log("ParcelFactory:  ", address(factory));
        console2.log("Wrote deployments/testnet.json");
    }
}
