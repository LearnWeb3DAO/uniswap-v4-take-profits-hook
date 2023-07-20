// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.0;

import "forge-std/Test.sol";
import {GasSnapshot} from "forge-gas-snapshot/GasSnapshot.sol";
import {TestERC20} from "v4-core/test/TestERC20.sol";
import {IERC20Minimal} from "v4-core/interfaces/external/IERC20Minimal.sol";
import {IHooks} from "v4-core/interfaces/IHooks.sol";
import {Hooks} from "v4-core/libraries/Hooks.sol";
import {TickMath} from "v4-core/libraries/TickMath.sol";
import {PoolManager} from "v4-core/PoolManager.sol";
import {IPoolManager} from "v4-core/interfaces/IPoolManager.sol";
import {PoolId, PoolIdLibrary} from "v4-core/libraries/PoolId.sol";
import {PoolModifyPositionTest} from "v4-core/test/PoolModifyPositionTest.sol";
import {PoolSwapTest} from "v4-core/test/PoolSwapTest.sol";
import {PoolDonateTest} from "v4-core/test/PoolDonateTest.sol";
import {Deployers} from "v4-core-test/foundry-tests/utils/Deployers.sol";
import {CurrencyLibrary, Currency} from "v4-core/libraries/CurrencyLibrary.sol";
import {TakeProfitsHook} from "../src/TakeProfits.sol";
import {TakeProfitsStub} from "../src/TakeProfitsStub.sol";

