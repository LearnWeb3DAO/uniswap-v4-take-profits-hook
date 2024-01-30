// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.0;

// Foundry libraries
import "forge-std/Test.sol";

// Test ERC-20 token implementation
import {TestERC20} from "v4-core/test/TestERC20.sol";

// Libraries
import {CurrencyLibrary, Currency} from "v4-core/types/Currency.sol";
import {PoolId, PoolIdLibrary} from "v4-core/types/PoolId.sol";
import {PoolKey} from "v4-core/types/PoolKey.sol";
import {Hooks} from "v4-core/libraries/Hooks.sol";
import {TickMath} from "v4-core/libraries/TickMath.sol";

// Interfaces
import {IHooks} from "v4-core/interfaces/IHooks.sol";
import {IERC20Minimal} from "v4-core/interfaces/external/IERC20Minimal.sol";
import {IPoolManager} from "v4-core/interfaces/IPoolManager.sol";

// Pool Manager related contracts
import {PoolManager} from "v4-core/PoolManager.sol";
import {PoolModifyPositionTest} from "v4-core/test/PoolModifyPositionTest.sol";
import {PoolSwapTest} from "v4-core/test/PoolSwapTest.sol";

// Our contracts
import {TakeProfitsHook} from "../src/TakeProfitsHook.sol";
import {TakeProfitsStub} from "../src/TakeProfitsStub.sol";

