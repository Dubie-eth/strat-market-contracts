// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;
import {Test, console2} from "forge-std/Test.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";

interface IMR {
    function swapETHForToken(address,uint256,uint256) external payable returns (uint256);
    function swapTokenForETH(address,uint256,uint256,uint256) external returns (uint256);
    function unlockCallback(bytes calldata) external returns (bytes memory);
    function verifyFactoryToken(address) external view returns (bool);
}
interface ISR {
    function swapETHForSTRATM(PoolKey calldata,uint256,uint256) external payable returns (uint256);
    function swapSTRATMForETH(PoolKey calldata,uint256,uint256,uint256) external returns (uint256);
    function unlockCallback(bytes calldata) external returns (bytes memory);
}
interface IT {
    function balanceOf(address) external view returns (uint256);
    function approve(address,uint256) external returns (bool);
    function transfer(address,uint256) external returns (bool);
    function owner() external view returns (address);
}
contract FakeToken { address public hook; constructor(address h){hook=h;} }
contract Attacker {
    function tryUnlock(IPoolManager pm) external { pm.unlock(""); }
    function unlockCallback(bytes calldata) external returns (bytes memory) {
        // attempt to make router act inside our unlock
        IMR(0x0fA032e55f1E4a4c33542B961a662bf1059a0ec0).unlockCallback(hex"00");
        return "";
    }
}

contract AuditLive is Test {
    address constant T = 0xABCC6e05718543faB52b16d7086D3FD32f0063B3;
    address constant H = 0xf43C7cC459A9430093f06b081f672F27e103a544;
    IPoolManager constant PM = IPoolManager(0x8366a39CC670B4001A1121B8F6A443A643e40951);
    IMR constant MR = IMR(0x0fA032e55f1E4a4c33542B961a662bf1059a0ec0);
    ISR constant SR = ISR(0xB5b4E183671caC499dF7cF0bccc10942e8D2B448);
    address constant TREAS = 0x80751aC15219F8495d9E46acd9c6F5f0e03291fB;
    address user = address(0xBEEF01);
    address victim = address(0xBEEF02);

    function setUp() public { vm.createSelectFork("https://rpc.mainnet.chain.robinhood.com"); vm.deal(user, 100 ether); vm.deal(victim, 100 ether); }
    function key() internal pure returns (PoolKey memory) { return PoolKey(Currency.wrap(address(0)), Currency.wrap(T), 0, 60, IHooks(H)); }

    function _buy(address who, uint256 v) internal returns (uint256 out) { vm.prank(who, who); out = MR.swapETHForToken{value: v}(T, 0, block.timestamp); }

    function test_buySellRoundtrip() public {
        uint256 t0 = TREAS.balance;
        uint256 out = _buy(user, 0.01 ether);
        console2.log("tokens for 0.01 ETH", out);
        console2.log("treasury gained on buy (router+tax)", TREAS.balance - t0);
        vm.startPrank(user, user); IT(T).approve(address(MR), out);
        uint256 e = MR.swapTokenForETH(T, out, 0, block.timestamp); vm.stopPrank();
        console2.log("ETH back", e);
        assertEq(address(MR).balance, 0);
    }
    function test_tinyBuy() public { uint256 out = _buy(user, 1000); console2.log("tiny out", out); }
    function test_hugeBuy() public { uint256 out = _buy(user, 50 ether); console2.log("50 ETH out", out); assertEq(address(MR).balance, 0); }
    function test_slippageRevert() public { vm.prank(user,user); vm.expectRevert(); MR.swapETHForToken{value: 0.01 ether}(T, type(uint256).max, block.timestamp); }
    function test_deadlineRevert() public { vm.prank(user,user); vm.expectRevert(); MR.swapETHForToken{value: 0.01 ether}(T, 0, block.timestamp - 1); }
    function test_directUnlockCallbackReverts() public { vm.expectRevert(); MR.unlockCallback(""); vm.expectRevert(); SR.unlockCallback(""); }
    function test_nestedUnlockAttack() public { Attacker a = new Attacker(); vm.expectRevert(); a.tryUnlock(PM); }
    function test_cannotSellVictimsApprovedTokens() public {
        uint256 out = _buy(victim, 0.01 ether);
        vm.prank(victim, victim); IT(T).approve(address(MR), type(uint256).max);
        vm.prank(victim, victim); IT(T).approve(address(SR), type(uint256).max);
        // attacker holds nothing; router always pulls from msg.sender
        vm.prank(user, user); vm.expectRevert(); MR.swapTokenForETH(T, out, 0, block.timestamp);
        vm.prank(user, user); vm.expectRevert(); SR.swapSTRATMForETH(key(), out, 0, block.timestamp);
        assertEq(IT(T).balanceOf(victim), out);
    }
    function test_fakeTokenPassesVerify() public { FakeToken f = new FakeToken(H); console2.log("fake verified?", MR.verifyFactoryToken(address(f))); vm.prank(user,user); vm.expectRevert(); MR.swapETHForToken{value: 0.01 ether}(address(f),0,block.timestamp); }
    function test_strayEthStuckInSwapRouter() public { vm.prank(user); (bool ok,) = address(SR).call{value: 1 ether}(""); console2.log("SR accepted stray ETH", ok); console2.log("SR bal", address(SR).balance); }
    function test_swapRouterBuySell() public {
        vm.prank(user,user); uint256 out = SR.swapETHForSTRATM{value: 0.01 ether}(key(), 0, block.timestamp);
        vm.startPrank(user,user); IT(T).approve(address(SR), out); uint256 e = SR.swapSTRATMForETH(key(), out, 0, block.timestamp); vm.stopPrank();
        console2.log("SR roundtrip ETH back", e);
    }
    function test_contractWalletCannotSell() public {
        uint256 out = _buy(user, 0.01 ether);
        address sw = address(new FakeToken(address(0)));
        vm.prank(user,user); vm.expectRevert(); IT(T).transfer(sw, out);
    }
}
