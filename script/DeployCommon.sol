// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "forge-std/Script.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";

import {FeeHook} from "../contracts/FeeHook.sol";
import {Launchpad} from "../contracts/Launchpad.sol";
import {LaunchRouter} from "../contracts/LaunchRouter.sol";
import {Buyback} from "../contracts/Buyback.sol";
import {PropertyClassCoin} from "../contracts/PropertyClassCoin.sol";
import {PegPool} from "../contracts/PegPool.sol";
import {HookMiner} from "./HookMiner.sol";

/// @title DeployCommon
/// @notice Shared deploy logic for both Robinhood Chain Testnet and
///         mainnet — the two chain-specific scripts (`Deploy.s.sol`,
///         `DeployMainnet.s.sol`) differ only in which `PoolManager`
///         address, chain id/RPC/explorer, and output file they pass in.
///
///         Classes split into two tiers: the six with no real market
///         (COUCH, TENT, SHED, LEAN, VAN, SHTY) stay on the static, fully-
///         collateralized `PropertyClassCoin`. The fourteen with genuine
///         (if infrequently-published) reference data get a `PegPool` —
///         see PegPool.sol for why a live-fed coin needs an AMM peg
///         rather than a mutable-rate mint/redeem contract.
abstract contract DeployCommon is Script {
    // Canonical deterministic-deployment proxy Foundry uses for a
    // broadcasted `new X{salt: s}(...)`. Present on essentially every EVM
    // chain (`forge script --broadcast` deploys it automatically if not) —
    // verify this holds for the target chain before a real deploy.
    address internal constant CREATE2_DEPLOYER = 0x4e59b44847b379578588920cA78FbF26c0B4956C;

    // Static assumption used only to size the two curve caps and the
    // starting property-class rates in ETH terms at deploy time — not a
    // live price, and not read by any contract at runtime.
    uint256 internal constant ETH_USD = 3_500 ether;
    uint256 internal constant OPEN_CAP_USD = 5_000 ether;
    uint256 internal constant MIGRATE_CAP_USD = 35_000 ether;

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
    // See script/Deploy.s.sol's original comment for sourcing methodology.
    uint256[20] usdPrices = [
        uint256(53 ether), 215 ether, 4_385 ether, 315 ether,
        18_750 ether, 86_077 ether, 71_300 ether, 91_667 ether, 50_000 ether,
        8_150 ether, 150_000 ether, 349_186 ether, 431_378 ether, 733_343 ether, 366_671 ether,
        1_350_000 ether, 3_700_000 ether, 37_176 ether, 65_000 ether, 401_564 ether
    ];
    // true = live tier (PegPool), false = static tier (PropertyClassCoin).
    // Same order as tickers/names/usdPrices above.
    bool[20] isLiveTier = [
        false, false, false, false, // COUCH, TENT, SHED, LEAN
        false, true, true, true, true, // VAN, RV, TRLR, TINY, CTNR
        false, true, true, true, true, true, // SHTY, CABN, CNDO, HOUS, DPLX, TOWN
        true, true, true, true, true // VILA, MANR, FARM, COMM, HIRS
    ];

    struct Deployed {
        uint256 deployedBlock; // the block this whole stack was deployed at
        address deployer;
        address poolManager;
        address feeHook;
        address launchpad;
        address launchRouter;
        address buyback;
        address usdg;
        address platformToken;
        uint256 platformLaunchId;
        address[20] classCoins; // the ERC20 coin, whichever tier
        address[20] pegPools; // nonzero only for live-tier indices
    }

    /// @param realUsdg Pass address(0) on testnet to deploy a static-rate
    ///        stand-in coin for demo purposes. On mainnet this MUST be the
    ///        real USDG contract address — never a new mint — see
    ///        DEPLOY.md; a stand-in "USDG" on mainnet would be a
    ///        fake-stablecoin impersonation risk, not a demo limitation.
    /// @param liveTierUpdater The ops key/multisig authorized to call
    ///        `PegPool.reposition()` for the 14 live-tier classes when
    ///        their reference index publishes a new number.
    /// @param bootstrapPlatformToken Pass true to launch a platform token
    ///        through this same Launchpad (the testnet/rehearsal demo
    ///        path) and wire it into Buyback immediately. Pass false when
    ///        the platform token ($CASTLE) is launched externally instead
    ///        (e.g. on Pons, for its own fee/visibility mechanics) — in
    ///        that case Buyback is left unset (`platformSet == false`,
    ///        `executeBuyback()` reverts `NothingToBuy`) until a separate,
    ///        later call to `Buyback.setPlatformPool()` points it at the
    ///        real pool once that external launch actually exists. See
    ///        script/SetPlatformPool.s.sol for that follow-up step.
    function _deploy(
        address poolManagerAddr,
        uint256 platformFirstBuyWei,
        address protocolTreasury,
        address realUsdg,
        address liveTierUpdater,
        bool bootstrapPlatformToken
    ) internal returns (Deployed memory out) {
        uint256 deployerKey = vm.envUint("PRIVATE_KEY");
        address deployer = vm.addr(deployerKey);
        IPoolManager poolManager = IPoolManager(poolManagerAddr);

        vm.startBroadcast(deployerKey);

        // Captured before anything deploys — the front end uses this as the
        // starting point for every event log scan (Trade, RewardAdded,
        // BuybackExecuted, ...) instead of block 0. On a long-lived chain
        // like mainnet, scanning from genesis means asking the RPC to
        // search the entire chain history on every page load for events
        // that can only possibly exist from this block onward — slow at
        // best, and many providers flatly refuse an eth_getLogs range that
        // large.
        out.deployedBlock = block.number;
        out.deployer = deployer;
        out.poolManager = poolManagerAddr;

        // 1. Property class coins + USDG.
        if (realUsdg != address(0)) {
            out.usdg = realUsdg;
        } else {
            PropertyClassCoin usdg = new PropertyClassCoin("Parcel USDG (testnet)", "USDG", 1 ether * 1 ether / ETH_USD);
            out.usdg = address(usdg);
        }

        for (uint256 i = 0; i < tickers.length; i++) {
            uint256 weiPerUnit = usdPrices[i] * 1 ether / ETH_USD;
            if (isLiveTier[i]) {
                PegPool pegPool = new PegPool(poolManager, liveTierUpdater, string.concat(names[i], " (Parcel)"), tickers[i]);
                pegPool.initialize(weiPerUnit);
                out.pegPools[i] = address(pegPool);
                out.classCoins[i] = address(pegPool.coin());
            } else {
                PropertyClassCoin coin =
                    new PropertyClassCoin(string.concat(names[i], " (Parcel)"), tickers[i], weiPerUnit);
                out.classCoins[i] = address(coin);
            }
        }

        // 2. Buyback, awaiting its platform pool (set once, after step 6).
        Buyback buyback = new Buyback(poolManager, deployer);
        out.buyback = address(buyback);

        // 3. Predict Launchpad's address so FeeHook can take it as an
        //    immutable constructor arg, breaking the FeeHook<->Launchpad
        //    circular dependency without any mutable setter on Launchpad.
        // +1: FeeHook itself consumes the next nonce slot (CREATE2 still
        // increments a contract account's nonce), so Launchpad lands one
        // slot after the nonce we read here.
        address predictedLaunchpad = vm.computeCreateAddress(deployer, vm.getNonce(deployer) + 1);

        // 4. Mine + deploy FeeHook via CREATE2 so its address carries only
        //    the AFTER_INITIALIZE_FLAG bit.
        (, bytes32 salt) = HookMiner.find(
            CREATE2_DEPLOYER,
            Hooks.AFTER_INITIALIZE_FLAG,
            type(FeeHook).creationCode,
            abi.encode(poolManager, predictedLaunchpad)
        );
        FeeHook feeHook = new FeeHook{salt: salt}(poolManager, predictedLaunchpad);
        out.feeHook = address(feeHook);

        // 5. Launchpad — must land at `predictedLaunchpad`.
        uint256 openCapWei = OPEN_CAP_USD * 1 ether / ETH_USD;
        uint256 migrateCapWei = MIGRATE_CAP_USD * 1 ether / ETH_USD;
        Launchpad launchpad =
            new Launchpad(poolManager, feeHook, address(buyback), protocolTreasury, openCapWei, migrateCapWei);
        require(address(launchpad) == predictedLaunchpad, "DeployCommon: launchpad address mismatch");
        out.launchpad = address(launchpad);

        // 6. Router.
        LaunchRouter router = new LaunchRouter(poolManager, launchpad);
        out.launchRouter = address(router);

        // 7. Bootstrap the platform token (the $CME-equivalent buyback
        //    target) as an ordinary ETH-paired launch, then wire it into
        //    Buyback. This step spends `platformFirstBuyWei` of real ETH
        //    from the deployer as the platform token's first buy. Skipped
        //    when the platform token is launched externally instead — see
        //    the `bootstrapPlatformToken` param doc above.
        if (bootstrapPlatformToken) {
            (uint256 platformLaunchId, address platformToken) = launchpad.createLaunch{value: platformFirstBuyWei}(
                "Parcel", "PARCEL", address(0), 300, "", 0
            );
            out.platformLaunchId = platformLaunchId;
            out.platformToken = platformToken;

            Launchpad.Launch memory platformLaunch = launchpad.getLaunch(platformLaunchId);
            buyback.setPlatformPool(platformLaunch.poolKey, platformToken);
        }

        vm.stopBroadcast();
    }

    /// @dev Builds a `{"TICKER":"0x...",...}` JSON object from a 20-entry
    ///      address array in `tickers` order — shared by both deploy
    ///      scripts for `classCoins` and `pegPools`.
    function _tickerMapJson(address[20] memory addrs) internal view returns (string memory json) {
        json = "{";
        for (uint256 i = 0; i < tickers.length; i++) {
            json = string.concat(json, '"', tickers[i], '":"', vm.toString(addrs[i]), '"', i < tickers.length - 1 ? "," : "");
        }
        json = string.concat(json, "}");
    }
}
