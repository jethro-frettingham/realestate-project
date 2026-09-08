// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "./ParcelToken.sol";
import "./PriceOracle.sol";
import "./interfaces/IUniswapV4Migrator.sol";

/// @title BondingCurve
/// @notice One curve per launch. Holds the full 1,000,000,000 ParcelToken
///         supply, sells 800,000,000 of it against a virtual constant-product
///         curve priced in `pairCoin`, and migrates the remaining 200,000,000
///         plus everything raised into a Uniswap v4 pool once the curve
///         sells out.
///
///         The curve's virtual reserves are chosen so it opens at
///         `OPEN_CAP_USD` and finishes at `MIGRATE_CAP_USD`, both expressed
///         in the pair coin at creation time (see `_deriveVirtualReserves`).
///         Reserves are virtual, not funded — no external liquidity is at
///         risk before migration.
/// @dev Reference implementation for the Parcel demo. Unaudited — this has
///      not been reviewed for reentrancy, oracle manipulation, or rounding
///      exploits and should not hold real funds as-is.
contract BondingCurve {
    using SafeERC20 for IERC20;

    uint256 public constant TOTAL_SUPPLY = 1_000_000_000 ether;
    uint256 public constant CURVE_SUPPLY = 800_000_000 ether;
    uint256 public constant RESERVE_SUPPLY = 200_000_000 ether; // moves to the v4 pool at migration

    uint256 public constant OPEN_CAP_USD = 5_000 ether;     // 18-decimals USD
    uint256 public constant MIGRATE_CAP_USD = 35_000 ether;

    uint16 public constant CREATOR_BPS = 3_000; // 30%
    uint16 public constant HOLDER_BPS = 4_000;  // 40%
    uint16 public constant PROTOCOL_BPS = 3_000; // 30%
    uint16 public constant BPS_DENOM = 10_000;

    ParcelToken public immutable token;
    IERC20 public immutable pairCoin;      // e.g. the SHED or VILA coin
    PriceOracle public immutable oracle;
    string public pairTicker;              // ticker passed to the oracle, e.g. "SHED"

    address public immutable creator;
    uint16 public immutable feeBps;        // 100–300 (1%–3%), set at creation
    address public immutable protocolTreasury;
    IUniswapV4Migrator public immutable migrator;

    uint256 public virtualTokenReserve;
    uint256 public virtualPairReserve;
    uint256 public tokensSold;
    bool public migrated;

    uint256 public creatorFeesOwed;
    uint256 public protocolFeesOwed;

    // Pull-based fee accounting for holders — see docs on why this isn't a
    // push-to-every-holder transfer.
    uint256 public holderFeePerShare; // scaled by 1e18
    mapping(address => uint256) private _holderFeeCheckpoint;
    mapping(address => uint256) public holderFeesOwed;

    event Trade(address indexed trader, bool isBuy, uint256 pairIn, uint256 tokensOut, uint256 pairOut, uint256 tokensIn);
    event Migrated(uint256 pairToPool, uint256 tokensToPool);
    event FeesClaimed(address indexed who, uint256 amount);

    constructor(
        string memory name_,
        string memory symbol_,
        address pairCoin_,
        string memory pairTicker_,
        address oracle_,
        address creator_,
        uint16 feeBps_,
        address protocolTreasury_,
        address migrator_
    ) {
        require(feeBps_ >= 100 && feeBps_ <= 300, "BondingCurve: fee out of range");
        token = new ParcelToken(name_, symbol_, address(this));
        pairCoin = IERC20(pairCoin_);
        pairTicker = pairTicker_;
        oracle = PriceOracle(oracle_);
        creator = creator_;
        feeBps = feeBps_;
        protocolTreasury = protocolTreasury_;
        migrator = IUniswapV4Migrator(migrator_);

        (virtualTokenReserve, virtualPairReserve) = _deriveVirtualReserves(oracle_, pairTicker_);
    }

    /// @dev Solves for virtual reserves such that the curve's spot price
    ///      starts at OPEN_CAP_USD / TOTAL_SUPPLY and, after CURVE_SUPPLY
    ///      tokens are sold, reaches MIGRATE_CAP_USD / TOTAL_SUPPLY — using
    ///      the standard constant-product identity x*y=k.
    function _deriveVirtualReserves(address oracle_, string memory ticker)
        internal
        view
        returns (uint256 vToken, uint256 vPair)
    {
        uint256 usdIndex = PriceOracle(oracle_).currentPrice(ticker); // USD per 1 pair-coin unit, 18dp
        uint256 startPriceUsd = OPEN_CAP_USD * 1e18 / TOTAL_SUPPLY;    // USD per token, 18dp
        uint256 endPriceUsd = MIGRATE_CAP_USD * 1e18 / TOTAL_SUPPLY;

        // price in pair-coin units = price in USD / usdIndex
        uint256 startPricePair = startPriceUsd * 1e18 / usdIndex;
        uint256 endPricePair = endPriceUsd * 1e18 / usdIndex;

        // vToken solves: endPricePair/startPricePair = (vToken / (vToken - CURVE_SUPPLY))^2
        uint256 ratio = _sqrt(endPricePair * 1e18 / startPricePair); // 1e9-scaled sqrt of a 1e18 ratio
        // vToken - CURVE_SUPPLY = vToken * 1e9 / ratio  =>  vToken * (ratio - 1e9) = CURVE_SUPPLY * ratio
        vToken = (CURVE_SUPPLY * ratio) / (ratio - 1e9);
        vPair = vToken * startPricePair / 1e18;
    }

    function _sqrt(uint256 x) internal pure returns (uint256 y) {
        if (x == 0) return 0;
        uint256 z = (x + 1) / 2;
        y = x;
        while (z < y) {
            y = z;
            z = (x / z + z) / 2;
        }
    }

    /// @notice Buy tokens with `pairAmountIn` of the pair coin.
    function buy(uint256 pairAmountIn, uint256 minTokensOut) external returns (uint256 tokensOut) {
        require(!migrated, "BondingCurve: migrated");
        require(pairAmountIn > 0, "BondingCurve: zero amount");

        pairCoin.safeTransferFrom(msg.sender, address(this), pairAmountIn);

        uint256 fee = pairAmountIn * feeBps / BPS_DENOM;
        uint256 netIn = pairAmountIn - fee;
        _distributeFee(fee);

        uint256 k = virtualTokenReserve * virtualPairReserve;
        uint256 newPairReserve = virtualPairReserve + netIn;
        uint256 newTokenReserve = k / newPairReserve;
        tokensOut = virtualTokenReserve - newTokenReserve;

        require(tokensOut >= minTokensOut, "BondingCurve: slippage");
        require(tokensSold + tokensOut <= CURVE_SUPPLY, "BondingCurve: exceeds curve supply");

        virtualTokenReserve = newTokenReserve;
        virtualPairReserve = newPairReserve;
        tokensSold += tokensOut;

        IERC20(address(token)).safeTransfer(msg.sender, tokensOut);
        emit Trade(msg.sender, true, pairAmountIn, tokensOut, 0, 0);

        if (tokensSold == CURVE_SUPPLY) {
            _migrate();
        }
    }

    /// @notice Sell `tokenAmountIn` tokens back into the curve.
    function sell(uint256 tokenAmountIn, uint256 minPairOut) external returns (uint256 pairOut) {
        require(!migrated, "BondingCurve: migrated");
        require(tokenAmountIn > 0, "BondingCurve: zero amount");

        IERC20(address(token)).safeTransferFrom(msg.sender, address(this), tokenAmountIn);

        uint256 k = virtualTokenReserve * virtualPairReserve;
        uint256 newTokenReserve = virtualTokenReserve + tokenAmountIn;
        uint256 newPairReserve = k / newTokenReserve;
        uint256 grossOut = virtualPairReserve - newPairReserve;

        uint256 fee = grossOut * feeBps / BPS_DENOM;
        pairOut = grossOut - fee;
        require(pairOut >= minPairOut, "BondingCurve: slippage");

        virtualTokenReserve = newTokenReserve;
        virtualPairReserve = newPairReserve;
        tokensSold -= tokenAmountIn;

        _distributeFee(fee);
        pairCoin.safeTransfer(msg.sender, pairOut);
        emit Trade(msg.sender, false, 0, 0, pairOut, tokenAmountIn);
    }

    function _distributeFee(uint256 fee) internal {
        uint256 creatorCut = fee * CREATOR_BPS / BPS_DENOM;
        uint256 holderCut = fee * HOLDER_BPS / BPS_DENOM;
        uint256 protocolCut = fee - creatorCut - holderCut; // remainder avoids rounding dust loss

        creatorFeesOwed += creatorCut;
        protocolFeesOwed += protocolCut;

        uint256 circulating = tokensSold; // tokens currently out of the curve
        if (circulating > 0 && holderCut > 0) {
            holderFeePerShare += holderCut * 1e18 / circulating;
        } else {
            // No circulating supply to weight by yet — route to protocol
            // rather than lock the fee in the contract.
            protocolFeesOwed += holderCut;
        }
    }

    /// @notice Claim a holder's accrued share of the 40% holder fee pool.
    ///         Weighted by the caller's ParcelToken balance at each fee
    ///         event since their last claim (standard reward-per-share
    ///         accounting, the same pattern staking contracts use).
    function claimHolderFees() external returns (uint256 amount) {
        uint256 owed = _pendingHolderFees(msg.sender);
        _holderFeeCheckpoint[msg.sender] = holderFeePerShare;
        holderFeesOwed[msg.sender] = 0;
        if (owed > 0) {
            pairCoin.safeTransfer(msg.sender, owed);
            emit FeesClaimed(msg.sender, owed);
        }
        return owed;
    }

    function _pendingHolderFees(address who) internal view returns (uint256) {
        uint256 delta = holderFeePerShare - _holderFeeCheckpoint[who];
        uint256 accrued = delta * IERC20(address(token)).balanceOf(who) / 1e18;
        return holderFeesOwed[who] + accrued;
    }

    /// @dev Called by transfer hooks in a full implementation to checkpoint
    ///      a holder's accrued fees before their balance changes. Omitted
    ///      here since ParcelToken is a plain OZ ERC20 — a production
    ///      version would either override `_update` on the token to call
    ///      back into the curve, or move to a snapshot/epoch model.
    function checkpoint(address who) external {
        holderFeesOwed[who] = _pendingHolderFees(who);
        _holderFeeCheckpoint[who] = holderFeePerShare;
    }

    function claimCreatorFees() external {
        require(msg.sender == creator, "BondingCurve: not creator");
        uint256 amount = creatorFeesOwed;
        creatorFeesOwed = 0;
        if (amount > 0) {
            pairCoin.safeTransfer(creator, amount);
            emit FeesClaimed(creator, amount);
        }
    }

    function claimProtocolFees() external {
        uint256 amount = protocolFeesOwed;
        protocolFeesOwed = 0;
        if (amount > 0) {
            pairCoin.safeTransfer(protocolTreasury, amount);
            emit FeesClaimed(protocolTreasury, amount);
        }
    }

    function _migrate() internal {
        migrated = true;
        uint256 pairBalance = pairCoin.balanceOf(address(this)) - creatorFeesOwed - protocolFeesOwed;
        IERC20(address(token)).safeIncreaseAllowance(address(migrator), RESERVE_SUPPLY);
        pairCoin.safeIncreaseAllowance(address(migrator), pairBalance);
        migrator.createAndSeedPool(address(token), address(pairCoin), pairBalance, RESERVE_SUPPLY, feeBps);
        emit Migrated(pairBalance, RESERVE_SUPPLY);
    }
}
