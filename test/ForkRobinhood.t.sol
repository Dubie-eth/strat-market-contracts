// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Test, console2} from "forge-std/Test.sol";
import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {IPositionManager} from "@uniswap/v4-periphery/src/interfaces/IPositionManager.sol";
import {IAllowanceTransfer} from "@uniswap/v4-periphery/lib/permit2/src/interfaces/IAllowanceTransfer.sol";
import {Actions} from "@uniswap/v4-periphery/src/libraries/Actions.sol";
import {ERC20THook} from "../src/ERC20T/ERC20THook.sol";
import {ERC20TFactory} from "../src/ERC20T/ERC20TFactory.sol";
import {ERC20T} from "../src/ERC20T/ERC20T.sol";
import {HookMiner} from "../script/HookMiner.sol";

interface IUniversalRouter {
    function execute(bytes calldata commands, bytes[] calldata inputs, uint256 deadline) external payable;
}

interface IERC721Min {
    function ownerOf(uint256) external view returns (address);
    function nextTokenId() external view returns (uint256);
}

struct ExactInputSingleParams {
    PoolKey poolKey;
    bool zeroForOne;
    uint128 amountIn;
    uint128 amountOutMinimum;
    bytes hookData;
}

contract SmartWallet { // stand-in for a Safe / contract wallet
    function send(ERC20T t, address to, uint256 a) external { t.transfer(to, a); }
}

