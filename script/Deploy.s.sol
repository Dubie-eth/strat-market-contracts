// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Script, console2} from "forge-std/Script.sol";
import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {ERC20THook} from "../src/ERC20T/ERC20THook.sol";
import {ERC20TFactory} from "../src/ERC20T/ERC20TFactory.sol";
import {HookMiner} from "./HookMiner.sol";

/// @notice Deploys ERC20THook (CREATE2, mined flags) + ERC20TFactory (which deploys the ERC20T impl) on Robinhood Chain.
/// env: HOOK_OWNER, PROTOCOL_FEE_RECIPIENT. Native ETH (address(0)) is the built-in quote; no external bases registered.
contract Deploy is Script {
    address constant POOL_MANAGER = 0x8366a39CC670B4001A1121B8F6A443A643e40951; // Robinhood Chain v4
    address constant CREATE2_DEPLOYER = 0x4e59b44847b379578588920cA78FbF26c0B4956C;
    uint160 constant FLAGS = uint160(
        Hooks.BEFORE_INITIALIZE_FLAG | Hooks.AFTER_ADD_LIQUIDITY_FLAG | Hooks.AFTER_REMOVE_LIQUIDITY_FLAG
            | Hooks.AFTER_SWAP_FLAG | Hooks.AFTER_SWAP_RETURNS_DELTA_FLAG
    );

    function run() external returns (ERC20THook hook, ERC20TFactory factory) {
        require(block.chainid == 4663, "not Robinhood Chain");
        address owner_ = vm.envAddress("HOOK_OWNER");
        address protocol_ = vm.envAddress("PROTOCOL_FEE_RECIPIENT");
        (hook, factory) = deploy(owner_, protocol_);
    }

    function deploy(address owner_, address protocol_) public returns (ERC20THook hook, ERC20TFactory factory) {
        bytes memory args =
            abi.encode(IPoolManager(POOL_MANAGER), owner_, protocol_, new ERC20THook.ExternalBaseConfig[](0));
        (address predicted, bytes32 salt) =
            HookMiner.find(CREATE2_DEPLOYER, FLAGS, type(ERC20THook).creationCode, args);
        vm.startBroadcast();
        hook = new ERC20THook{salt: salt}(IPoolManager(POOL_MANAGER), owner_, protocol_, new ERC20THook.ExternalBaseConfig[](0));
        factory = new ERC20TFactory();
        vm.stopBroadcast();
        require(address(hook) == predicted, "hook address mismatch");
        console2.log("hook", address(hook));
        console2.log("salt");
        console2.logBytes32(salt);
        console2.log("factory", address(factory));
        console2.log("implementation", factory.implementation());
    }
}
