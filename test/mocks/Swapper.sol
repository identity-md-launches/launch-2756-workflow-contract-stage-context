// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {IUnlockCallback} from "v4-core/src/interfaces/callback/IUnlockCallback.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {Currency} from "v4-core/src/types/Currency.sol";
import {BalanceDelta} from "v4-core/src/types/BalanceDelta.sol";
import {ModifyLiquidityParams, SwapParams} from "v4-core/src/types/PoolOperation.sol";
import {TickMath} from "v4-core/src/libraries/TickMath.sol";

/// @notice A minimal test router: swaps and liquidity changes paid from its own balances. Fund it
/// before use. The hook reads the buyer as `tx.origin`, so tests prank both sender and origin.
contract Swapper is IUnlockCallback {
    IPoolManager public immutable manager;

    enum Action {
        Swap,
        Liquidity
    }

    constructor(IPoolManager manager_) {
        manager = manager_;
    }

    /// @notice Exact-input swap of `amountIn` of the input currency.
    function swap(PoolKey memory key, bool zeroForOne, uint256 amountIn) external returns (BalanceDelta) {
        return _swap(key, zeroForOne, -int256(amountIn), 0);
    }

    /// @notice A swap with a signed amount: negative is exact input, positive exact output.
    function swapExact(PoolKey memory key, bool zeroForOne, int256 amountSpecified) external returns (BalanceDelta) {
        return _swap(key, zeroForOne, amountSpecified, 0);
    }

    /// @notice A swap bounded by a sqrt price limit, so the pool may fill only part of the amount.
    function swapWithLimit(PoolKey memory key, bool zeroForOne, int256 amountSpecified, uint160 limit)
        external
        returns (BalanceDelta)
    {
        return _swap(key, zeroForOne, amountSpecified, limit);
    }

    /// @notice Adds (or with a negative or zero delta removes/collects) liquidity on this router's position.
    function modifyLiquidity(PoolKey memory key, int24 tickLower, int24 tickUpper, int256 liquidityDelta)
        external
        returns (BalanceDelta)
    {
        bytes memory result =
            manager.unlock(abi.encode(Action.Liquidity, abi.encode(key, tickLower, tickUpper, liquidityDelta)));
        return abi.decode(result, (BalanceDelta));
    }

    function _swap(PoolKey memory key, bool zeroForOne, int256 amountSpecified, uint160 limit)
        private
        returns (BalanceDelta)
    {
        bytes memory result =
            manager.unlock(abi.encode(Action.Swap, abi.encode(key, zeroForOne, amountSpecified, limit)));
        return abi.decode(result, (BalanceDelta));
    }

    function unlockCallback(bytes calldata data) external returns (bytes memory) {
        require(msg.sender == address(manager), "not manager");
        (Action action, bytes memory inner) = abi.decode(data, (Action, bytes));
        BalanceDelta delta;
        PoolKey memory key;
        if (action == Action.Swap) {
            (PoolKey memory k, bool zeroForOne, int256 amountSpecified, uint160 limit) =
                abi.decode(inner, (PoolKey, bool, int256, uint160));
            key = k;
            // No limit given: swap to the edge of the price range.
            if (limit == 0) limit = zeroForOne ? TickMath.MIN_SQRT_PRICE + 1 : TickMath.MAX_SQRT_PRICE - 1;
            delta = manager.swap(key, SwapParams(zeroForOne, amountSpecified, limit), "");
        } else {
            (PoolKey memory k, int24 lower, int24 upper, int256 liquidity) =
                abi.decode(inner, (PoolKey, int24, int24, int256));
            key = k;
            (delta,) = manager.modifyLiquidity(key, ModifyLiquidityParams(lower, upper, liquidity, bytes32(0)), "");
        }
        _settle(key.currency0, delta.amount0());
        _settle(key.currency1, delta.amount1());
        return abi.encode(delta);
    }

    function _settle(Currency currency, int128 amount) private {
        if (amount < 0) {
            uint256 owedAmount = uint256(uint128(-amount));
            manager.sync(currency);
            if (currency.isAddressZero()) {
                manager.settle{value: owedAmount}();
            } else {
                IERC20(Currency.unwrap(currency)).transfer(address(manager), owedAmount);
                manager.settle();
            }
        } else if (amount > 0) {
            manager.take(currency, address(this), uint256(uint128(amount)));
        }
    }

    receive() external payable {}
}
