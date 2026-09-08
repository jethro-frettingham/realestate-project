// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "./ParcelToken.sol";
import "./PropertyClassCoin.sol";
import "./interfaces/IUniswapV4Migrator.sol";

/// @title BondingCurve
/// @notice One curve per launch. Holds the full 1,000,000,000 ParcelToken
///         supply, sells 800,000,000 of it directly against ETH on a virtual
///         constant-product curve — buying and selling always happens in
///         plain ETH, whether or not a property class was picked at
///         creation. `pairCoin` (e.g. SHED, HOUS) only changes what happens
///         at migration.
///
///         No class picked (`pairCoin == address(0)`): sellout migrates
///         the full 200,000,000 reserved tokens and all raised ETH into a
///         single TOKEN/ETH pool.
///
///         Class picked: sellout migrates into *two* pools — half the
///         reserved tokens and half the raised ETH into a TOKEN/ETH pool,
///         and the other half of each into a TOKEN/<class coin> pool (the
///         ETH going into that pool is minted into the class coin first,
///         at its fixed peg rate, so the pool is genuinely backed by the
///         class coin rather than a relabeled ETH balance).
/// @dev Reference implementation for the Parcel demo. Unaudited — this has
///      not been reviewed for reentrancy or rounding exploits and should
///      not hold real funds as-is.
contract BondingCurve {
    using SafeERC20 for IERC20;

    uint256 public constant TOTAL_SUPPLY = 1_000_000_000 ether;
    uint256 public constant CURVE_SUPPLY = 800_000_000 ether;
    uint256 public constant RESERVE_SUPPLY = 200_000_000 ether; // moves to pool(s) at migration

    // Fixed virtual reserves. With these values the curve opens around
    // ~2.8 ETH implied market cap and migrates once roughly ~8.8 ETH of
    // real ETH has been raised (before fees) — see test/BondingCurve.t.sol
    // for the derivation. Tune these two constants to change both numbers;
    // they don't depend on anything else in the contract, including
    // whether a class is picked.
    uint256 public constant VIRTUAL_ETH_RESERVE = 3 ether;
    uint256 public constant VIRTUAL_TOKEN_RESERVE = 1_073_000_000 ether;

    uint16 public constant CREATOR_BPS = 7_000; // 70%
    uint16 public constant PROTOCOL_BPS = 3_000; // 30%
    uint16 public constant BPS_DENOM = 10_000;

    ParcelToken public immutable token;
    PropertyClassCoin public immutable pairCoin; // address(0) if no class was picked
    string public propertyClass; // display tag mirrored from pairCoin.classTicker(), or "" if none

    address public immutable creator;
    uint16 public immutable feeBps;        // 100–300 (1%–3%), set at creation
    address public immutable protocolTreasury;
    IUniswapV4Migrator public immutable migrator;

    uint256 public virtualTokenReserve;
    uint256 public virtualEthReserve;
    uint256 public tokensSold;
    bool public migrated;

    uint256 public creatorFeesOwed;
    uint256 public protocolFeesOwed;

    event Trade(address indexed trader, bool isBuy, uint256 ethIn, uint256 tokensOut, uint256 ethOut, uint256 tokensIn);
    event Migrated(address indexed quoteAsset, uint256 quoteAmount, uint256 tokenAmount);
    event FeesClaimed(address indexed who, uint256 amount);

    constructor(
        string memory name_,
        string memory symbol_,
        address pairCoin_, // address(0) = no class, single-pool migration
        address creator_,
        uint16 feeBps_,
        address protocolTreasury_,
        address migrator_
    ) {
        require(feeBps_ >= 100 && feeBps_ <= 300, "BondingCurve: fee out of range");
        token = new ParcelToken(name_, symbol_, address(this));
        pairCoin = PropertyClassCoin(pairCoin_);
        propertyClass = pairCoin_ == address(0) ? "" : PropertyClassCoin(pairCoin_).classTicker();
        creator = creator_;
        feeBps = feeBps_;
        protocolTreasury = protocolTreasury_;
        migrator = IUniswapV4Migrator(migrator_);

        virtualTokenReserve = VIRTUAL_TOKEN_RESERVE;
        virtualEthReserve = VIRTUAL_ETH_RESERVE;
    }

    /// @notice Buy tokens by sending ETH directly — no approval, no
    ///         intermediate token, regardless of whether a class is picked.
    ///         `msg.value` is the full amount including the trading fee,
    ///         which is deducted before the curve math runs. If the amount
    ///         sent would buy more than the curve has left, the purchase is
    ///         automatically capped at the remaining supply and the unused
    ///         ETH is refunded in the same transaction rather than reverting.
    function buy(uint256 minTokensOut) external payable returns (uint256 tokensOut) {
        require(!migrated, "BondingCurve: migrated");
        require(msg.value > 0, "BondingCurve: zero amount");

        uint256 grossIn = msg.value;
        uint256 fee = grossIn * feeBps / BPS_DENOM;
        uint256 netIn = grossIn - fee;

        uint256 k = virtualTokenReserve * virtualEthReserve;
        uint256 newEthReserve = virtualEthReserve + netIn;
        uint256 newTokenReserve = k / newEthReserve;
        tokensOut = virtualTokenReserve - newTokenReserve;

        uint256 refund = 0;
        if (tokensSold + tokensOut > CURVE_SUPPLY) {
            // Cap at exactly what's left on the curve and refund the rest,
            // inverting the same fee math to find the smaller gross amount
            // that produces this capped netIn.
            tokensOut = CURVE_SUPPLY - tokensSold;
            newTokenReserve = virtualTokenReserve - tokensOut;
            newEthReserve = k / newTokenReserve;
            netIn = newEthReserve - virtualEthReserve;
            fee = netIn * feeBps / (BPS_DENOM - feeBps);
            grossIn = netIn + fee;
            refund = msg.value - grossIn;
        }

        require(tokensOut >= minTokensOut, "BondingCurve: slippage");

        _distributeFee(fee);
        virtualTokenReserve = newTokenReserve;
        virtualEthReserve = newEthReserve;
        tokensSold += tokensOut;

        IERC20(address(token)).safeTransfer(msg.sender, tokensOut);
        emit Trade(msg.sender, true, grossIn, tokensOut, 0, 0);

        if (refund > 0) {
            (bool sent, ) = msg.sender.call{value: refund}("");
            require(sent, "BondingCurve: refund failed");
        }

        if (tokensSold == CURVE_SUPPLY) {
            _migrate();
        }
    }

    /// @notice Sell `tokenAmountIn` tokens back into the curve for ETH.
    function sell(uint256 tokenAmountIn, uint256 minEthOut) external returns (uint256 ethOut) {
        require(!migrated, "BondingCurve: migrated");
        require(tokenAmountIn > 0, "BondingCurve: zero amount");

        IERC20(address(token)).safeTransferFrom(msg.sender, address(this), tokenAmountIn);

        uint256 k = virtualTokenReserve * virtualEthReserve;
        uint256 newTokenReserve = virtualTokenReserve + tokenAmountIn;
        uint256 newEthReserve = k / newTokenReserve;
        uint256 grossOut = virtualEthReserve - newEthReserve;

        uint256 fee = grossOut * feeBps / BPS_DENOM;
        ethOut = grossOut - fee;
        require(ethOut >= minEthOut, "BondingCurve: slippage");

        virtualTokenReserve = newTokenReserve;
        virtualEthReserve = newEthReserve;
        tokensSold -= tokenAmountIn;

        _distributeFee(fee);
        (bool sent, ) = msg.sender.call{value: ethOut}("");
        require(sent, "BondingCurve: ETH transfer failed");
        emit Trade(msg.sender, false, 0, 0, ethOut, tokenAmountIn);
    }

    function _distributeFee(uint256 fee) internal {
        uint256 creatorCut = fee * CREATOR_BPS / BPS_DENOM;
        uint256 protocolCut = fee - creatorCut; // remainder avoids rounding dust loss
        creatorFeesOwed += creatorCut;
        protocolFeesOwed += protocolCut;
    }

    function claimCreatorFees() external {
        require(msg.sender == creator, "BondingCurve: not creator");
        uint256 amount = creatorFeesOwed;
        creatorFeesOwed = 0;
        if (amount > 0) {
            (bool sent, ) = creator.call{value: amount}("");
            require(sent, "BondingCurve: ETH transfer failed");
            emit FeesClaimed(creator, amount);
        }
    }

    function claimProtocolFees() external {
        uint256 amount = protocolFeesOwed;
        protocolFeesOwed = 0;
        if (amount > 0) {
            (bool sent, ) = protocolTreasury.call{value: amount}("");
            require(sent, "BondingCurve: ETH transfer failed");
            emit FeesClaimed(protocolTreasury, amount);
        }
    }

    /// @dev No class: one TOKEN/ETH pool gets everything. Class picked:
    ///      split down the middle — half stays plain ETH, half gets minted
    ///      into the class coin (at its fixed peg, using real ETH) before
    ///      seeding a second, genuinely class-coin-backed pool.
    function _migrate() internal {
        migrated = true;
        uint256 ethBalance = address(this).balance - creatorFeesOwed - protocolFeesOwed;

        if (address(pairCoin) == address(0)) {
            IERC20(address(token)).safeIncreaseAllowance(address(migrator), RESERVE_SUPPLY);
            migrator.createAndSeedPool{value: ethBalance}(address(token), address(0), 0, RESERVE_SUPPLY, feeBps);
            emit Migrated(address(0), ethBalance, RESERVE_SUPPLY);
            return;
        }

        uint256 ethForEthPool = ethBalance / 2;
        uint256 ethForClassPool = ethBalance - ethForEthPool;
        uint256 tokensForEthPool = RESERVE_SUPPLY / 2;
        uint256 tokensForClassPool = RESERVE_SUPPLY - tokensForEthPool;

        IERC20(address(token)).safeIncreaseAllowance(address(migrator), tokensForEthPool);
        migrator.createAndSeedPool{value: ethForEthPool}(address(token), address(0), 0, tokensForEthPool, feeBps);
        emit Migrated(address(0), ethForEthPool, tokensForEthPool);

        uint256 classCoinAmount = pairCoin.mint{value: ethForClassPool}(0);
        IERC20(address(token)).safeIncreaseAllowance(address(migrator), tokensForClassPool);
        IERC20(address(pairCoin)).safeIncreaseAllowance(address(migrator), classCoinAmount);
        migrator.createAndSeedPool(address(token), address(pairCoin), classCoinAmount, tokensForClassPool, feeBps);
        emit Migrated(address(pairCoin), classCoinAmount, tokensForClassPool);
    }
}
