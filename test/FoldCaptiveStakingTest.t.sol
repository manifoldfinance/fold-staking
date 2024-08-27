// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.13;

import "forge-std/Test.sol";
import "../src/FoldCaptiveStaking.sol";
import {ERC20} from "lib/solmate/src/tokens/ERC20.sol";
import {IERC20} from "../src/interfaces/IERC20.sol";
import {INonfungiblePositionManager} from "../src/interfaces/INonfungiblePositionManager.sol";

contract FoldCaptiveStakingTest is Test {
    FoldCaptiveStaking public staking;
    IERC20 public token0;
    IERC20 public token1;
    INonfungiblePositionManager public positionManager;

    address public owner = address(1);

    function setUp() public {
        vm.startPrank(owner);
        token0 = IERC20(address(new ERC20Mock()));
        token1 = IERC20(address(new ERC20Mock()));
        positionManager = INonfungiblePositionManager(address(new PositionManagerMock()));
        staking = new FoldCaptiveStaking(address(token0), address(token1), address(positionManager), owner);
        vm.stopPrank();
    }

    function testInitialize() public {
        vm.startPrank(owner);
        staking.initialize();
        assertTrue(staking.initialized());
        assertEq(staking.TOKEN_ID(), 1);
        assertGt(staking.liquidityUnderManagement(), 0);
        vm.stopPrank();
    }

    function testInitializeRevertOnSecondCall() public {
        vm.startPrank(owner);
        staking.initialize();
        vm.expectRevert(FoldCaptiveStaking.AlreadyInitialized.selector);
        staking.initialize();
        vm.stopPrank();
    }

    function testInitializeRevertOnZeroLiquidity() public {
        vm.startPrank(owner);
        PositionManagerMock(address(positionManager)).setMintLiquidity(0);
        vm.expectRevert(FoldCaptiveStaking.ZeroLiquidity.selector);
        staking.initialize();
        vm.stopPrank();
    }

    function testInitializeOnlyOwner() public {
        vm.prank(address(2));
        vm.expectRevert("Ownable: caller is not the owner");
        staking.initialize();
    }
}

contract ERC20Mock is ERC20 {
    constructor() ERC20("Mock Token", "MTK", 18) {
        _mint(msg.sender, 1000000 * 10**uint256(decimals));
    }
}

contract PositionManagerMock {
    uint256 public tokenIdCounter = 1;
    uint128 public liquidityToMint = 1000;

    function mint(INonfungiblePositionManager.MintParams memory) external returns (uint256 tokenId, uint128 liquidity, uint256, uint256) {
        tokenId = tokenIdCounter++;
        liquidity = liquidityToMint;
        return (tokenId, liquidity, 0, 0);
    }

    function setMintLiquidity(uint128 _liquidity) external {
        liquidityToMint = _liquidity;
    }
}
