// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "@openzeppelin/contracts/token/ERC20/ERC20.sol";

/// @title LiveClassCoin
/// @notice The coin for a live-tier property class (one with a genuine,
///         if infrequently-published, reference index — housing, farmland,
///         RVs, and similar). Unlike the static `PropertyClassCoin`, this
///         is not collateral-backed 1:1: its supply is minted and burned
///         exclusively by its `PegPool`, which is the only place its price
///         is discovered (a single-sided Uniswap v4 ask position, repriced
///         when the reference index updates). There is no direct mint/
///         redeem-at-a-fixed-rate here — that's exactly the mechanism a
///         mutable-rate coin can't safely offer (see PegPool.sol's
///         top comment for why).
/// @dev Reference implementation. Unaudited.
contract LiveClassCoin is ERC20 {
    address public immutable pegPool;
    string public classTicker;

    constructor(string memory name_, string memory symbol_, address pegPool_) ERC20(name_, symbol_) {
        pegPool = pegPool_;
        classTicker = symbol_;
    }

    function mint(address to, uint256 amount) external {
        require(msg.sender == pegPool, "LiveClassCoin: not pegPool");
        _mint(to, amount);
    }

    function burn(address from, uint256 amount) external {
        require(msg.sender == pegPool, "LiveClassCoin: not pegPool");
        _burn(from, amount);
    }
}
