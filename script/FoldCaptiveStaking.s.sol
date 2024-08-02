// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.19;

import "forge-std/Script.sol";
import {FoldCaptiveStaking} from "src/FoldCaptiveStaking.sol";

contract FoldCaptiveStakingScript is Script {
    INonfungiblePositionManager public positionManager =
        INonfungiblePositionManager(0xC36442b4a4522E871399CD717aBDD847Ab11FE88);
    IUniswapV3Pool public pool = IUniswapV3Pool(0x5eCEf3b72Cb00DBD8396EBAEC66E0f87E9596e97);
    WETH public weth = WETH(payable(0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2));
    ERC20 public fold = ERC20(0xd084944d3c05CD115C09d072B9F44bA3E0E45921);

    function run() public {
        vm.startBroadcast();
        foldCaptiveStaking =
            new FoldCaptiveStaking(address(positionManager), address(pool), address(weth), address(fold));

        fold.transfer(address(foldCaptiveStaking), 1_000_000);
        weth.transfer(address(foldCaptiveStaking), 1_000_000);

        foldCaptiveStaking.initialize();
        vm.stopBroadcast();
    }
}