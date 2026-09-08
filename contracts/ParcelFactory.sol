// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "./BondingCurve.sol";

/// @title ParcelFactory
/// @notice Entry point for a launch. Deploys a BondingCurve (which deploys
///         its own ParcelToken), records its metadata URI on chain, and
///         forwards the creator's first buy — in ETH, in the same
///         transaction. No token needs to exist before this call, and none
///         needs to be minted or approved by the creator or by any later
///         buyer: connect a wallet, send ETH, get tokens. Optionally
///         picking a property class (`pairCoin_`) doesn't change any of
///         that — it only changes what migration seeds (see BondingCurve).
/// @dev Reference implementation for the Parcel demo. Unaudited.
contract ParcelFactory {
    struct Launch {
        address curve;
        address token;
        address pairCoin;     // address(0) if no class was picked
        string propertyClass; // display tag mirrored from the curve, "" if none
        address creator;
        string metadataURI; // content-addressed: name, image, links, description
        uint64 createdAt;
    }

    address public immutable protocolTreasury;
    address public immutable migrator;

    Launch[] public launches;
    mapping(address => uint256[]) public launchesByCreator;

    event LaunchCreated(
        uint256 indexed launchId,
        address indexed creator,
        address curve,
        address token,
        address pairCoin,
        string propertyClass,
        uint16 feeBps,
        string metadataURI
    );

    constructor(address protocolTreasury_, address migrator_) {
        protocolTreasury = protocolTreasury_;
        migrator = migrator_;
    }

    /// @param name_          Market name shown in the UI
    /// @param symbol_        Market ticker shown in the UI
    /// @param pairCoin_      A PropertyClassCoin address to pick a class, or
    ///                       address(0) for no class (single-pool migration)
    /// @param feeBps         100–300 (1%–3%), chosen by the creator
    /// @param metadataURI    Content-addressed URI for image/description/links
    /// @param minTokensOut   Slippage floor for the first buy
    /// The creator's first buy is msg.value — at least enough to clear the
    /// curve's built-in minimum (see BondingCurve.buy).
    function createLaunch(
        string calldata name_,
        string calldata symbol_,
        address pairCoin_,
        uint16 feeBps,
        string calldata metadataURI,
        uint256 minTokensOut
    ) external payable returns (uint256 launchId, address curveAddr) {
        require(msg.value > 0, "ParcelFactory: first buy required");

        BondingCurve curve = new BondingCurve(
            name_,
            symbol_,
            pairCoin_,
            msg.sender,
            feeBps,
            protocolTreasury,
            migrator
        );

        curve.buy{value: msg.value}(minTokensOut);

        // The curve sent the just-bought tokens to the factory (since the
        // factory called buy) — forward them on to the actual creator.
        IERC20 tok = IERC20(address(curve.token()));
        tok.transfer(msg.sender, tok.balanceOf(address(this)));

        string memory propertyClass_ = curve.propertyClass();

        launchId = launches.length;
        launches.push(Launch({
            curve: address(curve),
            token: address(curve.token()),
            pairCoin: pairCoin_,
            propertyClass: propertyClass_,
            creator: msg.sender,
            metadataURI: metadataURI,
            createdAt: uint64(block.timestamp)
        }));
        launchesByCreator[msg.sender].push(launchId);

        emit LaunchCreated(launchId, msg.sender, address(curve), address(curve.token()), pairCoin_, propertyClass_, feeBps, metadataURI);
        return (launchId, address(curve));
    }

    function launchCount() external view returns (uint256) {
        return launches.length;
    }

    function launchesOf(address creator) external view returns (uint256[] memory) {
        return launchesByCreator[creator];
    }
}
