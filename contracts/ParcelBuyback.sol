// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import "@openzeppelin/contracts/token/ERC20/extensions/ERC20Burnable.sol";

/// @title ParcelBuyback
/// @notice The $PARCEL token, and the treasury every BondingCurve sweeps its
///         30% buyback fee share into (via `sweepBuybackFees()` on each
///         curve — anyone can call it, funds always land here).
///
///         What this contract does NOT do, on purpose: it does not swap the
///         ETH it holds for $PARCEL and burn it. A real buyback needs a live
///         $PARCEL/ETH pool to swap through, and none exists yet on
///         testnet — there's nothing to buy $PARCEL from. `attemptBuyback()`
///         is here as the hook a real implementation would fill in (find a
///         pool, swap, burn), but today it just moves the ETH into a
///         separately-tracked `queuedForBuyback` balance and emits an event,
///         so the amount that *should* have been burned is visible on chain
///         even though nothing is burned yet.
/// @dev Reference implementation for the Parcel demo. Unaudited. Fixed
///      supply, minted once to the deployer at creation — no further mint
///      function exists.
contract ParcelBuyback is ERC20, ERC20Burnable {
    uint256 public constant TOTAL_SUPPLY = 1_000_000_000 ether;

    uint256 public queuedForBuyback;
    uint256 public totalReceived;

    event FeesReceived(address indexed from, uint256 amount);
    event BuybackAttempted(uint256 amountQueued, string reason);

    constructor(address initialHolder) ERC20("Parcel", "PARCEL") {
        _mint(initialHolder, TOTAL_SUPPLY);
    }

    receive() external payable {
        totalReceived += msg.value;
        queuedForBuyback += msg.value;
        emit FeesReceived(msg.sender, msg.value);
    }

    /// @notice Anyone can call this. On testnet it's a no-op beyond logging,
    ///         since there's no pool to swap through yet — see the contract
    ///         note above. A production version would swap `queuedForBuyback`
    ///         ETH for $PARCEL here and burn what it receives.
    function attemptBuyback() external {
        emit BuybackAttempted(queuedForBuyback, "no live PARCEL/ETH pool on this network yet");
    }
}
