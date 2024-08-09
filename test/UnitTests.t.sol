pragma solidity 0.8.25;

import "test/BaseCaptiveTest.sol";
import "test/interfaces/ISwapRouter.sol";

contract UnitTests is BaseCaptiveTest {
    ISwapRouter public router = ISwapRouter(0xE592427A0AEce92De3Edee1F18E0157C05861564);

    /// @dev Ensure that balances and state variables are updated correctly.
    function testAddLiquidity() public {
        fold.transfer(User01, 1_000 ether);

        vm.deal(User01, 1_000 ether);
        vm.startPrank(User01);

        weth.deposit{value: 1_000 ether}();
        weth.approve(address(foldCaptiveStaking), type(uint256).max);
        fold.approve(address(foldCaptiveStaking), type(uint256).max);

        foldCaptiveStaking.deposit(1_000 ether, 1_000 ether, 0);
        (uint128 amount, uint128 rewardDebt, uint128 token0FeeDebt, uint128 token1FeeDebt) =
            foldCaptiveStaking.balances(User01);

        assertGt(amount, 0);
        assertEq(rewardDebt, 0);
        assertEq(token0FeeDebt, 0);
        assertEq(token1FeeDebt, 0);
    }

    /// @dev Ensure that balances and state variables are updated correctly.
    function testRemoveLiquidity() public {
        testAddLiquidity();

        // Simulate passage of cooldown period
        vm.warp(block.timestamp + 14 days);

        (uint128 amount, uint128 rewardDebt, uint128 token0FeeDebt, uint128 token1FeeDebt) =
            foldCaptiveStaking.balances(User01);

        (uint128 liq,,,) = foldCaptiveStaking.balances(User01);
        foldCaptiveStaking.withdraw(liq / 2);

        (amount, rewardDebt, token0FeeDebt, token1FeeDebt) = foldCaptiveStaking.balances(User01);

        assertEq(amount, liq / 2);
        assertEq(rewardDebt, 0);
        assertEq(token0FeeDebt, 0);
        assertEq(token1FeeDebt, 0);

        foldCaptiveStaking.withdraw(liq / 4);

        (amount,,,) = foldCaptiveStaking.balances(User01);

        assertEq(amount, liq / 4);
    }

    /// @dev Ensure fees are accrued correctly and distributed proportionately.
    function testFeesAccrue() public {
        testAddLiquidity();

        vm.deal(User01, 10 ether);
        weth.deposit{value: 10 ether}();
        weth.approve(address(router), type(uint256).max);

        ISwapRouter.ExactInputSingleParams memory params = ISwapRouter.ExactInputSingleParams({
            tokenIn: address(weth),
            tokenOut: address(fold),
            fee: 10_000,
            recipient: msg.sender,
            deadline: block.timestamp,
            amountIn: 10 ether,
            amountOutMinimum: 0,
            sqrtPriceLimitX96: 0
        });

        // The call to `exactInputSingle` executes the swap.
        uint256 amountOut = router.exactInputSingle(params);
        assertGt(amountOut, 0);

        foldCaptiveStaking.collectFees();

        assertGt(foldCaptiveStaking.token0FeesPerLiquidity(), 0);

        fold.approve(address(router), type(uint256).max);

        params = ISwapRouter.ExactInputSingleParams({
            tokenIn: address(fold),
            tokenOut: address(weth),
            fee: 10_000,
            recipient: msg.sender,
            deadline: block.timestamp,
            amountIn: 10 ether,
            amountOutMinimum: 0,
            sqrtPriceLimitX96: 0
        });

        // The call to `exactInputSingle` executes the swap.
        amountOut = router.exactInputSingle(params);
        assertGt(amountOut, 0);

        foldCaptiveStaking.collectFees();
        assertGt(foldCaptiveStaking.token0FeesPerLiquidity(), 0);
        assertGt(foldCaptiveStaking.token1FeesPerLiquidity(), 0);
    }

    /// @dev Ensure fees are compounded correctly and state variables are updated.
    function testCanCompoundFees() public {
        testAddLiquidity();

        vm.deal(User01, 10 ether);
        weth.deposit{value: 10 ether}();
        weth.approve(address(router), type(uint256).max);

        ISwapRouter.ExactInputSingleParams memory params = ISwapRouter.ExactInputSingleParams({
            tokenIn: address(weth),
            tokenOut: address(fold),
            fee: 10_000,
            recipient: msg.sender,
            deadline: block.timestamp,
            amountIn: 10 ether,
            amountOutMinimum: 0,
            sqrtPriceLimitX96: 0
        });

        // The call to `exactInputSingle` executes the swap.
        uint256 amountOut = router.exactInputSingle(params);
        assertGt(amountOut, 0);

        fold.approve(address(router), type(uint256).max);

        params = ISwapRouter.ExactInputSingleParams({
            tokenIn: address(fold),
            tokenOut: address(weth),
            fee: 10_000,
            recipient: msg.sender,
            deadline: block.timestamp,
            amountIn: 10 ether,
            amountOutMinimum: 0,
            sqrtPriceLimitX96: 0
        });

        // The call to `exactInputSingle` executes the swap.
        amountOut = router.exactInputSingle(params);

        (uint128 amount,,,) = foldCaptiveStaking.balances(User01);

        foldCaptiveStaking.compound();

        (uint128 newAmount,,,) = foldCaptiveStaking.balances(User01);

        assertGt(newAmount, amount);
    }

    /// @dev Ensure new users can't steal fees accrued by others.
    function testNewUsersDontStealFees() public {
        testFeesAccrue();

        assertGt(foldCaptiveStaking.token0FeesPerLiquidity(), 0);
        assertGt(foldCaptiveStaking.token1FeesPerLiquidity(), 0);
        vm.stopPrank();

        fold.transfer(User02, 100 ether);

        vm.deal(User02, 100 ether);
        vm.startPrank(User02);

        weth.deposit{value: 100 ether}();
        weth.approve(address(foldCaptiveStaking), type(uint256).max);
        fold.approve(address(foldCaptiveStaking), type(uint256).max);

        foldCaptiveStaking.deposit(10 ether, 10 ether, 0);

        (,, uint128 token0FeeDebt, uint128 token1FeeDebt) = foldCaptiveStaking.balances(User02);

        assertEq(token0FeeDebt, foldCaptiveStaking.token0FeesPerLiquidity());
        assertEq(token1FeeDebt, foldCaptiveStaking.token1FeesPerLiquidity());
    }

    function testCannotCallbeforeInit() public {
        FoldCaptiveStaking stakingTwo =
            new FoldCaptiveStaking(address(positionManager), address(pool), address(weth), address(fold));

        vm.expectRevert(NotInitialized.selector);
        stakingTwo.deposit(0, 0, 0);

        vm.expectRevert(NotInitialized.selector);
        stakingTwo.withdraw(0);

        vm.expectRevert(NotInitialized.selector);
        stakingTwo.collectFees();

        vm.expectRevert(NotInitialized.selector);
        stakingTwo.collectRewards();

        vm.expectRevert(NotInitialized.selector);
        stakingTwo.compound();

        vm.expectRevert(NotInitialized.selector);
        stakingTwo.depositRewards();
    }

    /// @dev Ensure rewards are added and collected correctly.
    function testCanAddRewards() public {
        testAddLiquidity();

        vm.deal(User01, 1000 ether);

        uint256 initialGlobalRewards = foldCaptiveStaking.rewardsPerLiquidity();
        (, uint256 rewardDebt,,) = foldCaptiveStaking.balances(User01);
        assertEq(rewardDebt, 0);

        foldCaptiveStaking.depositRewards{value: 1000 ether}();

        assertEq(foldCaptiveStaking.rewardsPerLiquidity(), 1000 ether);
        assertGt(foldCaptiveStaking.rewardsPerLiquidity(), initialGlobalRewards);

        uint256 initialBalance = weth.balanceOf(User01);
        foldCaptiveStaking.collectRewards();

        (, rewardDebt,,) = foldCaptiveStaking.balances(User01);
        assertEq(rewardDebt, foldCaptiveStaking.rewardsPerLiquidity());
        assertGt(weth.balanceOf(User01), initialBalance);

        // Simulate passage of cooldown period
        vm.warp(block.timestamp + 14 days);

        (uint128 liq,,,) = foldCaptiveStaking.balances(User01);
        foldCaptiveStaking.withdraw(liq / 3);
    }

    /// @dev Ensure the owner can claim insurance correctly.
    function testClaimInsurance() public {
        testAddLiquidity();

        // Owner claims insurance
        uint128 liquidityToClaim = uint128(foldCaptiveStaking.liquidityUnderManagement() / 4);

        address owner = foldCaptiveStaking.owner();
        vm.startPrank(owner);
        uint256 initialToken0Balance = fold.balanceOf(owner);
        uint256 initialToken1Balance = weth.balanceOf(owner);

        foldCaptiveStaking.claimInsurance(liquidityToClaim);

        assertGt(fold.balanceOf(owner), initialToken0Balance);
        assertGt(weth.balanceOf(owner), initialToken1Balance);

        vm.stopPrank();
    }

    /// @dev Ensure pro-rata withdrawals are handled correctly
    function testProRataWithdrawals() public {
        testAddLiquidity();

        (uint128 liq,,,) = foldCaptiveStaking.balances(User01);

        // Attempt to withdraw more than allowed amount
        vm.expectRevert(WithdrawProRata.selector);
        foldCaptiveStaking.withdraw(liq);

        // Pro-rated withdrawal
        foldCaptiveStaking.withdraw(liq / 2);
        (uint128 amount,,,) = foldCaptiveStaking.balances(User01);
        assertEq(amount, liq / 2);
    }

    /// @dev Ensure zero deposits are handled correctly and revert as expected.
    function testZeroDeposit() public {
        vm.expectRevert();
        foldCaptiveStaking.deposit(0, 0, 0);
        (uint128 amount,,,) = foldCaptiveStaking.balances(User01);
        assertEq(amount, 0);
    }

    /// @dev Ensure the contract is protected against reentrancy attacks.
    function testReentrancy() public {
        testAddLiquidity();

        // Create a reentrancy attack contract and attempt to exploit the staking contract
        ReentrancyAttack attack = new ReentrancyAttack(payable(address(foldCaptiveStaking)));
        fold.transfer(address(attack), 1 ether);
        weth.transfer(address(attack), 1 ether);

        vm.expectRevert();
        attack.attack();
    }

    function testMinimumDeposit() public {
        fold.transfer(User01, 0.5 ether);

        vm.deal(User01, 0.5 ether);
        vm.startPrank(User01);

        weth.deposit{value: 0.5 ether}();
        weth.approve(address(foldCaptiveStaking), type(uint256).max);
        fold.approve(address(foldCaptiveStaking), type(uint256).max);

        // Expect revert due to minimum deposit requirement
        vm.expectRevert(DepositAmountBelowMinimum.selector);
        foldCaptiveStaking.deposit(0.5 ether, 0.5 ether, 0);
    /// @dev Deposit Cap Enforcement: Test to ensure the deposit cap is respected.
    function testDepositCap() public {
        uint256 cap = 100 ether;
        foldCaptiveStaking.setDepositCap(cap);

        fold.transfer(User01, 2000 ether);

        vm.deal(User01, 2000 ether);
        vm.startPrank(User01);

        weth.deposit{value: 2000 ether}();
        weth.approve(address(foldCaptiveStaking), type(uint256).max);
        fold.approve(address(foldCaptiveStaking), type(uint256).max);

        // First deposit should succeed
        foldCaptiveStaking.deposit(1_000 ether, 1_000 ether, 0);

        // Second deposit should revert due to cap
        vm.expectRevert(DepositCapReached.selector);
        foldCaptiveStaking.deposit(1_000 ether, 1_000 ether, 0);

        vm.stopPrank();
    }

    function testWithdrawalCooldown() public {
        testAddLiquidity();

        vm.startPrank(User01);

        (uint128 liq,,,) = foldCaptiveStaking.balances(User01);

        // Attempt to withdraw before cooldown period
        vm.expectRevert(WithdrawalCooldownPeriodNotMet.selector);
        foldCaptiveStaking.withdraw(liq / 2);

        // Simulate passage of cooldown period
        vm.warp(block.timestamp + 14 days);

        // Withdraw after cooldown period
        foldCaptiveStaking.withdraw(liq / 2);
        (uint128 amount,,,) = foldCaptiveStaking.balances(User01);
    /// @dev Multiple Users: Test simultaneous deposits and withdrawals by multiple users.
    function testMultipleUsersDepositWithdraw() public {
        // User 1 deposits
        fold.transfer(User01, 1_000 ether);
        vm.deal(User01, 1_000 ether);
        vm.startPrank(User01);

        weth.deposit{value: 1_000 ether}();
        weth.approve(address(foldCaptiveStaking), type(uint256).max);
        fold.approve(address(foldCaptiveStaking), type(uint256).max);

        foldCaptiveStaking.deposit(1_000 ether, 1_000 ether, 0);

        vm.stopPrank();

        // User 2 deposits
        fold.transfer(User02, 500 ether);
        vm.deal(User02, 500 ether);
        vm.startPrank(User02);

        weth.deposit{value: 500 ether}();
        weth.approve(address(foldCaptiveStaking), type(uint256).max);
        fold.approve(address(foldCaptiveStaking), type(uint256).max);

        foldCaptiveStaking.deposit(500 ether, 500 ether, 0);

        vm.stopPrank();

        // User 1 withdraws
        vm.startPrank(User01);

        (uint128 liq,,,) = foldCaptiveStaking.balances(User01);
        foldCaptiveStaking.withdraw(liq / 2);

        (uint128 amount,,,) = foldCaptiveStaking.balances(User01);
        assertEq(amount, liq / 2);

        vm.stopPrank();

        // User 2 withdraws
        vm.startPrank(User02);

        (liq,,,) = foldCaptiveStaking.balances(User02);
        foldCaptiveStaking.withdraw(liq / 2);

        (amount,,,) = foldCaptiveStaking.balances(User02);
        assertEq(amount, liq / 2);

        vm.stopPrank();
    }
}

// Reentrancy attack contract
contract ReentrancyAttack {
    FoldCaptiveStaking public staking;

    constructor(address payable _staking) {
        staking = FoldCaptiveStaking(_staking);
    }

    function attack() public {
        staking.deposit(1 ether, 1 ether, 0);
        staking.withdraw(1);
    }

    receive() external payable {
        staking.withdraw(1);
    }
}
