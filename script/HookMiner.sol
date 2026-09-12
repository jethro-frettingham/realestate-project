// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/// @title HookMiner
/// @notice Finds a CREATE2 salt that gives a hook contract's address the
///         exact low-bit flags Uniswap v4 requires. This repo vendors
///         v4-core only, not v4-periphery (where the standard HookMiner
///         utility normally lives), so this is a local reimplementation
///         of the same well-known algorithm, script-only — not part of
///         any deployed contract's bytecode.
/// @dev `deployer` must be the actual account that will execute the
///      CREATE2 — for a `new X{salt: s}(...)` inside a broadcasted forge
///      script, that's the canonical deterministic-deployment proxy
///      (0x4e59b44847b379578588920cA78FbF26c0B4956C), which `forge script
///      --broadcast` deploys automatically if the target chain doesn't
///      already have it. Verify that's true for the target chain before
///      relying on this in a real deploy.
library HookMiner {
    uint160 internal constant FLAG_MASK = uint160((1 << 14) - 1);
    uint256 internal constant MAX_LOOP = 200_000;

    function find(address deployer, uint160 flags, bytes memory creationCode, bytes memory constructorArgs)
        internal
        pure
        returns (address hookAddress, bytes32 salt)
    {
        bytes memory initCode = abi.encodePacked(creationCode, constructorArgs);
        bytes32 initCodeHash = keccak256(initCode);
        for (uint256 i; i < MAX_LOOP; i++) {
            salt = bytes32(i);
            hookAddress = computeAddress(deployer, salt, initCodeHash);
            if (uint160(hookAddress) & FLAG_MASK == flags) {
                return (hookAddress, salt);
            }
        }
        revert("HookMiner: could not find salt");
    }

    function computeAddress(address deployer, bytes32 salt, bytes32 initCodeHash) internal pure returns (address) {
        return address(uint160(uint256(keccak256(abi.encodePacked(bytes1(0xff), deployer, salt, initCodeHash)))));
    }
}
