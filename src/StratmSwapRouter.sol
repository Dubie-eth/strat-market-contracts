// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {Currency, CurrencyLibrary} from "@uniswap/v4-core/src/types/Currency.sol";
import {BalanceDelta} from "@uniswap/v4-core/src/types/BalanceDelta.sol";
import {SwapParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";

interface IUnlockCallback {
    function unlockCallback(bytes calldata data) external returns (bytes memory);
}

library TransientStateLibrary {
    function currencyDelta(IPoolManager manager, address target, Currency currency) internal view returns (int256) {
        bytes32 key;
        assembly ("memory-safe") {
            mstore(0, and(target, 0xffffffffffffffffffffffffffffffffffffffff))
            mstore(32, and(currency, 0xffffffffffffffffffffffffffffffffffffffff))
            key := keccak256(0, 64)
        }
        return int256(uint256(manager.exttload(key)));
    }
}

/// @title StratmSwapRouter
/// @notice Minimal, non-upgradeable router for STRATM/ETH swaps on Uniswap v4
/// @dev Implements IUnlockCallback for PoolManager unlock pattern
///      - ETH -> STRATM: exact input with slippage protection, 0.5% router fee on ETH input
///      - STRATM -> ETH: exact input with slippage protection, 0.5% router fee on ETH output
///      - Router fee: 0.5% (50 bps) goes to treasury
///      - Token tax: 3% (300 bps) applied by ERC20THook
///      - No admin, no owner, no upgrades
///      - Settles and takes directly to msg.sender (EOA)
///      - Never holds user funds beyond the swap transaction
contract StratmSwapRouter is IUnlockCallback {
    using CurrencyLibrary for Currency;

    IPoolManager public immutable poolManager;
    address public immutable treasury;

    /// @dev STRATM token on Robinhood Chain
    address public constant STRATM = 0xABCC6e05718543faB52b16d7086D3FD32f0063B3;
    /// @dev Native ETH as Currency (address(0))
    Currency public constant ETH = Currency.wrap(address(0));
    /// @dev STRATM as Currency
    Currency public constant STRATM_CURRENCY = Currency.wrap(STRATM);
    
    /// @dev Router fee: 0.5% (50 bps out of 10000)
    uint256 public constant ROUTER_FEE_BPS = 50;
    uint256 public constant BPS = 10000;

    error Unauthorized();
    error DeadlineExpired();
    error InsufficientOutput();
    error InvalidAmount();
    error TreasuryTransferFailed();

    event RouterFee(address indexed user, bool isETH, uint256 feeAmount);

    struct SwapCallbackData {
        address sender;
        PoolKey key;
        SwapParams params;
        uint256 minAmountOut;
        bool isETHInput;
    }

    constructor(IPoolManager _poolManager, address _treasury) {
        poolManager = _poolManager;
        treasury = _treasury;
    }

    /// @notice Swap exact ETH for STRATM
    /// @dev Takes 0.5% router fee from ETH input before swap, sends to treasury
    /// @param key The pool key for STRATM/ETH pool
    /// @param minAmountOut Minimum STRATM to receive (slippage protection, user receives this)
    /// @param deadline Transaction must execute before this timestamp
    /// @return amountOut Actual STRATM received by user
    function swapETHForSTRATM(
        PoolKey calldata key,
        uint256 minAmountOut,
        uint256 deadline
    ) external payable returns (uint256 amountOut) {
        if (block.timestamp > deadline) revert DeadlineExpired();
        if (msg.value == 0) revert InvalidAmount();

        // Calculate and send router fee (0.5% of ETH input)
        uint256 routerFee = (msg.value * ROUTER_FEE_BPS) / BPS;
        uint256 ethAfterFee = msg.value - routerFee;

        if (routerFee > 0) {
            (bool success, ) = treasury.call{value: routerFee}("");
            if (!success) revert TreasuryTransferFailed();
            emit RouterFee(msg.sender, true, routerFee);
        }

        // ETH (currency0) -> STRATM (currency1), zeroForOne = true
        // For exact input, amountSpecified must be NEGATIVE
        SwapParams memory params = SwapParams({
            zeroForOne: true,
            amountSpecified: -int256(ethAfterFee),  // Negative = exact input
            sqrtPriceLimitX96: TickMath.MIN_SQRT_PRICE + 1
        });

        SwapCallbackData memory data = SwapCallbackData({
            sender: msg.sender,
            key: key,
            params: params,
            minAmountOut: minAmountOut,
            isETHInput: true
        });

        bytes memory result = poolManager.unlock(abi.encode(data));
        amountOut = abi.decode(result, (uint256));

        if (amountOut < minAmountOut) revert InsufficientOutput();
    }

    /// @notice Swap exact STRATM for ETH
    /// @dev Takes 0.5% router fee from ETH output before sending to user
    ///      User must approve PoolManager for STRATM before calling
    /// @param key The pool key for STRATM/ETH pool
    /// @param amountIn Exact STRATM to sell
    /// @param minAmountOut Minimum ETH user receives after fee (slippage protection)
    /// @param deadline Transaction must execute before this timestamp
    /// @return amountOut Actual ETH received by user (after router fee)
    function swapSTRATMForETH(
        PoolKey calldata key,
        uint256 amountIn,
        uint256 minAmountOut,
        uint256 deadline
    ) external returns (uint256 amountOut) {
        if (block.timestamp > deadline) revert DeadlineExpired();
        if (amountIn == 0) revert InvalidAmount();

        // Note: User must have approved PoolManager for STRATM
        // The hook blocks transfers to contract wallets, so we can't transfer to router first
        // Instead, PoolManager will pull directly from user during settle

        // STRATM (currency1) -> ETH (currency0), zeroForOne = false
        // For exact input, amountSpecified must be NEGATIVE
        SwapParams memory params = SwapParams({
            zeroForOne: false,
            amountSpecified: -int256(amountIn),  // Negative = exact input
            sqrtPriceLimitX96: TickMath.MAX_SQRT_PRICE - 1
        });

        SwapCallbackData memory data = SwapCallbackData({
            sender: msg.sender,
            key: key,
            params: params,
            minAmountOut: minAmountOut,
            isETHInput: false
        });

        bytes memory result = poolManager.unlock(abi.encode(data));
        uint256 ethFromSwap = abi.decode(result, (uint256));

        // Calculate and send router fee (0.5% of ETH output)
        uint256 routerFee = (ethFromSwap * ROUTER_FEE_BPS) / BPS;
        uint256 ethAfterFee = ethFromSwap - routerFee;

        if (routerFee > 0) {
            (bool success1, ) = treasury.call{value: routerFee}("");
            if (!success1) revert TreasuryTransferFailed();
            emit RouterFee(msg.sender, true, routerFee);
        }

        // Send net ETH to user
        (bool success2, ) = msg.sender.call{value: ethAfterFee}("");
        if (!success2) revert TreasuryTransferFailed();

        amountOut = ethAfterFee;

        if (amountOut < minAmountOut) revert InsufficientOutput();
    }

    /// @notice Unlock callback called by PoolManager during unlock
    /// @dev Only PoolManager can call this
    ///      ERC20THook uses transient allowances: transfers to PM only work AFTER swap()
    function unlockCallback(bytes calldata data) external returns (bytes memory) {
        if (msg.sender != address(poolManager)) revert Unauthorized();

        SwapCallbackData memory swapData = abi.decode(data, (SwapCallbackData));

        // Step 1: Execute swap first - hook's afterSwap sets transient allowance for PM transfers
        poolManager.swap(swapData.key, swapData.params, "");

        // Check router's deltas after swap
        int256 delta0 = TransientStateLibrary.currencyDelta(poolManager, address(this), swapData.key.currency0);
        int256 delta1 = TransientStateLibrary.currencyDelta(poolManager, address(this), swapData.key.currency1);
        
        uint256 amountOut;
        
        // Settle negative deltas (router owes)
        if (delta0 < 0) {
            // Settle ETH using native value
            poolManager.settle{value: uint256(-delta0)}();
        }
        if (delta1 < 0) {
            // Settle STRATM: sync → transfer user→PM directly → settle
            // Hook's transient allowance (set during swap) permits user→PM transfer
            uint256 amountToSettle = uint256(-delta1);
            
            // Step 2: Sync STRATM before transfer
            poolManager.sync(swapData.key.currency1);
            
            // Step 3: Transfer directly from user to PoolManager
            // User approved router; router calls transferFrom on their behalf
            // This works because hook granted transient allowance during swap
            _transferFrom(STRATM, swapData.sender, address(poolManager), amountToSettle);
            
            // Step 4: Settle to clear the debt
            poolManager.settle();
        }
        
        // Take positive deltas (router is owed)
        if (delta0 > 0) {
            // Take ETH to router (for sell), will deduct fee and forward to user
            amountOut = uint256(delta0);
            poolManager.take(swapData.key.currency0, address(this), amountOut);
        }
        if (delta1 > 0) {
            // Take STRATM directly to user (for buy)
            amountOut = uint256(delta1);
            poolManager.take(swapData.key.currency1, swapData.sender, amountOut);
        }

        return abi.encode(amountOut);
    }

    /// @dev Internal transfer helper
    function _transfer(address token, address to, uint256 amount) internal {
        (bool success, bytes memory data) = token.call(
            abi.encodeWithSelector(0xa9059cbb, to, amount)  // transfer(address,uint256)
        );
        require(success && (data.length == 0 || abi.decode(data, (bool))), "Transfer failed");
    }

    /// @dev Internal transferFrom helper
    function _transferFrom(address token, address from, address to, uint256 amount) internal {
        (bool success, bytes memory data) = token.call(
            abi.encodeWithSelector(0x23b872dd, from, to, amount)  // transferFrom(address,address,uint256)
        );
        require(success && (data.length == 0 || abi.decode(data, (bool))), "TransferFrom failed");
    }

    /// @notice Allow contract to receive ETH from PoolManager
    receive() external payable {}
}


