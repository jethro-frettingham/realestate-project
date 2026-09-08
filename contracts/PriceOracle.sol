// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "@openzeppelin/contracts/access/Ownable.sol";

/// @title PriceOracle
/// @notice Optional, currently unused by BondingCurve/ParcelFactory. Holds a
///         USD index price (18 decimals) per property class, e.g. SHED,
///         VILA, HOUS, for classes that want a "worth roughly N sheds"
///         style display. Kept as a separate piece deliberately — nothing
///         about launching or trading a token depends on this being
///         deployed, seeded, or fresh.
///
///         This is a minimal reference oracle for the demo, not a
///         production data pipeline:
///           - `reporters` should in practice be a set of independent
///             services pulling comparable sales/listing data (e.g. from
///             county records or listing APIs), not a single key.
///           - There is no staleness check baked into consumers here —
///             `BondingCurve` and `PropertyPool` should be extended to
///             reject a price older than `maxStaleness` before this goes
///             anywhere near real funds.
///           - Consider a median-of-reporters or a Chainlink-style
///             aggregation instead of last-writer-wins for production use.
/// @dev Unaudited reference implementation.
contract PriceOracle is Ownable {
    struct Price {
        uint256 usdPerUnit; // 18 decimals, e.g. 1 SHED's index price in USD
        uint64 updatedAt;
    }

    mapping(bytes32 => Price) public prices;          // classId => price
    mapping(address => bool) public isReporter;
    uint64 public maxStaleness = 1 days;

    event PriceReported(bytes32 indexed classId, uint256 usdPerUnit, address reporter);
    event ReporterSet(address reporter, bool allowed);
    event MaxStalenessSet(uint64 seconds_);

    modifier onlyReporter() {
        require(isReporter[msg.sender], "PriceOracle: not a reporter");
        _;
    }

    constructor(address initialOwner) Ownable(initialOwner) {}

    function classId(string memory ticker) public pure returns (bytes32) {
        return keccak256(bytes(ticker));
    }

    function setReporter(address reporter, bool allowed) external onlyOwner {
        isReporter[reporter] = allowed;
        emit ReporterSet(reporter, allowed);
    }

    function setMaxStaleness(uint64 seconds_) external onlyOwner {
        maxStaleness = seconds_;
        emit MaxStalenessSet(seconds_);
    }

    /// @notice Push a new index price for a class, e.g. "SHED" -> $4,200.
    function report(string calldata ticker, uint256 usdPerUnit) external onlyReporter {
        require(usdPerUnit > 0, "PriceOracle: zero price");
        bytes32 id = classId(ticker);
        prices[id] = Price(usdPerUnit, uint64(block.timestamp));
        emit PriceReported(id, usdPerUnit, msg.sender);
    }

    /// @notice Read the current index price. Reverts if it has never been
    ///         reported, or if it's older than `maxStaleness`.
    function currentPrice(string calldata ticker) external view returns (uint256) {
        Price memory p = prices[classId(ticker)];
        require(p.updatedAt > 0, "PriceOracle: no price yet");
        require(block.timestamp - p.updatedAt <= maxStaleness, "PriceOracle: stale price");
        return p.usdPerUnit;
    }
}