contract TakeProfitsTest is Test, Deployers, GasSnapshot {
    using PoolIdLibrary for IPoolManager.PoolKey;
    using CurrencyLibrary for Currency;

    TakeProfitsHook hook =
        TakeProfitsHook(
            address(
                uint160(Hooks.AFTER_INITIALIZE_FLAG | Hooks.AFTER_SWAP_FLAG)
            )
        );

    PoolManager poolManager;
    PoolModifyPositionTest modifyPositionRouter;
    PoolSwapTest swapRouter;

    TestERC20 _tokenA;
    TestERC20 _tokenB;
    TestERC20 token0;
    TestERC20 token1;

    IPoolManager.PoolKey poolKey;
    PoolId poolId;

    function setUp() public {
        _deployERC20Tokens();
        poolManager = new PoolManager(500_000);
        _stubValidateHookAddress();
        _initializePool();
        _addLiquidityToPool();
    }

    function test_placeOrder() public {
        int24 tick = 100;
        uint256 amount = 100 ether;
        bool zeroForOne = true;

        uint256 originalBalance = token0.balanceOf(address(this));
        token0.approve(address(hook), amount);

        int24 actualTick = hook.placeOrder(poolKey, tick, amount, zeroForOne);
        uint256 newBalance = token0.balanceOf(address(this));

        assertEq(actualTick, 60);
        assertEq(originalBalance - newBalance, amount);

        uint256 tokenId = hook.getTokenId(poolKey, actualTick, zeroForOne);
        uint256 tokenBalance = hook.balanceOf(address(this), tokenId);
        assertTrue(tokenId != 0);
        assertEq(tokenBalance, amount);
    }

    function test_cancelOrder() public {
        int24 tick = 100;
        uint256 amount = 100 ether;
        bool zeroForOne = true;

        uint256 originalBalance = token0.balanceOf(address(this));
        token0.approve(address(hook), amount);

        int24 actualTick = hook.placeOrder(poolKey, tick, amount, zeroForOne);
        uint256 newBalance = token0.balanceOf(address(this));

        assertEq(actualTick, 60);
        assertEq(originalBalance - newBalance, amount);

        hook.cancelOrder(poolKey, actualTick, zeroForOne);

        uint256 newNewBalance = token0.balanceOf(address(this));
        assertEq(newNewBalance, originalBalance);
    }

    // Take profits execution happens when there is a trade in the opposite direction as the position.
    // To test it, we have a zeroForOne take profit when
    // the tick price crosses 100.
    // The pool is by default initialized to tick price 0
    // Therefore, by doing a oneForZero swap, we can trigger the take profit
    function test_orderExecute_zeroForOne() public {
        int24 tick = 100;
        uint256 amount = 10 ether;
        bool zeroForOne = true;

        token0.approve(address(hook), amount);
        int24 actualTick = hook.placeOrder(poolKey, tick, amount, zeroForOne);

        IPoolManager.SwapParams memory params = IPoolManager.SwapParams({
            zeroForOne: !zeroForOne,
            amountSpecified: 1 ether,
            sqrtPriceLimitX96: TickMath.MAX_SQRT_RATIO - 1
        });

        PoolSwapTest.TestSettings memory testSettings = PoolSwapTest
            .TestSettings({withdrawTokens: true, settleUsingTransfer: true});

        swapRouter.swap(poolKey, params, testSettings);

        int256 orderAmount = hook.takeProfitPositions(
            poolKey.toId(),
            tick,
            zeroForOne
        );
        assertEq(orderAmount, 0);

        uint256 tokenId = hook.getTokenId(poolKey, actualTick, zeroForOne);
        uint256 claimableTokens = hook.tokenIdClaimable(tokenId);
        assertEq(claimableTokens, token1.balanceOf(address(hook))); // we're the only ones who own `token1` so we must be able to claim all

        uint256 balanceBefore = token1.balanceOf(address(this));
        hook.redeem(
            tokenId,
            hook.balanceOf(address(this), tokenId),
            address(this)
        );
        uint256 balanceAfter = token1.balanceOf(address(this));
        assertEq(balanceAfter - balanceBefore, claimableTokens);
    }

    // Helper Functions

    function _addLiquidityToPool() private {
        // Approve the modifyPositionRouter to spend tokens
        token0.approve(address(modifyPositionRouter), 100 ether);
        token1.approve(address(modifyPositionRouter), 100 ether);

        // Mint a lot of tokens to ourselves
        token0.mint(address(this), 100 ether);
        token1.mint(address(this), 100 ether);

        // Add liquidity across different tick ranges
        modifyPositionRouter.modifyPosition(
            poolKey,
            IPoolManager.ModifyPositionParams(-60, 60, 10 ether)
        );
        modifyPositionRouter.modifyPosition(
            poolKey,
            IPoolManager.ModifyPositionParams(-120, 120, 10 ether)
        );
        modifyPositionRouter.modifyPosition(
            poolKey,
            IPoolManager.ModifyPositionParams(
                TickMath.minUsableTick(60),
                TickMath.maxUsableTick(60),
                50 ether
            )
        );

        // Approve the tokens for swapping through the swapRouter
        token0.approve(address(swapRouter), 100 ether);
        token1.approve(address(swapRouter), 100 ether);
    }

    function _initializePool() private {
        modifyPositionRouter = new PoolModifyPositionTest(
            IPoolManager(address(poolManager))
        );
        swapRouter = new PoolSwapTest(IPoolManager(address(poolManager)));

        poolKey = IPoolManager.PoolKey({
            currency0: Currency.wrap(address(token0)),
            currency1: Currency.wrap(address(token1)),
            fee: 3000,
            tickSpacing: 60,
            hooks: IHooks(hook)
        });
        poolId = poolKey.toId();
        poolManager.initialize(poolKey, SQRT_RATIO_1_1);
    }

    function _stubValidateHookAddress() private {
        //// The testing environment requires us to override `validateHookAddress` function
        //// To avoid doing that in the main contract so it doesn't affect a real deployment
        //// We do it in the TakeProfitsStub and then use Foundry Cheat Codes to override the
        //// hook address to the stub
        TakeProfitsStub stub = new TakeProfitsStub(poolManager, hook);
        (, bytes32[] memory writes) = vm.accesses(address(stub));
        vm.etch(address(hook), address(stub).code);
        unchecked {
            for (uint256 i = 0; i < writes.length; i++) {
                bytes32 slot = writes[i];
                vm.store(address(hook), slot, vm.load(address(stub), slot));
            }
        }
    }

    function _deployERC20Tokens() private {
        _tokenA = new TestERC20(2 ** 128);
        _tokenB = new TestERC20(2 ** 128);

        if (address(_tokenA) < address(_tokenB)) {
            token0 = _tokenA;
            token1 = _tokenB;
        } else {
            token0 = _tokenB;
            token1 = _tokenA;
        }
    }

    receive() external payable {}

    function onERC1155Received(
        address,
        address,
        uint256,
        uint256,
        bytes calldata
    ) external pure returns (bytes4) {
        return
            bytes4(
                keccak256(
                    "onERC1155Received(address,address,uint256,uint256,bytes)"
                )
            );
    }

    function onERC1155BatchReceived(
        address,
        address,
        uint256[] calldata,
        uint256[] calldata,
        bytes calldata
    ) external pure returns (bytes4) {
        return
            bytes4(
                keccak256(
                    "onERC1155BatchReceived(address,address,uint256[],uint256[],bytes)"
                )
            );
    }
}
