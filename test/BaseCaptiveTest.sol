/// SPDX-License-Identifier: SSPL-1.-0
pragma solidity ^0.8.26;

import "src/FoldCaptiveStaking.sol";
import {Test} from "forge-std/Test.sol";

contract BaseCaptiveTest is Test {
    /// Custom Errors
    error ZeroAddress();
    error AlreadyInitialized();
    error NotInitialized();
    error ZeroLiquidity();
    error WithdrawFailed();
    error DepositAmountBelowMinimum();
    error WithdrawalCooldownPeriodNotMet();
    error WithdrawProRata();
    error DepositCapReached();

    FoldCaptiveStaking public foldCaptiveStaking;

    INonfungiblePositionManager public positionManager =
        INonfungiblePositionManager(0xC36442b4a4522E871399CD717aBDD847Ab11FE88);
    IUniswapV3Pool public pool = IUniswapV3Pool(0x5eCEf3b72Cb00DBD8396EBAEC66E0f87E9596e97);
    WETH public weth = WETH(payable(0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2));
    ERC20 public fold = ERC20(0xd084944d3c05CD115C09d072B9F44bA3E0E45921);

    address public User01 = address(0x1);
    address public User02 = address(0x2);

    function setUp() public {
        uint256 mainnetFork = vm.createFork("https://rpc.ankr.com/eth", 20185705);
        vm.selectFork(mainnetFork);

        address self = address(this);

        // Fold Whale
        vm.startPrank(0xA0766B65A4f7B1da79a1AF79aC695456eFa28644);
        fold.transfer(self, fold.balanceOf(address(0xA0766B65A4f7B1da79a1AF79aC695456eFa28644)));
        vm.stopPrank();

        vm.deal(address(this), 1_000_000 ether);
        weth.deposit{value: 1_000_000 ether}();

        foldCaptiveStaking =
            new FoldCaptiveStaking(address(positionManager), address(pool), address(weth), address(fold));

        fold.transfer(address(foldCaptiveStaking), 1_000_000);
        fold.transfer(address(User01), 100 ether);

        weth.transfer(address(foldCaptiveStaking), 1_000_000);

        foldCaptiveStaking.initialize();
    }
}
