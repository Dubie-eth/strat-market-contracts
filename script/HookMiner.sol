// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

/// @notice Minimal CREATE2 salt miner for v4 hook permission bits (same approach as v4-periphery HookMiner).
library HookMiner {
    uint160 internal constant FLAG_MASK = (1 << 14) - 1;

    function find(address deployer, uint160 flags, bytes memory creationCode, bytes memory constructorArgs)
        internal
        pure
        returns (address hookAddress, bytes32 salt)
    {
        bytes32 initHash = keccak256(abi.encodePacked(creationCode, constructorArgs));
        for (uint256 i; i < 500_000; ++i) {
            salt = bytes32(i);
            hookAddress = address(uint160(uint256(keccak256(abi.encodePacked(bytes1(0xff), deployer, salt, initHash)))));
            if (uint160(hookAddress) & FLAG_MASK == flags) return (hookAddress, salt);
        }
        revert("HookMiner: no salt");
    }
}
