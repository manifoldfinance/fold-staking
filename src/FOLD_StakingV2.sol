/// SPDX-License-Identifier: SSPL-1.0
pragma solidity 0.8.26;

// Authorization and Authentication

import {Owned} from "lib/solmate/src/auth/Owned.sol";

/// contracts
import {WETH} from "lib/solady/src/tokens/WETH.sol";
import {ERC20} from "lib/solady/src/tokens/ERC20.sol";


/// Interfaces
import {INonfungiblePositionManager} from "./interfaces/INonfungiblePositionManager.sol";
import {IUniswapV3MintCallback} from "./interfaces/IUniswapV3MintCallback.sol";
import {IUniswapV3Factory} from "./interfaces/IUniswapV3Factory.sol";
import {IUniswapV3Pool} from "./interfaces/IUniswapV3Pool.sol";

/// Libraries
import {TickMath} from "./libraries/TickMath.sol";





/// @author CopyPaste
/// @title FoldCaptiveStakingV2
/// @notice Staking contract for managing FOLD token liquidity on Uniswap V3
contract FoldCaptiveStakingV2 is Owned(msg.sender) {
    /*//////////////////////////////////////////////////////////////
                             INITIALIZATION
    //////////////////////////////////////////////////////////////*/
    bool public initialized;

    // Events
    event Initialized();
    event Deposit(address indexed user, uint256 amount0, uint256 amount1);
    event Withdraw(address indexed user, uint128 liquidity);
    event RewardsDeposited(uint256 amount);
    event FeesCollected(address indexed user, uint256 fee0Owed, uint256 fee1Owed);
    event RewardsCollected(address indexed user, uint256 rewardsOwed);
    event Compounded(address indexed user, uint128 liquidity, uint256 fee0Owed, uint256 fee1Owed);
    event InsuranceClaimed(address indexed owner, uint256 amount0, uint256 amount1);

    /// Custom Errors
    error ZeroAddress();
    error AlreadyInitialized();
    error NotInitialized();
    error ZeroLiquidity();
    error WithdrawFailed();
    error DepositCapReached();
    error DepositAmountBelowMinimum();
    error WithdrawalCooldownPeriodNotMet();

    /// @param _positionManager The Canonical UniswapV3 PositionManager
    /// @param _pool The FOLD Pool to Reward
    /// @param _weth The address of WETH on the deployed chain
    /// @param _fold The address of Fold on the deployed chain
    constructor(address _positionManager, address _pool, address _weth, address _fold) {
        if (_positionManager == address(0) || _pool == address(0) || _weth == address(0) || _fold == address(0)) {
            revert ZeroAddress();
        }

        positionManager = INonfungiblePositionManager(_positionManager);
        POOL = IUniswapV3Pool(_pool);

        token0 = ERC20(POOL.token0());
        token1 = ERC20(POOL.token1());

        WETH9 = WETH(payable(_weth));
        FOLD = ERC20(_fold);

        initialized = false;
    }

    /// @notice Initialize the contract by minting a small initial liquidity position
    function initialize() public onlyOwner {
        if (initialized) {
            revert AlreadyInitialized();
        }

        // We must mint the pool a small dust LP position, which also prevents share attacks
        // So this is our "minimum shares"
        INonfungiblePositionManager.MintParams memory params = INonfungiblePositionManager.MintParams({
            token0: address(token0),
            token1: address(token1),
            fee: 10000,
            tickLower: -887_200,
            tickUpper: 887_200,
            amount0Desired: 1_000_000,
            amount1Desired: 1_000_000,
            amount0Min: 0,
            amount1Min: 0,
            recipient: address(this),
            deadline: block.timestamp + 1 minutes
        });

        token0.approve(address(positionManager), type(uint256).max);
        token1.approve(address(positionManager), type(uint256).max);

        uint128 liquidity;
        (TOKEN_ID, liquidity,,) = positionManager.mint(params);
        if (liquidity == 0) {
            revert ZeroLiquidity();
        }

        liquidityUnderManagement += uint256(liquidity);

        initialized = true;
        emit Initialized();
    }

    modifier isInitialized() {
        if (!initialized) {
            revert NotInitialized();
        }
        _;
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
    /// @dev The FOLD <> {WETH, USDC} Liquidity Pool
    IUniswapV3Pool public immutable POOL;
    /// @dev token0 In terms of the Uniswap Pool
    ERC20 public immutable token0;
    /// @dev token1 in terms of the Uniswap Pool
    ERC20 public immutable token1;
    /// @dev The tokenId of the UniswapV3 position
    uint256 public TOKEN_ID;
    /// @dev Used for all rewards related tracking
    uint256 public liquidityUnderManagement;
    /// @dev Used to keep track of rewards given per share
    uint256 public rewardsPerLiquidity;
    /// @dev For keeping track of position fees
    uint256 public token0FeesPerLiquidity;
    /// @dev For keeping track of positions fees
    uint256 public token1FeesPerLiquidity;

    /// @dev The cap on deposits in the pool in liquidity, set to 0 if no cap
    uint256 public depositCap;

    /// @dev Min deposit amount for Fold / Eth
    uint256 public constant MINIMUM_DEPOSIT = 1 ether;
    /// @dev Min lockup period
    uint256 public constant COOLDOWN_PERIOD = 14 days;

    mapping(address => uint256) public depositTimeStamp;

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

    /// @dev The Canonical WETH address
    WETH public immutable WETH9;
    ERC20 public immutable FOLD;

    /// @notice Allows anyone to add funds to the contract, split among all depositors
    function depositRewards() public payable isInitialized {
        WETH9.deposit{value: msg.value}();
        rewardsPerLiquidity += msg.value;
        emit RewardsDeposited(msg.value);
    }

    receive() external payable {
        depositRewards();
    }

    /*//////////////////////////////////////////////////////////////
                               MANAGEMENT
    //////////////////////////////////////////////////////////////*/

    /// @notice Allows a user to deposit liquidity into the pool
    /// @param amount0 The amount of token0 to deposit
    /// @param amount1 The amount of token1 to deposit
    /// @param slippage Slippage on deposit out of 1e18
    function deposit(uint256 amount0, uint256 amount1, uint256 slippage) external isInitialized {
        if (amount0 < MINIMUM_DEPOSIT && amount1 < MINIMUM_DEPOSIT) revert DepositAmountBelowMinimum();

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

        token0.transferFrom(msg.sender, address(this), amount0);
        token1.transferFrom(msg.sender, address(this), amount1);

        (uint128 liquidity, uint256 actualAmount0, uint256 actualAmount1) = positionManager.increaseLiquidity(params);

        if (actualAmount0 < amount0) {
            token0.transfer(msg.sender, amount0 - actualAmount0);
        }
        if (actualAmount1 < amount1) {
            token1.transfer(msg.sender, amount1 - actualAmount1);
        }

        balances[msg.sender].amount += liquidity;
        liquidityUnderManagement += uint256(liquidity);

        if (liquidityUnderManagement > depositCap && depositCap != 0) {
            revert DepositCapReached();
        }

        depositTimeStamp[msg.sender] = block.timestamp;

        emit Deposit(msg.sender, amount0, amount1);
    }

    /// @notice Compounds User Earned Fees back into their position
    function compound() public isInitialized {
        collectPositionFees();

        uint256 fee0Owed = (token0FeesPerLiquidity - balances[msg.sender].token0FeeDebt) * balances[msg.sender].amount
            / liquidityUnderManagement;
        uint256 fee1Owed = (token1FeesPerLiquidity - balances[msg.sender].token1FeeDebt) * balances[msg.sender].amount
            / liquidityUnderManagement;

        INonfungiblePositionManager.IncreaseLiquidityParams memory params = INonfungiblePositionManager
            .IncreaseLiquidityParams({
            tokenId: TOKEN_ID,
            amount0Desired: fee0Owed,
            amount1Desired: fee1Owed,
            amount0Min: 0,
            amount1Min: 0,
            deadline: block.timestamp + 1 minutes
        });

        (uint128 liquidity, uint256 actualAmount0, uint256 actualAmount1) = positionManager.increaseLiquidity(params);

        token0.transfer(msg.sender, fee0Owed - actualAmount0);
        token1.transfer(msg.sender, fee1Owed - actualAmount1);

        balances[msg.sender].token0FeeDebt = uint128(token0FeesPerLiquidity);
        balances[msg.sender].token1FeeDebt = uint128(token1FeesPerLiquidity);

        balances[msg.sender].amount += liquidity;
        liquidityUnderManagement += uint256(liquidity);

        emit Compounded(msg.sender, liquidity, fee0Owed, fee1Owed);
    }

    /// @notice User-specific function to collect fees on the singular position
    function collectFees() public isInitialized {
        collectPositionFees();

        uint256 fee0Owed = (token0FeesPerLiquidity - balances[msg.sender].token0FeeDebt) * balances[msg.sender].amount
            / liquidityUnderManagement;
        uint256 fee1Owed = (token1FeesPerLiquidity - balances[msg.sender].token1FeeDebt) * balances[msg.sender].amount
            / liquidityUnderManagement;

        token0.transfer(msg.sender, fee0Owed);
        token1.transfer(msg.sender, fee1Owed);

        balances[msg.sender].token0FeeDebt = uint128(token0FeesPerLiquidity);
        balances[msg.sender].token1FeeDebt = uint128(token1FeesPerLiquidity);

        emit FeesCollected(msg.sender, fee0Owed, fee1Owed);
    }

    /// @notice User-specific Rewards for Protocol Rewards
    function collectRewards() public isInitialized {
        uint256 rewardsOwed = (rewardsPerLiquidity - balances[msg.sender].rewardDebt) * balances[msg.sender].amount
            / liquidityUnderManagement;

        WETH9.transfer(msg.sender, rewardsOwed);

        balances[msg.sender].rewardDebt = uint128(rewardsPerLiquidity);

        emit RewardsCollected(msg.sender, rewardsOwed);
    }

    /// @notice Withdraws liquidity from the pool
    /// @param liquidity The amount of liquidity to withdraw
    function withdraw(uint128 liquidity) external isInitialized {
        if (block.timestamp < depositTimeStamp[msg.sender] + COOLDOWN_PERIOD) revert WithdrawalCooldownPeriodNotMet();

        collectFees();
        collectRewards();

        balances[msg.sender].amount -= liquidity;
        liquidityUnderManagement -= uint256(liquidity);

        INonfungiblePositionManager.DecreaseLiquidityParams memory decreaseParams = INonfungiblePositionManager
            .DecreaseLiquidityParams({
            tokenId: TOKEN_ID,
            liquidity: liquidity,
            amount0Min: 0,
            amount1Min: 0,
            deadline: block.timestamp + 1 minutes
        });

        (uint256 amount0, uint256 amount1) = positionManager.decreaseLiquidity(decreaseParams);

        INonfungiblePositionManager.CollectParams memory collectParams = INonfungiblePositionManager.CollectParams({
            tokenId: TOKEN_ID,
            recipient: address(this),
            amount0Max: uint128(amount0),
            amount1Max: uint128(amount1)
        });

        (uint256 amount0Collected, uint256 amount1Collected) = positionManager.collect(collectParams);

        if (amount0Collected != amount0 || amount1Collected != amount1) {
            revert WithdrawFailed();
        }

        token0.transfer(msg.sender, amount0);
        token1.transfer(msg.sender, amount1);

        emit Withdraw(msg.sender, liquidity);
    }

    /*//////////////////////////////////////////////////////////////
                            INTERNAL HELPERS
    //////////////////////////////////////////////////////////////*/

    /// @notice Collects fees on the underling UniswapV3 Position
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

    /*//////////////////////////////////////////////////////////////
                             OWNER CONTROLS
    //////////////////////////////////////////////////////////////*/
    /// @param _newCap The new deposit cap, measured in liquidity
    function setDepositCap(uint256 _newCap) public onlyOwner {
        depositCap = _newCap;
    }

    /// @notice Allows the owner to claim insurance in case of relay outage
    /// @param liquidity The amount of liquidity to claim
    function claimInsurance(uint128 liquidity) external onlyOwner {
        collectPositionFees();
        collectRewards();

        liquidityUnderManagement -= uint256(liquidity);

        INonfungiblePositionManager.DecreaseLiquidityParams memory decreaseParams = INonfungiblePositionManager
            .DecreaseLiquidityParams({
            tokenId: TOKEN_ID,
            liquidity: liquidity,
            amount0Min: 0,
            amount1Min: 0,
            deadline: block.timestamp + 1 minutes
        });

        (uint256 amount0, uint256 amount1) = positionManager.decreaseLiquidity(decreaseParams);

        INonfungiblePositionManager.CollectParams memory collectParams = INonfungiblePositionManager.CollectParams({
            tokenId: TOKEN_ID,
            recipient: address(this),
            amount0Max: uint128(amount0),
            amount1Max: uint128(amount1)
        });

        (uint256 amount0Collected, uint256 amount1Collected) = positionManager.collect(collectParams);

        if (amount0Collected != amount0 || amount1Collected != amount1) {
            revert WithdrawFailed();
        }

        token0.transfer(owner, amount0);
        token1.transfer(owner, amount1);

        emit InsuranceClaimed(owner, amount0, amount1);
    }
}
