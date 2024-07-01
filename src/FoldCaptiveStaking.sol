pragma solidity 0.8.25;

/// Interfaces
import {INonfungiblePositionManager} from "./interfaces/INonfungiblePositionManager.sol";
import {IUniswapV3MintCallback} from "./interfaces/IUniswapV3MintCallback.sol";
import {IUniswapV3Factory} from "./interfaces/IUniswapV3Factory.sol";
import {IUniswapV3Pool} from "./interfaces/IUniswapV3Pool.sol";

/// Libraries
import {TickMath} from "./libraries/TickMath.sol";

/// contracts
import {ERC20} from "lib/solmate/src/tokens/ERC20.sol";
import {Owned} from "lib/solmate/src/auth/Owned.sol";
import {WETH9} from "./contracts/WETH9.sol";

/// @author CopyPaste
/// @title FoldCaptiveStaking
contract FoldCaptiveStaking is Owned(msg.sender) {
    /*//////////////////////////////////////////////////////////////
                             INITIALIZATION
    //////////////////////////////////////////////////////////////*/

    constructor(address _positionManager, address _pool, address _weth, address _fold) {
        positionManager = INonfungiblePositionManager(_positionManager);
        POOL = IUniswapV3Pool(_pool);

        WETH = WETH9(payable(_weth));
        FOLD = ERC20(_fold);

        // We must mint the pool a small dust LP position, which also prevents share attacks
        // So this is our "minimum shares"
        INonfungiblePositionManager.MintParams memory params = INonfungiblePositionManager.MintParams({
            token0: address(FOLD),
            token1: address(WETH),
            fee: 10000,
            tickLower: TICK_LOWER,
            tickUpper: TICK_UPPER,
            amount0Desired: 10_000,
            amount1Desired: 10_000,
            amount0Min: 0,
            amount1Min: 0,
            recipient: address(this),
            deadline: block.timestamp + 1 minutes
        });

        WETH.approve(address(positionManager), type(uint256).max);
        FOLD.approve(address(positionManager), type(uint256).max);

        uint128 liquidity;
        (TOKEN_ID, liquidity,,) = positionManager.mint(params);
        require(liquidity > 0, "ZERO Liquidity");

        liquidityUnderManagement += uint256(liquidity);
    }

    /*//////////////////////////////////////////////////////////////
                                STORAGE
    //////////////////////////////////////////////////////////////*/

    /// @dev The max Tick of the position
    int24 public constant TICK_UPPER = TickMath.MAX_TICK;
    /// @dev The lower Tick of the position
    int24 public constant TICK_LOWER = TickMath.MIN_TICK;
    /// @dev The Canonical UniswapV3 Position Manager
    INonfungiblePositionManager public immutable positionManager;
    /// @dev The FOLD <> USDC Liquidity Pool
    IUniswapV3Pool public immutable POOL;
    /// @dev The tokenId of the UniswapV3 position
    uint256 public immutable TOKEN_ID;
    /// @dev Used for all rewards related tracking
    uint256 public liquidityUnderManagement;
    /// @dev Used to keep track of rewards given per share
    uint256 public rewardsPerLiquidity;
    /// @dev For keeping track of position fees
    uint256 public token0FeesPerLiquidity;
    /// @dev For keeping track of positions fees
    uint256 public token1FeesPerLiquidity;

    /*//////////////////////////////////////////////////////////////
                                  CHEF
    //////////////////////////////////////////////////////////////*/

    struct UserInfo {
        uint128 amount; // How much Liquidity provided by the User, as defined by UniswapV3.
        uint128 rewardDebt; // Reward debt. As in the Masterchef Sense
        uint128 token0FeeDebt;
        uint128 token1FeeDebt;
    }

    mapping(address user => UserInfo info) public balances;

    WETH9 public immutable WETH;
    ERC20 public immutable FOLD;

    function depositRewards() payable public {
      WETH.deposit(msg.value);
      rewardsPerLiquidity += msg.value;
    }

    /*//////////////////////////////////////////////////////////////
                               MANAGEMENT
    //////////////////////////////////////////////////////////////*/

    function deposit(uint256 amount0, uint256 amount1, uint256 slippage) external {
        collectFees();
        collectRewards();

        INonfungiblePositionManager.IncreaseLiquidityParams memory params = INonfungiblePositionManager
            .IncreaseLiquidityParams({
            tokenId: TOKEN_ID,
            amount0Desired: amount0,
            amount1Desired: amount1,
            amount0Min: amount0 * slippage / 1 ether,
            amount1Min: amount1 * slippage / 1 ether,
            deadline: block.timestamp + 1 minutes
        });

        FOLD.transferFrom(msg.sender, address(this), amount0);
        WETH.transferFrom(msg.sender, address(this), amount1);

        (uint128 liquidity, uint256 actualAmount0, uint256 actualAmount1) = positionManager.increaseLiquidity(params);

        if (actualAmount0 < amount0) {
            FOLD.transfer(msg.sender, amount0 - actualAmount0);
        }
        if (actualAmount1 < amount1) {
            WETH.transfer(msg.sender, amount1 - actualAmount1);
        }

        balances[msg.sender].amount += liquidity;
        liquidityUnderManagement += uint256(liquidity);
    }

    function collectFees() public {
        collectPositionFees();

        uint256 fee0Owed = (token0FeesPerLiquidity - balances[msg.sender].token0FeeDebt) * balances[msg.sender].amount
            / liquidityUnderManagement;
        uint256 fee1Owed = token1FeesPerLiquidity
            - balances[msg.sender].token1FeeDebt * balances[msg.sender].amount / liquidityUnderManagement;

        FOLD.transfer(msg.sender, fee0Owed);
        WETH.transfer(msg.sender, fee1Owed);

        balances[msg.sender].token0FeeDebt = uint128(token0FeesPerLiquidity);
        balances[msg.sender].token1FeeDebt = uint128(token1FeesPerLiquidity);
    }

    function collectRewards() public {
        uint256 rewardsOwed = (rewardsPerLiquidity - balances[msg.sender].rewardDebt) * balances[msg.sender].amount
            / liquidityUnderManagement;
        WETH.transfer(msg.sender, rewardsOwed);

        balances[msg.sender].rewardDebt = uint128(rewardsPerLiquidity);
    }

    function withdraw(uint128 liquidity) external {
        collectFees();
        collectRewards();

        balances[msg.sender].amount -= liquidity;
        liquidityUnderManagement += uint256(liquidity);

        INonfungiblePositionManager.DecreaseLiquidityParams memory params = INonfungiblePositionManager
            .DecreaseLiquidityParams({
            tokenId: TOKEN_ID,
            liquidity: liquidity,
            amount0Min: 0,
            amount1Min: 0,
            deadline: block.timestamp + 1 minutes
        });

        (uint256 amount0, uint256 amount1) = positionManager.decreaseLiquidity(params);

        FOLD.transfer(msg.sender, amount0);
        WETH.transfer(msg.sender, amount1);
    }

    /*//////////////////////////////////////////////////////////////
                            INTERNAL HELPERS
    //////////////////////////////////////////////////////////////*/
    function collectPositionFees() internal {
        INonfungiblePositionManager.CollectParams memory params = INonfungiblePositionManager.CollectParams({
            tokenId: TOKEN_ID,
            recipient: address(this),
            amount0Max: type(uint128).max,
            amount1Max: type(uint128).max
        });

        (uint256 amount0Collected, uint256 amount1Collected) = positionManager.collect(params);

        token0FeesPerLiquidity += amount0Collected;
        token1FeesPerLiquidity += amount1Collected;
    }
}
