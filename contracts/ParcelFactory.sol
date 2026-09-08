// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "./BondingCurve.sol";

/// @title ParcelFactory
/// @notice Entry point for a launch. Deploys a BondingCurve (which deploys
///         its own ParcelToken), records its metadata URI on chain, and
///         forwards the creator's first buy in the same transaction —
///         matching the "connect wallet, fill the form, launch" flow on
///         the /launch page.
/// @dev Reference implementation for the Parcel demo. Unaudited.
contract ParcelFactory {
    using SafeERC20 for IERC20;

    struct Launch {
        address curve;
        address token;
        address pairCoin;
        string pairTicker;
        address creator;
        string metadataURI; // content-addressed: name, image, links, description
        uint64 createdAt;
    }

    address public immutable oracle;
    address public immutable protocolTreasury;
    address public immutable migrator;

    Launch[] public launches;
    mapping(address => uint256[]) public launchesByCreator;

    event LaunchCreated(
        uint256 indexed launchId,
        address indexed creator,
        address curve,
        address token,
        string pairTicker,
        uint16 feeBps,
        string metadataURI
    );

    constructor(address oracle_, address protocolTreasury_, address migrator_) {
        oracle = oracle_;
        protocolTreasury = protocolTreasury_;
        migrator = migrator_;
    }

    /// @param name_        Market name shown in the UI
    /// @param symbol_      Market ticker shown in the UI
    /// @param pairCoin     Address of the property-class coin to pair with
    /// @param pairTicker   That class's ticker, e.g. "SHED" — must match the oracle key
    /// @param feeBps       100–300 (1%–3%), chosen by the creator
    /// @param metadataURI  Content-addressed URI for image/description/links
    /// @param firstBuyIn   Pair-coin amount for the creator's required first buy (>= $1 equivalent)
    /// @param minTokensOut Slippage floor for the first buy
    function createLaunch(
        string calldata name_,
        string calldata symbol_,
        address pairCoin,
        string calldata pairTicker,
        uint16 feeBps,
        string calldata metadataURI,
        uint256 firstBuyIn,
        uint256 minTokensOut
    ) external returns (uint256 launchId, address curveAddr) {
        require(firstBuyIn > 0, "ParcelFactory: first buy required");

        BondingCurve curve = new BondingCurve(
            name_,
            symbol_,
            pairCoin,
            pairTicker,
            oracle,
            msg.sender,
            feeBps,
            protocolTreasury,
            migrator
        );

        // Pull the creator's first buy through the factory so `createLaunch`
        // is the single transaction described in the docs — the creator
        // only signs once.
        IERC20(pairCoin).safeTransferFrom(msg.sender, address(this), firstBuyIn);
        IERC20(pairCoin).safeIncreaseAllowance(address(curve), firstBuyIn);
        curve.buy(firstBuyIn, minTokensOut);

        // Forward the tokens just bought to the creator — the curve sent
        // them to the factory since the factory called `buy`.
        IERC20(curve.token()).safeTransfer(msg.sender, IERC20(curve.token()).balanceOf(address(this)));

        launchId = launches.length;
        launches.push(Launch({
            curve: address(curve),
            token: address(curve.token()),
            pairCoin: pairCoin,
            pairTicker: pairTicker,
            creator: msg.sender,
            metadataURI: metadataURI,
            createdAt: uint64(block.timestamp)
        }));
        launchesByCreator[msg.sender].push(launchId);

        emit LaunchCreated(launchId, msg.sender, address(curve), address(curve.token()), pairTicker, feeBps, metadataURI);
        return (launchId, address(curve));
    }

    function launchCount() external view returns (uint256) {
        return launches.length;
    }

    function launchesOf(address creator) external view returns (uint256[] memory) {
        return launchesByCreator[creator];
    }
}
