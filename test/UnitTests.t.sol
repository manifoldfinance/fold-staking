
pragma solidity 0.8.25;

import "test/BaseCaptiveTest.sol";

contract UnitTests is BaseCaptiveTest {
  address public User01 = address(0x1);

  function testAddLiquidity() public {
    fold.transfer(User01, 1_000 ether);

    vm.deal(User01, 1_000 ether);
    vm.startPrank(User01);

    weth.deposit{value: 1_000 ether}();
    weth.approve(address(foldCaptiveStaking), type(uint256).max);
    fold.approve(address(foldCaptiveStaking), type(uint256).max);

    foldCaptiveStaking.deposit(1_000 ether, 1_000 ether, 0);
  }

  function testRemoveLiquidity() public {
    testAddLiquidity();
    
    (uint128 liq, , ,) = foldCaptiveStaking.balances(User01);
    foldCaptiveStaking.withdraw(liq / 2);

  }
}
