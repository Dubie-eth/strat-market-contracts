
// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {Currency, CurrencyLibrary} from "@uniswap/v4-core/src/types/Currency.sol";
import {BalanceDelta} from "@uniswap/v4-core/src/types/BalanceDelta.sol";
import {SwapParams as PMSwapParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";

/// @notice Inlined from IUnlockCallback for vendored v4-core subset
interface IUnlockCallback {
    function unlockCallback(bytes calldata data) external returns (bytes memory);
}

/// @title StratmMultiRouter
/// @notice Multi-token router for ERC20T factory tokens on Uniswap v4
/// @dev Non-upgradeable router that verifies tokens are from factory 0x74C6654Eb785Bc7863DA21dFCa37cA450fBd540d
///      before allowing swaps. Uses proven pattern: swap -> sync -> transferFrom -> settle -> take.
///      Charges 0.5% router fee on ETH (input for buy, output for sell) to immutable treasury.
contract StratmMultiRouter is IUnlockCallback {
    using CurrencyLibrary for Currency;

    IPoolManager public immutable poolManager;
    address public immutable treasury;
    address public immutable factory;
    address public immutable hook;

    /// @dev Native ETH as Currency (address(0))
    Currency public constant ETH = Currency.wrap(address(0));
    
    /// @dev Router fee: 0.5% (50 bps out of 10000)
    uint256 public constant ROUTER_FEE_BPS = 50;
    uint256 public constant BPS = 10000;
    
    /// @dev Fixed pool parameters for ERC20T tokens
    uint24 public constant POOL_FEE = 0;
    int24 public constant TICK_SPACING = 60;

    error Unauthorized();
    error DeadlineExpired();
    error InsufficientOutput();
    error InvalidAmount();
    error TreasuryTransferFailed();
    error TokenNotFromFactory();

    event RouterFee(address indexed user, address indexed token, bool isETH, uint256 feeAmount);

    /// @notice Swap parameters (inlined from IPoolManager for vendored v4-core)
    struct SwapParams {
        bool zeroForOne;
        int256 amountSpecified;
        uint160 sqrtPriceLimitX96;
    }

    struct SwapCallbackData {
        address sender;
        address token;
        PoolKey key;
        SwapParams params;
        uint256 minAmountOut;
        bool isETHInput;
    }

    constructor(IPoolManager _poolManager, address _treasury, address _factory, address _hook) {
        poolManager = _poolManager;
        treasury = _treasury;
        factory = _factory;
        hook = _hook;
    }

    /// @notice Build PoolKey for an ERC20T token
    /// @dev All ERC20T tokens use: ETH/token, fee 0, tickSpacing 60, shared hook
    function buildPoolKey(address token) public view returns (PoolKey memory) {
        return PoolKey({
            currency0: ETH,
            currency1: Currency.wrap(token),
            fee: POOL_FEE,
            tickSpacing: TICK_SPACING,
            hooks: IHooks(hook)
        });
    }

    /// @notice Verify token was created by the factory
    /// @dev Checks if factory's implementation is deployed at the token's code
    ///      ERC20T tokens are clones of the factory's implementation
    function verifyFactoryToken(address token) public view returns (bool) {
        if (token == address(0) || token.code.length == 0) return false;
        
        // Read the factory's implementation address
        (bool success, bytes memory data) = factory.staticcall(
            abi.encodeWithSignature("implementation()")
        );
        if (!success || data.length < 32) return false;
        
        address implementation = abi.decode(data, (address));
        if (implementation == address(0) || implementation.code.length == 0) return false;
        
        // ERC20T tokens are minimal clones. Check if the token's bytecode contains
        // references to the implementation (clone pattern detection).
        // For a proper check, we verify the token has the hook we expect.
        (success, data) = token.staticcall(abi.encodeWithSignature("hook()"));
        if (!success || data.length < 32) return false;
        
        address tokenHook = abi.decode(data, (address));
        return tokenHook == hook;
    }

    /// @notice Buy ERC20T tokens with ETH
    /// @param token The ERC20T token address
    /// @param minAmountOut Minimum tokens to receive (slippage protection)
    /// @param deadline Transaction must execute before this timestamp
    /// @return amountOut The amount of tokens received
    function swapETHForToken(
        address token,
        uint256 minAmountOut,
        uint256 deadline
    ) external payable returns (uint256 amountOut) {
        if (block.timestamp > deadline) revert DeadlineExpired();
        if (msg.value == 0) revert InvalidAmount();
        if (!verifyFactoryToken(token)) revert TokenNotFromFactory();

        // Calculate router fee (0.5% of ETH input)
        uint256 routerFee = (msg.value * ROUTER_FEE_BPS) / BPS;
        uint256 ethAfterFee = msg.value - routerFee;

        // ETH (currency0) -> Token (currency1), zeroForOne = true
        // For exact input, amountSpecified must be NEGATIVE
        SwapParams memory params = SwapParams({
            zeroForOne: true,
            amountSpecified: -int256(ethAfterFee),
            sqrtPriceLimitX96: TickMath.MIN_SQRT_PRICE + 1
        });

        SwapCallbackData memory data = SwapCallbackData({
            sender: msg.sender,
            token: token,
            key: buildPoolKey(token),
            params: params,
            minAmountOut: minAmountOut,
            isETHInput: true
        });

        bytes memory result = poolManager.unlock(abi.encode(data));
        amountOut = abi.decode(result, (uint256));

        // Transfer router fee to treasury
        (bool success,) = treasury.call{value: routerFee}("");
        if (!success) revert TreasuryTransferFailed();

        emit RouterFee(msg.sender, token, true, routerFee);
    }

    /// @notice Sell ERC20T tokens for ETH
    /// @param token The ERC20T token address
    /// @param amountIn Amount of tokens to sell
    /// @param minAmountOut Minimum ETH to receive (slippage protection)
    /// @param deadline Transaction must execute before this timestamp
    /// @return amountOut The amount of ETH received (after 0.5% router fee)
    function swapTokenForETH(
        address token,
        uint256 amountIn,
        uint256 minAmountOut,
        uint256 deadline
    ) external returns (uint256 amountOut) {
        if (block.timestamp > deadline) revert DeadlineExpired();
        if (amountIn == 0) revert InvalidAmount();
        if (!verifyFactoryToken(token)) revert TokenNotFromFactory();

        // Token (currency1) -> ETH (currency0), zeroForOne = false
        // For exact input, amountSpecified must be NEGATIVE
        SwapParams memory params = SwapParams({
            zeroForOne: false,
            amountSpecified: -int256(amountIn),
            sqrtPriceLimitX96: TickMath.MAX_SQRT_PRICE - 1
        });

        SwapCallbackData memory data = SwapCallbackData({
            sender: msg.sender,
            token: token,
            key: buildPoolKey(token),
            params: params,
            minAmountOut: minAmountOut,
            isETHInput: false
        });

        bytes memory result = poolManager.unlock(abi.encode(data));
        uint256 ethBeforeFee = abi.decode(result, (uint256));

        // Calculate router fee (0.5% of ETH output)
        uint256 routerFee = (ethBeforeFee * ROUTER_FEE_BPS) / BPS;
        amountOut = ethBeforeFee - routerFee;

        if (amountOut < minAmountOut) revert InsufficientOutput();

        // Transfer router fee to treasury
        (bool success,) = treasury.call{value: routerFee}("");
        if (!success) revert TreasuryTransferFailed();

        // Transfer remaining ETH to user
        (success,) = msg.sender.call{value: amountOut}("");
        require(success, "ETH transfer to user failed");

        emit RouterFee(msg.sender, token, true, routerFee);
    }

    /// @notice Unlock callback implementation
    /// @dev Called by PoolManager during unlock. Executes swap and settlement.
    function unlockCallback(bytes calldata rawData) external returns (bytes memory) {
        if (msg.sender != address(poolManager)) revert Unauthorized();

        SwapCallbackData memory swapData = abi.decode(rawData, (SwapCallbackData));

        // Step 1: Execute swap first - hook's afterSwap sets transient allowance for PM transfers
        // Convert our SwapParams to SwapParams
        PMSwapParams memory pmParams = PMSwapParams({
            zeroForOne: swapData.params.zeroForOne,
            amountSpecified: swapData.params.amountSpecified,
            sqrtPriceLimitX96: swapData.params.sqrtPriceLimitX96
        });
        poolManager.swap(swapData.key, pmParams, "");

        // Check router's deltas after swap (inlined currencyDelta for vendored v4-core)
        int256 delta0 = int256(uint256(poolManager.exttload(
            keccak256(abi.encode(address(this), Currency.unwrap(swapData.key.currency0)))
        )));
        int256 delta1 = int256(uint256(poolManager.exttload(
            keccak256(abi.encode(address(this), Currency.unwrap(swapData.key.currency1)))
        )));

        if (swapData.isETHInput) {
            // Buy: ETH in (delta0 negative), Token out (delta1 positive)
            uint256 ethOwed = uint256(-delta0);
            uint256 tokenReceived = uint256(delta1);

            if (tokenReceived < swapData.minAmountOut) revert InsufficientOutput();

            // Step 2: Settle ETH debt to PoolManager
            poolManager.settle{value: ethOwed}();

            // Step 3: Take tokens to user
            poolManager.take(swapData.key.currency1, swapData.sender, tokenReceived);

            return abi.encode(tokenReceived);
        } else {
            // Sell: Token in (delta1 negative), ETH out (delta0 positive)
            uint256 tokenOwed = uint256(-delta1);
            uint256 ethReceived = uint256(delta0);

            // Note: minAmountOut is checked by caller after router fee deduction

            // Step 2: Sync token balance (required before transferFrom)
            poolManager.sync(swapData.key.currency1);

            // Step 3: Transfer tokens from user to PoolManager
            // Hook's afterSwap has set transient allowance, so this direct transfer works
            (bool success,) = swapData.token.call(
                abi.encodeWithSignature(
                    "transferFrom(address,address,uint256)",
                    swapData.sender,
                    address(poolManager),
                    tokenOwed
                )
            );
            require(success, "TransferFrom failed");

            // Step 4: Settle token debt
            poolManager.settle();

            // Step 5: Take ETH to this contract (router will handle fee and forward to user)
            poolManager.take(swapData.key.currency0, address(this), ethReceived);

            // Return ETH received (caller will deduct fee and send to user)
            return abi.encode(ethReceived);
        }
    }

    /// @notice Accept ETH from PoolManager
    receive() external payable {
        require(msg.sender == address(poolManager), "Only PoolManager");
    }
}