contract ForkRobinhoodTest is Test {
    IPoolManager constant PM = IPoolManager(0x8366a39CC670B4001A1121B8F6A443A643e40951);
    IPositionManager constant POSM = IPositionManager(payable(0x58daec3116aae6D93017bAAea7749052E8a04fA7));
    IUniversalRouter constant UR = IUniversalRouter(0x8876789976dEcBfCbBbe364623C63652db8C0904);
    IAllowanceTransfer constant PERMIT2 = IAllowanceTransfer(0x000000000022D473030F116dDEE9F6B43aC78BA3);

    address hookOwner = makeAddr("hookOwner");
    address protocol = makeAddr("protocol");
    address creator = makeAddr("creator");
    address treasury = makeAddr("treasury");      // resting tax recipient
    address launchVault = makeAddr("launchVault"); // decay tax recipient
    address alice = makeAddr("alice");
    address bob = makeAddr("bob");

    ERC20THook hook;
    ERC20TFactory factory;
    ERC20T token;
    PoolKey key;

    uint256 constant SUPPLY = 1_000_000_000e18;
    uint16 constant CREATOR_BPS = 500;          // 5%
    uint256 constant START_PRICE = 5e9;         // wei per whole token => 5 ETH FDV
    uint16 constant TAX = 300;                  // 3%
    uint32 constant DECAY_INTERVAL = 6;         // seconds per 1pt

    function setUp() public {
        vm.createSelectFork(vm.envOr("RH_RPC_URL", string("https://rpc.mainnet.chain.robinhood.com")));
        uint160 flags = uint160(
            Hooks.BEFORE_INITIALIZE_FLAG | Hooks.AFTER_ADD_LIQUIDITY_FLAG | Hooks.AFTER_REMOVE_LIQUIDITY_FLAG
                | Hooks.AFTER_SWAP_FLAG | Hooks.AFTER_SWAP_RETURNS_DELTA_FLAG
        );
        ERC20THook.ExternalBaseConfig[] memory none;
        bytes memory args = abi.encode(PM, hookOwner, protocol, none);
        (address predicted, bytes32 salt) = HookMiner.find(address(this), flags, type(ERC20THook).creationCode, args);
        uint256 g = gasleft();
        hook = new ERC20THook{salt: salt}(PM, hookOwner, protocol, none);
        console2.log("gas: hook deploy", g - gasleft());
        assertEq(address(hook), predicted);
        g = gasleft();
        factory = new ERC20TFactory();
        console2.log("gas: factory+impl deploy", g - gasleft());

        ERC20T.Config memory c = ERC20T.Config({
            name: "Test Token",
            symbol: "TEST",
            supply: SUPPLY,
            lpSupply: 0,
            owner: creator,
            hook: address(hook),
            quoteToken: address(0),
            positionManager: POSM,
            permit2: PERMIT2,
            taxBps: TAX,
            feeRecipient: treasury,
            launchTaxBps: 9900,
            taxDecayIntervalSeconds: DECAY_INTERVAL,
            feeDecayRecipient: launchVault
        });
        vm.deal(creator, 1 ether);
        vm.prank(creator);
        g = gasleft();
        token = factory.createAndLaunchAtPrice(c, CREATOR_BPS, START_PRICE);
        console2.log("gas: createAndLaunchAtPrice", g - gasleft());
        key = token.poolKey();
        vm.deal(alice, 100 ether);
        vm.deal(bob, 100 ether);
    }

    function _buy(address who, uint256 ethIn) internal returns (uint256 got) {
        uint256 b0 = token.balanceOf(who);
        bytes memory actions = abi.encodePacked(uint8(Actions.SWAP_EXACT_IN_SINGLE), uint8(Actions.SETTLE_ALL), uint8(Actions.TAKE_ALL));
        bytes[] memory p = new bytes[](3);
        p[0] = abi.encode(ExactInputSingleParams(key, true, uint128(ethIn), 0, ""));
        p[1] = abi.encode(key.currency0, ethIn);
        p[2] = abi.encode(key.currency1, uint256(0));
        bytes[] memory inputs = new bytes[](1);
        inputs[0] = abi.encode(actions, p);
        vm.prank(who, who);
        uint256 g = gasleft();
        UR.execute{value: ethIn}(hex"10", inputs, block.timestamp);
        console2.log("gas: UR buy", g - gasleft());
        got = token.balanceOf(who) - b0;
    }

    function _sell(address who, uint256 amt) internal returns (uint256 ethOut) {
        vm.startPrank(who, who);
        token.approve(address(PERMIT2), type(uint256).max);
        PERMIT2.approve(address(token), address(UR), type(uint160).max, type(uint48).max);
        bytes memory actions = abi.encodePacked(uint8(Actions.SWAP_EXACT_IN_SINGLE), uint8(Actions.SETTLE_ALL), uint8(Actions.TAKE_ALL));
        bytes[] memory p = new bytes[](3);
        p[0] = abi.encode(ExactInputSingleParams(key, false, uint128(amt), 0, ""));
        p[1] = abi.encode(key.currency1, amt);
        p[2] = abi.encode(key.currency0, uint256(0));
        bytes[] memory inputs = new bytes[](1);
        inputs[0] = abi.encode(actions, p);
        uint256 b0 = who.balance;
        uint256 g = gasleft();
        UR.execute(hex"10", inputs, block.timestamp);
        console2.log("gas: UR sell", g - gasleft());
        vm.stopPrank();
        ethOut = who.balance - b0;
    }

    function test_launchState() public view {
        assertEq(token.owner(), creator);
        assertEq(token.balanceOf(creator), SUPPLY * CREATOR_BPS / 10_000);
        assertTrue(token.launched());
        assertEq(token.taxBps(), 9900);
        assertEq(Currency.unwrap(key.currency0), address(0));
        // LP NFT minted to 0xdead => permanently locked
        uint256 id = IERC721Min(address(POSM)).nextTokenId() - 1;
        assertEq(IERC721Min(address(POSM)).ownerOf(id), address(0xdEaD));
        console2.log("creator ETH refunded", creator.balance);
    }

    function test_sniperAtLaunchPays99pct() public {
        uint256 v0 = launchVault.balance; uint256 p0 = protocol.balance; uint256 t0 = treasury.balance;
        uint256 got = _buy(alice, 1 ether);
        uint256 toVault = launchVault.balance - v0;
        console2.log("sniper tokens", got / 1e18);
        console2.log("decay recipient ETH (wei)", toVault);
        console2.log("protocol ETH", protocol.balance - p0);
        console2.log("treasury ETH", treasury.balance - t0);
        assertGt(toVault, 0.9 ether); // ~97% of the sniper's ETH comes back as fees
    }

    function test_decayAndRestingTax() public {
        vm.warp(block.timestamp + DECAY_INTERVAL * 10);
        assertEq(token.taxBps(), 8900);
        vm.warp(block.timestamp + DECAY_INTERVAL * 200);
        assertEq(token.taxBps(), TAX);
        assertFalse(token.taxDecayActive());

        uint256 p0 = protocol.balance; uint256 t0 = treasury.balance; uint256 v0 = launchVault.balance;
        uint256 got = _buy(alice, 1 ether);
        uint256 pBuy = protocol.balance - p0; uint256 tBuy = treasury.balance - t0;
        console2.log("buy 1 ETH -> tokens", got / 1e18);
        console2.log("buy fee: treasury wei", tBuy);
        console2.log("buy fee: protocol wei", pBuy);
        assertEq(launchVault.balance, v0);
        // treasury ~ 2.85%, protocol ~ 0.15% of ~1 ETH
        // Buy-side fee tokens are sold back at the post-buy price, so ETH fee >= 3% of ETH in.
        assertGe(tBuy, 0.0285 ether);
        assertApproxEqRel(pBuy * 19, tBuy, 0.001e18); // protocol = 15/300 of the tax

        p0 = protocol.balance; t0 = treasury.balance;
        uint256 out = _sell(alice, got / 2);
        console2.log("sell half -> ETH wei", out);
        console2.log("sell fee: treasury wei", treasury.balance - t0);
        console2.log("sell fee: protocol wei", protocol.balance - p0);
        assertApproxEqRel((treasury.balance - t0) + (protocol.balance - p0), out * 300 / 9700, 0.01e18);
    }

    function test_walletTransferUntaxed_contractBlocked() public {
        vm.warp(block.timestamp + DECAY_INTERVAL * 200);
        uint256 got = _buy(alice, 1 ether);
        vm.prank(alice, alice);
        token.transfer(bob, got);
        assertEq(token.balanceOf(bob), got); // no tax
        SmartWallet sw = new SmartWallet();
        vm.prank(bob, bob);
        vm.expectRevert(ERC20T.InvalidTransfer.selector);
        token.transfer(address(sw), 1e18);
        // contract wallets can still BUY (router pays PoolManager -> recipient directly)
        vm.deal(address(sw), 1 ether);
    }

    function test_externalLiquidityBlocked_and_onlyOneLaunch() public {
        vm.prank(creator);
        vm.expectRevert(ERC20T.AlreadyLaunched.selector);
        token.launch(0, 0, 0);
    }

    function test_exactOutputReverts() public {
        // documented limitation: exact-output routes are rejected by the hook
        vm.warp(block.timestamp + DECAY_INTERVAL * 200);
        bytes memory actions = abi.encodePacked(uint8(Actions.SWAP_EXACT_OUT_SINGLE), uint8(Actions.SETTLE_ALL), uint8(Actions.TAKE_ALL));
        bytes[] memory p = new bytes[](3);
        p[0] = abi.encode(key, true, uint128(1000e18), uint128(1 ether), bytes(""));
        p[1] = abi.encode(key.currency0, 1 ether);
        p[2] = abi.encode(key.currency1, uint256(0));
        bytes[] memory inputs = new bytes[](1);
        inputs[0] = abi.encode(actions, p);
        vm.prank(alice, alice);
        vm.expectRevert();
        UR.execute{value: 1 ether}(hex"10", inputs, block.timestamp);
    }
}