contract TakeProfitsHookTest is Test {
    // Use the libraries
    using PoolIdLibrary for PoolKey;
    using CurrencyLibrary for Currency;

    // Hardcode the address for our hook instead of deploying it
    // We will overwrite the storage to replace code at this address with code from the stub
    TakeProfitsHook hook =
        TakeProfitsHook(
            address(
                uint160(Hooks.AFTER_INITIALIZE_FLAG | Hooks.AFTER_SWAP_FLAG)
            )
        );

    // poolManager is the Uniswap v4 Pool Manager
    PoolManager poolManager;

    // modifyPositionRouter is the test-version of the contract that allows
    // liquidity providers to add/remove/update their liquidity positions
    PoolModifyPositionTest modifyPositionRouter;

    // swapRouter is the test-version of the contract that allows
    // users to execute swaps on Uniswap v4
    PoolSwapTest swapRouter;

    // token0 and token1 are the two tokens in the pool
    TestERC20 token0;
    TestERC20 token1;

    // poolKey and poolId are the pool key and pool id for the pool
    PoolKey poolKey;
    PoolId poolId;

    // SQRT_RATIO_1_1 is the Q notation for sqrtPriceX96 where price = 1
    // i.e. sqrt(1) * 2^96
    // This is used as the initial price for the pool
    // as we add equal amounts of token0 and token1 to the pool during setUp
    uint160 constant SQRT_RATIO_1_1 = 79228162514264337593543950336;

    function setUp() public {
        _deployERC20Tokens();
        poolManager = new PoolManager(500_000);
        _stubValidateHookAddress();
        _initializePool();
        _addLiquidityToPool();
    }

    function test_placeOrder() public {
        // Place a zeroForOne take-profit order
        // for 10e18 token0 tokens
        // at tick 100

        int24 tick = 100;
        uint256 amount = 10 ether;
        bool zeroForOne = true;

        // Note the original balance of token0 we have
        uint256 originalBalance = token0.balanceOf(address(this));

        // Place the order
        token0.approve(address(hook), amount);
        int24 tickLower = hook.placeOrder(poolKey, tick, amount, zeroForOne);

        // Note the new balance of token0 we have
        uint256 newBalance = token0.balanceOf(address(this));

        // Since we deployed the pool contract with tick spacing = 60
        // i.e. the tick can only be a multiple of 60
        // and initially the tick is 0
        // the tickLower should be 60 since we placed an order at tick 100
        assertEq(tickLower, 60);

        // Ensure that our balance was reduced by `amount` tokens
        assertEq(originalBalance - newBalance, amount);

        // Check the balance of ERC-1155 tokens we received
        uint256 tokenId = hook.getTokenId(poolKey, tickLower, zeroForOne);
        uint256 tokenBalance = hook.balanceOf(address(this), tokenId);

        // Ensure that we were, in fact, given ERC-1155 tokens for the order
        // equal to the `amount` of token0 tokens we placed the order for
        assertTrue(tokenId != 0);
        assertEq(tokenBalance, amount);
    }

    function test_cancelOrder() public {
        // Place an order similar as earlier, but cancel it later
        int24 tick = 100;
        uint256 amount = 10 ether;
        bool zeroForOne = true;

        uint256 originalBalance = token0.balanceOf(address(this));

        token0.approve(address(hook), amount);
        int24 tickLower = hook.placeOrder(poolKey, tick, amount, zeroForOne);

        uint256 newBalance = token0.balanceOf(address(this));

        assertEq(tickLower, 60);
        assertEq(originalBalance - newBalance, amount);

        // Check the balance of ERC-1155 tokens we received
        uint256 tokenId = hook.getTokenId(poolKey, tickLower, zeroForOne);
        uint256 tokenBalance = hook.balanceOf(address(this), tokenId);
        assertEq(tokenBalance, amount);

        // Cancel the order
        hook.cancelOrder(poolKey, tickLower, zeroForOne);

        // Check that we received our token0 tokens back, and no longer own any ERC-1155 tokens
        uint256 finalBalance = token0.balanceOf(address(this));
        assertEq(finalBalance, originalBalance);

        tokenBalance = hook.balanceOf(address(this), tokenId);
        assertEq(tokenBalance, 0);
    }

    function test_orderExecute_zeroForOne() public {
        int24 tick = 100;
        uint256 amount = 10 ether;
        bool zeroForOne = true;

        // Place our order at tick 100 for 10e18 token0 tokens
        token0.approve(address(hook), amount);
        int24 tickLower = hook.placeOrder(poolKey, tick, amount, zeroForOne);

        // Do a separate swap from oneForZero to make tick go up
        // Sell 1e18 token1 tokens for token0 tokens
        IPoolManager.SwapParams memory params = IPoolManager.SwapParams({
            zeroForOne: !zeroForOne,
            amountSpecified: 1 ether,
            sqrtPriceLimitX96: TickMath.MAX_SQRT_RATIO - 1
        });

        PoolSwapTest.TestSettings memory testSettings = PoolSwapTest
            .TestSettings({withdrawTokens: true, settleUsingTransfer: true});

        swapRouter.swap(poolKey, params, testSettings);

        // Check that the order has been executed
        int256 tokensLeftToSell = hook.takeProfitPositions(
            poolId,
            tick,
            zeroForOne
        );
        assertEq(tokensLeftToSell, 0);

        // Check that the hook contract has the expected number of token1 tokens ready to redeem
        uint256 tokenId = hook.getTokenId(poolKey, tickLower, zeroForOne);
        uint256 claimableTokens = hook.tokenIdClaimable(tokenId);
        uint256 hookContractToken1Balance = token1.balanceOf(address(hook));
        assertEq(claimableTokens, hookContractToken1Balance);

        // Ensure we can redeem the token1 tokens
        uint256 originalToken1Balance = token1.balanceOf(address(this));
        hook.redeem(tokenId, amount, address(this));
        uint256 newToken1Balance = token1.balanceOf(address(this));

        assertEq(newToken1Balance - originalToken1Balance, claimableTokens);
    }

    function test_orderExecute_oneForZero() public {
        int24 tick = -100;
        uint256 amount = 10 ether;
        bool zeroForOne = false;

        // Place our order at tick -100 for 10e18 token1 tokens
        token1.approve(address(hook), amount);
        int24 tickLower = hook.placeOrder(poolKey, tick, amount, zeroForOne);

        // Do a separate swap from zeroForOne to make tick go down
        // Sell 1e18 token0 tokens for token1 tokens
        IPoolManager.SwapParams memory params = IPoolManager.SwapParams({
            zeroForOne: !zeroForOne,
            amountSpecified: 1 ether,
            sqrtPriceLimitX96: TickMath.MIN_SQRT_RATIO + 1
        });

        PoolSwapTest.TestSettings memory testSettings = PoolSwapTest
            .TestSettings({withdrawTokens: true, settleUsingTransfer: true});

        swapRouter.swap(poolKey, params, testSettings);

        // Check that the order has been executed
        int256 tokensLeftToSell = hook.takeProfitPositions(
            poolId,
            tick,
            zeroForOne
        );
        assertEq(tokensLeftToSell, 0);

        // Check that the hook contract has the expected number of token0 tokens ready to redeem
        uint256 tokenId = hook.getTokenId(poolKey, tickLower, zeroForOne);
        uint256 claimableTokens = hook.tokenIdClaimable(tokenId);
        uint256 hookContractToken0Balance = token0.balanceOf(address(hook));
        assertEq(claimableTokens, hookContractToken0Balance);

        // Ensure we can redeem the token0 tokens
        uint256 originalToken0Balance = token0.balanceOf(address(this));
        hook.redeem(tokenId, amount, address(this));
        uint256 newToken0Balance = token0.balanceOf(address(this));

        assertEq(newToken0Balance - originalToken0Balance, claimableTokens);
    }

    function test_multiple_orderExecute_zeroForOne() public {
        PoolSwapTest.TestSettings memory testSettings = PoolSwapTest
            .TestSettings({withdrawTokens: true, settleUsingTransfer: true});

        // Setup two zeroForOne orders at ticks 0 and 60
        uint256 amount = 1 ether;

        token1.approve(address(hook), 10 ether);
        token0.approve(address(hook), 10 ether);
        hook.placeOrder(poolKey, 0, amount, true);
        hook.placeOrder(poolKey, 60, amount, true);

        // Do a swap to make tick increase to 120
        IPoolManager.SwapParams memory params = IPoolManager.SwapParams({
            zeroForOne: false,
            amountSpecified: 0.5 ether,
            sqrtPriceLimitX96: TickMath.MAX_SQRT_RATIO - 1
        });

        swapRouter.swap(poolKey, params, testSettings);

        // Only one order should have been executed
        // because the execution of that order would lower the tick
        // so even though tick increased to 120
        // the first order execution will lower it back down
        // so order at tick = 60 will not be executed
        int256 tokensLeftToSell = hook.takeProfitPositions(
            poolId,
            0,
            true
        );
        assertEq(tokensLeftToSell, 0);

        tokensLeftToSell = hook.takeProfitPositions(
            poolId,
            60,
            true
        );
        assertEq(tokensLeftToSell, int(amount));
    }

    function _addLiquidityToPool() private {
        // Mint a lot of tokens to ourselves
        token0.mint(address(this), 100 ether);
        token1.mint(address(this), 100 ether);

        // Approve the modifyPositionRouter to spend your tokens
        token0.approve(address(modifyPositionRouter), 100 ether);
        token1.approve(address(modifyPositionRouter), 100 ether);

        // Add liquidity across different tick ranges
        // First, from -60 to +60
        // Then, from -120 to +120
        // Then, from minimum possible tick to maximum possible tick

        // Add liquidity from -60 to +60
        modifyPositionRouter.modifyPosition(
            poolKey,
            IPoolManager.ModifyPositionParams(-60, 60, 10 ether)
        );

        // Add liquidity from -120 to +120
        modifyPositionRouter.modifyPosition(
            poolKey,
            IPoolManager.ModifyPositionParams(-120, 120, 10 ether)
        );

        // Add liquidity from minimum tick to maximum tick
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
        // Deploy the test-versions of modifyPositionRouter and swapRouter
        modifyPositionRouter = new PoolModifyPositionTest(
            IPoolManager(address(poolManager))
        );
        swapRouter = new PoolSwapTest(IPoolManager(address(poolManager)));

        // Specify the pool key and pool id for the new pool
        poolKey = PoolKey({
            currency0: Currency.wrap(address(token0)),
            currency1: Currency.wrap(address(token1)),
            fee: 3000,
            tickSpacing: 60,
            hooks: IHooks(hook)
        });
        poolId = poolKey.toId();

        // Initialize the new pool with initial price ratio = 1
        poolManager.initialize(poolKey, SQRT_RATIO_1_1);
    }

    function _stubValidateHookAddress() private {
        // Deploy the stub contract
        TakeProfitsStub stub = new TakeProfitsStub(poolManager, hook);

        // Fetch all the storage slot writes that have been done at the stub address
        // during deployment
        (, bytes32[] memory writes) = vm.accesses(address(stub));

        // Etch the code of the stub at the hardcoded hook address
        vm.etch(address(hook), address(stub).code);

        // Replay the storage slot writes at the hook address
        unchecked {
            for (uint256 i = 0; i < writes.length; i++) {
                bytes32 slot = writes[i];
                vm.store(address(hook), slot, vm.load(address(stub), slot));
            }
        }
    }

    function _deployERC20Tokens() private {
        TestERC20 tokenA = new TestERC20(2 ** 128);
        TestERC20 tokenB = new TestERC20(2 ** 128);

        // Token 0 and Token 1 are assigned in a pool based on
        // the address of the token
        if (address(tokenA) < address(tokenB)) {
            token0 = tokenA;
            token1 = tokenB;
        } else {
            token0 = tokenB;
            token1 = tokenA;
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
