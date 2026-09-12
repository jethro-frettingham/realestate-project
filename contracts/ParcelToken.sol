// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

/// @title ParcelToken
/// @notice The ERC20 minted for a single launch. Fixed supply, minted once
///         to `Launchpad` at creation — there is no further mint function.
///         Holders earn a pull-based share of the market's trading fees:
///         `Launchpad.collectFees` pushes the holder-reward cut in here via
///         `notifyRewardAmount`, and any holder calls `claimRewards()` to
///         withdraw their accrued share. Standard fee-per-share accounting
///         (the same pattern used by staking/dividend tokens), so the cost
///         of a payout is O(1) regardless of holder count — no off-chain
///         indexer or keeper enumerating balances.
/// @dev Reference implementation. Unaudited.
contract ParcelToken is ERC20 {
    using SafeERC20 for IERC20;

    uint256 public constant TOTAL_SUPPLY = 1_000_000_000 ether;
    uint256 private constant PRECISION = 1e18;

    address public immutable launchpad;
    address public immutable quoteAsset; // address(0) = ETH

    // Balances that don't represent a real economic holder for reward
    // purposes: unsold supply sitting in the Uniswap v4 pool (custodied by
    // the singleton PoolManager) and any transient balance on Launchpad
    // itself mid-transaction. Mirrors CME's own exclusion of "the pool"
    // and "the launchpad" from holder payouts — without this, unsold
    // inventory would dilute every real holder's share.
    address public immutable excludedPoolManager;

    uint256 public rewardPerTokenStored;
    mapping(address => uint256) public rewardDebt;
    mapping(address => uint256) public rewards;

    event RewardAdded(uint256 amount);
    event RewardClaimed(address indexed who, uint256 amount);

    /// @param name_        Market name, e.g. "Nana's Storage Shed"
    /// @param symbol_      Market ticker, e.g. "NANASHED"
    /// @param launchpad_   The Launchpad contract that receives the full supply
    /// @param quoteAsset_  What the market trades against; address(0) for ETH
    /// @param poolManager_ The Uniswap v4 PoolManager, excluded from rewards
    constructor(string memory name_, string memory symbol_, address launchpad_, address quoteAsset_, address poolManager_)
        ERC20(name_, symbol_)
    {
        launchpad = launchpad_;
        quoteAsset = quoteAsset_;
        excludedPoolManager = poolManager_;
        _mint(launchpad_, TOTAL_SUPPLY);
    }

    /// @notice Adds `amount` of `quoteAsset` to the reward pool. Caller
    ///         must have already transferred it in: ETH via msg.value, or
    ///         (for an ERC20 quote asset) via a prior transferFrom this
    ///         function performs itself against `launchpad`.
    function notifyRewardAmount(uint256 amount) external payable {
        require(msg.sender == launchpad, "ParcelToken: not launchpad");
        if (quoteAsset == address(0)) {
            require(msg.value == amount, "ParcelToken: bad value");
        } else {
            require(msg.value == 0, "ParcelToken: no eth expected");
            if (amount > 0) IERC20(quoteAsset).safeTransferFrom(launchpad, address(this), amount);
        }
        uint256 supply = totalSupply();
        if (amount > 0 && supply > 0) {
            rewardPerTokenStored += amount * PRECISION / supply;
            emit RewardAdded(amount);
        }
    }

    /// @notice Pays out the caller's accrued reward share.
    function claimRewards() external returns (uint256 amount) {
        _accrue(msg.sender);
        amount = rewards[msg.sender];
        if (amount == 0) return 0;
        rewards[msg.sender] = 0;
        if (quoteAsset == address(0)) {
            (bool sent, ) = msg.sender.call{value: amount}("");
            require(sent, "ParcelToken: ETH transfer failed");
        } else {
            IERC20(quoteAsset).safeTransfer(msg.sender, amount);
        }
        emit RewardClaimed(msg.sender, amount);
    }

    /// @notice View helper: what `claimRewards()` would currently pay out.
    function earned(address account) external view returns (uint256) {
        if (account == address(0) || account == excludedPoolManager) return rewards[account];
        return rewards[account] + balanceOf(account) * (rewardPerTokenStored - rewardDebt[account]) / PRECISION;
    }

    function _accrue(address account) internal {
        if (account == address(0) || account == excludedPoolManager) return;
        uint256 owed = balanceOf(account) * (rewardPerTokenStored - rewardDebt[account]) / PRECISION;
        if (owed > 0) rewards[account] += owed;
        rewardDebt[account] = rewardPerTokenStored;
    }

    function _update(address from, address to, uint256 value) internal override {
        _accrue(from);
        _accrue(to);
        super._update(from, to, value);
    }

    // Accepts the ETH `notifyRewardAmount` forwards in as msg.value, and
    // nothing else — there's no other path that should send this contract
    // ETH directly.
    receive() external payable {
        require(msg.sender == launchpad, "ParcelToken: direct ETH not accepted");
    }
}
