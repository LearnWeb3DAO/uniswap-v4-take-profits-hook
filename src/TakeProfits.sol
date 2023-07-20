// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.0;

import {PoolId, PoolIdLibrary} from "v4-core/libraries/PoolId.sol";
import {BaseHook} from "periphery-next/BaseHook.sol";
import {IPoolManager} from "v4-core/interfaces/IPoolManager.sol";
import {Hooks} from "v4-core/libraries/Hooks.sol";
import {ERC1155} from "openzeppelin-contracts/contracts/token/ERC1155/ERC1155.sol";
import {BalanceDelta} from "v4-core/types/BalanceDelta.sol";
import {Currency, CurrencyLibrary} from "v4-core/libraries/CurrencyLibrary.sol";
import {FixedPointMathLib} from "solmate/utils/FixedPointMathLib.sol";
import {TickMath} from "v4-core/libraries/TickMath.sol";
import {IERC20} from "openzeppelin-contracts/contracts/token/ERC20/IERC20.sol";

contract TakeProfitsHook is BaseHook, ERC1155 {
    using PoolIdLibrary for IPoolManager.PoolKey;
    using CurrencyLibrary for Currency;
    using FixedPointMathLib for uint256;

    // Hook State
    mapping(PoolId poolId => int24 tickLower) public tickLowerLasts;
    mapping(PoolId poolId => mapping(int24 tick => mapping(bool zeroForOne => int256 amount)))
        public takeProfitPositions;

    // ERC-1155 NFT State
    mapping(uint256 tokenId => bool exists) public tokenIdExists;
    mapping(uint256 tokenId => uint256 claimable) public tokenIdClaimable;
    mapping(uint256 tokenId => uint256 supply) public tokenIdTotalSupply;
    mapping(uint256 tokenId => TokenData) public tokenIdData;

    struct TokenData {
        IPoolManager.PoolKey poolKey;
        int24 tick;
        bool zeroForOne;
    }

    constructor(
        IPoolManager _poolManager,
        string memory _uri
    ) BaseHook(_poolManager) ERC1155(_uri) {}

    function getHooksCalls() public pure override returns (Hooks.Calls memory) {
        return
            Hooks.Calls({
                beforeInitialize: false,
                afterInitialize: false,
                beforeModifyPosition: false,
                afterModifyPosition: false,
                beforeSwap: false,
                afterSwap: true,
                beforeDonate: false,
                afterDonate: false
            });
    }

    function afterInitialize(
        address,
        IPoolManager.PoolKey calldata key,
        uint160,
        int24 tick
    ) external override poolManagerOnly returns (bytes4) {
        _setTickLowerLast(key.toId(), _getTickLower(tick, key.tickSpacing));
        return TakeProfitsHook.afterInitialize.selector;
    }

    function afterSwap(
        address,
        IPoolManager.PoolKey calldata key,
        IPoolManager.SwapParams calldata params,
        BalanceDelta
    ) external override returns (bytes4) {
        int24 lastTick = tickLowerLasts[key.toId()];
        (, int24 tick, , , , ) = poolManager.getSlot0(key.toId());
        int24 currentTick = _getTickLower(tick, key.tickSpacing);
        tick = lastTick;

        int256 swapAmounts;

        bool swapZeroForOne = !params.zeroForOne;

        // If current tick is higher than last tick, fill all orders, if any, with take profits
        // set to a price between last tick and current tick
        if (lastTick < currentTick) {
            for (; tick < currentTick; ) {
                swapAmounts = takeProfitPositions[key.toId()][tick][
                    swapZeroForOne
                ];
                if (swapAmounts > 0) {
                    fillOrder(key, tick, swapZeroForOne, swapAmounts);
                }

                tick += key.tickSpacing;
            }
        }
        // If current tick is lower than last tick, fill all orders, if any, with take profits
        // set to a price between current tick and last tick
        else {
            for (; currentTick < tick; ) {
                swapAmounts = takeProfitPositions[key.toId()][tick][
                    swapZeroForOne
                ];
                if (swapAmounts > 0) {
                    fillOrder(key, tick, swapZeroForOne, swapAmounts);
                }

                tick -= key.tickSpacing;
            }
        }

        return TakeProfitsHook.afterSwap.selector;
    }

    function fillOrder(
        IPoolManager.PoolKey calldata key,
        int24 tick,
        bool zeroForOne,
        int256 swapAmount
    ) internal {
        IPoolManager.SwapParams memory swapParams = IPoolManager.SwapParams({
            zeroForOne: zeroForOne,
            amountSpecified: swapAmount,
            sqrtPriceLimitX96: zeroForOne
                ? TickMath.MIN_SQRT_RATIO + 1
                : TickMath.MAX_SQRT_RATIO - 1
        });

        BalanceDelta delta = _swap(key, swapParams, address(this));
        takeProfitPositions[key.toId()][tick][zeroForOne] -= swapAmount;

        uint256 tokenId = getTokenId(key, tick, zeroForOne);

        uint256 amountReceived = zeroForOne
            ? uint256(int256(-delta.amount1()))
            : uint256(int256(-delta.amount0()));
        tokenIdClaimable[tokenId] += amountReceived;
    }

    function placeOrder(
        IPoolManager.PoolKey calldata key,
        int24 tickLower,
        uint256 amountIn,
        bool zeroForOne
    ) external returns (int24) {
        int24 tick = _getTickLower(tickLower, key.tickSpacing);
        takeProfitPositions[key.toId()][tick][zeroForOne] += int256(amountIn);

        uint256 tokenId = getTokenId(key, tick, zeroForOne);
        if (!tokenIdExists[tokenId]) {
            tokenIdExists[tokenId] = true;
            tokenIdData[tokenId] = TokenData(key, tick, zeroForOne);
        }

        _mint(msg.sender, tokenId, amountIn, "");
        tokenIdTotalSupply[tokenId] += amountIn;

        address tokenContract = zeroForOne
            ? Currency.unwrap(key.currency0)
            : Currency.unwrap(key.currency1);
        IERC20(tokenContract).transferFrom(msg.sender, address(this), amountIn);

        return tick;
    }

    function cancelOrder(
        IPoolManager.PoolKey calldata key,
        int24 tick,
        bool zeroForOne
    ) external {
        uint256 tokenId = getTokenId(key, tick, zeroForOne);
        uint256 amountIn = balanceOf(msg.sender, tokenId);
        require(amountIn > 0, "TPH: Nothing to cancel");

        takeProfitPositions[key.toId()][tick][zeroForOne] -= int256(amountIn);
        _burn(msg.sender, tokenId, amountIn);
        tokenIdTotalSupply[tokenId] -= amountIn;

        address tokenContract = zeroForOne
            ? Currency.unwrap(key.currency0)
            : Currency.unwrap(key.currency1);
        IERC20(tokenContract).transfer(msg.sender, amountIn);
    }

    // Core Internals
    function _swap(
        IPoolManager.PoolKey calldata key,
        IPoolManager.SwapParams memory params,
        address recipient
    ) internal returns (BalanceDelta) {
        BalanceDelta delta = abi.decode(
            poolManager.lock(
                abi.encodeCall(this._handleSwap, (key, params, recipient))
            ),
            (BalanceDelta)
        );

        uint256 ethBalance = address(this).balance;
        if (ethBalance > 0) {
            CurrencyLibrary.NATIVE.transfer(msg.sender, ethBalance);
        }

        return delta;
    }

    function _handleSwap(
        IPoolManager.PoolKey calldata key,
        IPoolManager.SwapParams calldata params,
        address recipient
    ) external returns (BalanceDelta) {
        BalanceDelta delta = poolManager.swap(key, params);

        if (params.zeroForOne) {
            if (delta.amount0() > 0) {
                if (key.currency0.isNative()) {
                    poolManager.settle{value: uint128(delta.amount0())}(
                        key.currency0
                    );
                } else {
                    IERC20(Currency.unwrap(key.currency0)).transfer(
                        address(poolManager),
                        uint128(delta.amount0())
                    );
                    poolManager.settle(key.currency0);
                }
            }

            if (delta.amount1() < 0) {
                poolManager.take(
                    key.currency1,
                    recipient,
                    uint128(-delta.amount1())
                );
            }
        } else {
            if (delta.amount1() > 0) {
                if (key.currency1.isNative()) {
                    poolManager.settle{value: uint128(delta.amount1())}(
                        key.currency1
                    );
                } else {
                    IERC20(Currency.unwrap(key.currency1)).transfer(
                        address(poolManager),
                        uint128(delta.amount0())
                    );
                    poolManager.settle(key.currency1);
                }
            }

            if (delta.amount0() < 0) {
                poolManager.take(
                    key.currency0,
                    recipient,
                    uint128(-delta.amount0())
                );
            }
        }

        return delta;
    }

    // ERC-1155 Functions
    function getTokenId(
        IPoolManager.PoolKey calldata key,
        int24 tick,
        bool zeroForOne
    ) public pure returns (uint256) {
        return
            uint256(keccak256(abi.encodePacked(key.toId(), tick, zeroForOne)));
    }

    function redeem(
        uint256 tokenId,
        uint256 amountIn,
        address destination
    ) external {
        require(tokenIdClaimable[tokenId] > 0, "TPH: Nothing to claim");
        uint256 balance = balanceOf(msg.sender, tokenId);
        require(amountIn <= balance, "TPH: Insufficient token balance");

        TokenData memory data = tokenIdData[tokenId];
        address tokenContract = data.zeroForOne
            ? Currency.unwrap(data.poolKey.currency1)
            : Currency.unwrap(data.poolKey.currency0);

        uint256 amountOut = amountIn.mulDivDown(
            tokenIdClaimable[tokenId],
            tokenIdTotalSupply[tokenId]
        );

        tokenIdClaimable[tokenId] -= amountOut;
        _burn(msg.sender, tokenId, amountIn);
        tokenIdTotalSupply[tokenId] -= amountIn;

        IERC20(tokenContract).transfer(destination, amountOut);
    }

    // Utility Functions
    function _setTickLowerLast(PoolId poolId, int24 tickLower) private {
        tickLowerLasts[poolId] = tickLower;
    }

    function _getTickLower(
        int24 tick,
        int24 tickSpacing
    ) private pure returns (int24) {
        int24 compressed = tick / tickSpacing;
        if (tick < 0 && tick % tickSpacing != 0) compressed--;
        return compressed * tickSpacing;
    }
}
