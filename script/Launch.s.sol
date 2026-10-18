// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Script, console2} from "forge-std/Script.sol";
import {IPositionManager} from "@uniswap/v4-periphery/src/interfaces/IPositionManager.sol";
import {IAllowanceTransfer} from "@uniswap/v4-periphery/lib/permit2/src/interfaces/IAllowanceTransfer.sol";
import {ERC20T} from "../src/ERC20T/ERC20T.sol";
import {ERC20TFactory} from "../src/ERC20T/ERC20TFactory.sol";

/// @notice Launches one ERC20T on our factory/hook, paired with native ETH.
/// env: FACTORY, HOOK, TOKEN_OWNER, FEE_RECIPIENT, FEE_DECAY_RECIPIENT, TOKEN_NAME, TOKEN_SYMBOL,
///      SUPPLY_WHOLE (default 1e9), CREATOR_BPS (default 500), TAX_BPS (default 300),
///      DECAY_INTERVAL (default 10), START_PRICE_WEI (wei per whole token, default 5e9 = 5 ETH FDV)
contract Launch is Script {
    IPositionManager constant POSM = IPositionManager(payable(0x58daec3116aae6D93017bAAea7749052E8a04fA7));
    IAllowanceTransfer constant PERMIT2 = IAllowanceTransfer(0x000000000022D473030F116dDEE9F6B43aC78BA3);

    function run() external returns (ERC20T token) {
        require(block.chainid == 4663, "not Robinhood Chain");
        ERC20TFactory factory = ERC20TFactory(payable(vm.envAddress("FACTORY")));
        ERC20T.Config memory c = ERC20T.Config({
            name: vm.envString("TOKEN_NAME"),
            symbol: vm.envString("TOKEN_SYMBOL"),
            supply: vm.envOr("SUPPLY_WHOLE", uint256(1_000_000_000)) * 1e18,
            lpSupply: 0,
            owner: vm.envAddress("TOKEN_OWNER"),
            hook: vm.envAddress("HOOK"),
            quoteToken: address(0),
            positionManager: POSM,
            permit2: PERMIT2,
            taxBps: uint16(vm.envOr("TAX_BPS", uint256(300))),
            feeRecipient: vm.envAddress("FEE_RECIPIENT"),
            launchTaxBps: 9900,
            taxDecayIntervalSeconds: uint32(vm.envOr("DECAY_INTERVAL", uint256(10))),
            feeDecayRecipient: vm.envAddress("FEE_DECAY_RECIPIENT")
        });
        uint16 creatorBps = uint16(vm.envOr("CREATOR_BPS", uint256(500)));
        uint256 price = vm.envOr("START_PRICE_WEI", uint256(5e9));
        ERC20TFactory.LaunchPreview memory pv = factory.previewLaunch(c.supply, creatorBps, price);
        console2.log("creatorSupply", pv.creatorSupply / 1e18);
        console2.log("lpSupply", pv.lpSupply / 1e18);
        console2.log("effectivePriceWei", pv.effectivePriceWei);
        vm.startBroadcast();
        token = factory.createAndLaunchAtPrice(c, creatorBps, price); // no ETH needed: single-sided token LP
        vm.stopBroadcast();
        console2.log("token", address(token));
    }
}
