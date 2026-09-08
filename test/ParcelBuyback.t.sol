// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "forge-std/Test.sol";
import "../contracts/ParcelBuyback.sol";

contract ParcelBuybackTest is Test {
    ParcelBuyback buyback;
    address deployer = address(0xD30);
    address sender = address(0x5E4D);

    function setUp() public {
        buyback = new ParcelBuyback(deployer);
        vm.deal(sender, 10 ether);
    }

    function test_mintsFixedSupplyToDeployerOnly() public view {
        assertEq(buyback.totalSupply(), buyback.TOTAL_SUPPLY());
        assertEq(buyback.balanceOf(deployer), buyback.TOTAL_SUPPLY());
    }

    function test_receivingEthQueuesItForBuyback() public {
        vm.prank(sender);
        (bool sent, ) = address(buyback).call{value: 1 ether}("");
        assertTrue(sent);

        assertEq(buyback.totalReceived(), 1 ether);
        assertEq(buyback.queuedForBuyback(), 1 ether);
    }

    function test_attemptBuybackDoesNotBurnOnTestnet() public {
        vm.prank(sender);
        (bool sent, ) = address(buyback).call{value: 1 ether}("");
        assertTrue(sent);

        uint256 supplyBefore = buyback.totalSupply();
        buyback.attemptBuyback();

        // Nothing is burned — there's no live pool to swap through — the
        // queued balance stays exactly where it was, honestly unresolved.
        assertEq(buyback.totalSupply(), supplyBefore);
        assertEq(buyback.queuedForBuyback(), 1 ether);
    }
}
