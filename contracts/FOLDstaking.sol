
// SPDX-License-Identifier: MIT

pragma solidity =0.8.8;

import "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC721/IERC721.sol";
import "@openzeppelin/contracts/token/ERC721/IERC721Receiver.sol";

/**
 * @title Captive Insurance
 * @dev Lock users' Uniswap LP NFTs (V3 only) or creates an NFT for them 
 */

import "./Dependencies/SafeTransferLib.sol";
import "./Dependencies/TransferHelper.sol";

// Alternative way of working with pools instead of NFPM, used by Bunni
// isssue: does not return NFTid when minting, requires using own keys (abi.encode)
// import {IUniswapV3Pool} from "./Dependencies/IUniswapV3Pool.sol";
// import {TickMath, FullMath, LiquidityAmounts} from "./Dependencies/LiquidityAmounts.sol";

interface IWETH is IERC20 {
    function deposit() external payable;
    function withdraw(uint256 amount) external;
}

interface INonfungiblePositionManager is IERC721 { // reward QD<>USDT or QD<>WETH liquidity deposits
    
    struct MintParams {
        address token0;
        address token1;
        uint24 fee;
        int24 tickLower;
        int24 tickUpper;
        uint256 amount0Desired;
        uint256 amount1Desired;
        uint256 amount0Min;
        uint256 amount1Min;
        address recipient;
        uint256 deadline;
    }

    /// @notice Creates a new position wrapped in a NFT
    /// @dev Call this when the pool does exist and is initialized. Note that if the pool is created but not initialized
    /// a method does not exist, i.e. the pool is assumed to be initialized.
    /// @param params The params necessary to mint a position, encoded as `MintParams` in calldata
    /// @return tokenId The ID of the token that represents the minted position
    /// @return liquidity The amount of liquidity for this position
    /// @return amount0 The amount of token0
    /// @return amount1 The amount of token1
    function mint(MintParams calldata params)
        external
        payable
        returns (
            uint256 tokenId,
            uint128 liquidity,
            uint256 amount0,
            uint256 amount1
        );

    function positions(uint tokenId) external
    view returns (uint96 nonce,address operator,
        address token0, address token1, uint24 fee,
        int24 tickLower, int24 tickUpper, uint128 liquidity,
        uint feeGrowthInside0LastX128,
        uint feeGrowthInside1LastX128,
        uint128 tokensOwed0, uint128 tokensOwed1
    );
}

/// @title Callback for IUniswapV3PoolActions#mint
/// @notice Any contract that calls IUniswapV3PoolActions#mint must implement this interface
// interface IUniswapV3MintCallback {
//     /// @notice Called to `msg.sender` after minting liquidity to a position from IUniswapV3Pool#mint.
//     /// @dev In the implementation you must pay the pool tokens owed for the minted liquidity.
//     /// The caller of this method must be checked to be a UniswapV3Pool deployed by the canonical UniswapV3Factory.
//     /// @param amount0Owed The amount of token0 due to the pool for the minted liquidity
//     /// @param amount1Owed The amount of token1 due to the pool for the minted liquidity
//     /// @param data Any data passed through by the caller via the IUniswapV3PoolActions#mint call
//     function uniswapV3MintCallback(
//         uint256 amount0Owed,
//         uint256 amount1Owed,
//         bytes calldata data
//     ) external;
// }

// ERC20 represents the shareToken  
contract FOLDstaking is IERC721Receiver {
    
    using SafeTransferLib for IERC20;
    using SafeTransferLib for IWETH;

    /// @notice Inidicates if staking is paused.
    bool public stakingPaused;

    // minimum duration of being in the vault before withdraw can be called (triggering reward payment)
    
    uint public minLockDuration;
    uint public minDeposit;
    uint public weeklyReward;
    uint public immutable deployed; // timestamp when contract was deployed
    
    address[] public owners;
    mapping(address => bool) public isOwner;
    mapping(uint => uint) public totalsUSDC; // week # -> liquidity
    uint public liquidityUSDC; // in UniV3 liquidity units
    uint public maxTotalUSDC; // in the same units

    mapping(uint => uint) public totalsETH; // week # -> liquidity
    uint public liquidityETH; // for the WETH<>FOLD pool
    uint public maxTotalWETH;

    INonfungiblePositionManager public immutable nonfungiblePositionManager;

    struct Transaction {
        address to;
        uint value;
        address token;
        bool executed;
        uint confirm;
    }   Transaction[] public transactions;
    mapping(uint => mapping(address => bool)) public confirmed;

    // You can have multiple positions per address (representing different ranges).
    
    mapping(address => LP) totals;

    struct LP { // total LP deposit, including both NFT deposits, and the other kind
        uint fold;
        uint usdc;
        uint weth;
    }
    mapping(address => mapping(uint => uint)) public depositTimestamps; // owner => NFTid => amount

    // ERC20 addresses (mainnet) of tokens
    address constant FOLD = 0xd084944d3c05CD115C09d072B9F44bA3E0E45921;
    address constant USDC = 0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48;
    address constant WETH = 0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2;
    
    // Pools addresses (mainnet) so we don't need to import IUniswapV3Factory
    address constant FOLD_WETH = 0x5eCEf3b72Cb00DBD8396EBAEC66E0f87E9596e97;
    address constant FOLD_USDC = 0xe081EEAB0AdDe30588bA8d5B3F6aE5284790F54A;

    // Uniswap's NonFungiblePositionManager (one for all new pools)
    address constant NFPM = 0xC36442b4a4522E871399CD717aBDD847Ab11FE88;

    uint constant public WAD = 1e18; 
    uint constant HOURS_PER_WEEK = 168;
    uint public minDuration;

    error UnsupportedToken();
    error StakingPaused();

    event SetWeeklyReward(uint reward);
    event SetMinDuration(uint duration);
    event SetMinDeposit(uint _minDeposit);

    event SetMaxTotalUSDC(uint maxTotal);
    event SetMaxTotalWETH(uint maxTotal);

    event DepositNFT(uint tokenId, address owner);
    event Withdrawal(uint tokenId, address owner, uint rewardPaid);
    
    event ConfirmTransfer(address indexed owner, uint indexed index);
    event RevokeTransfer(address indexed owner, uint indexed index);
    event ExecuteTransfer(address indexed owner, uint indexed index);
    event SubmitTransfer(
        address indexed owner,
        uint indexed index,
        address indexed to,
        uint value
    );

    modifier onlyOwner() {
        require(isOwner[msg.sender], "not owner");
        _;
    }

    modifier exists(uint _index) {
        require(_index < transactions.length, "does not exist");
        _;
    }

    modifier notExecuted(uint _index) {
        require(!transactions[_index].executed, "already executed");
        _;
    }

    modifier notConfirmed(uint _index) {
        require(!confirmed[_index][msg.sender], "already confirmed");
        _;
    }

    function toggleStaking() external onlyOwner {
        stakingPaused = !stakingPaused;
    }

    function _valid_token(address token, uint amount) internal returns (uint fold, uint usdc) {
        fold = token == FOLD ? amount : 0;
        usdc = token == USDC ? amount : 0;
        require(fold > 0 || usdc > 0 || token == WETH, "token type");
    }

    /**
     * @dev Update the weekly reward. Amount in WETH
     * @param _newReward New weekly reward.
     */
    function setWeeklyReward(uint _newReward) external onlyOwner {
        weeklyReward = _newReward;
        emit SetWeeklyReward(_newReward);
    }

    /**
     * @dev Update the minimum deposit. Amount in WETH
     * @param _minDeposit New minimum deposit.
     */
    function setMinDeposit(uint _minDeposit) external onlyOwner {
        minDeposit = _minDeposit;
        emit SetMinDeposit(_minDeposit);
    }

    /**
     * @dev Update the minimum lock duration for staked LP tokens.
     * @param _newMinDuration New minimum lock duration.(in weeks)
     */
    function setMinDuration(uint _newMinDuration) external onlyOwner {
        require(_newMinDuration % 1 weeks == 0 && minDuration / 1 weeks >= 1, 
         "Duration must be in units of weeks");
        minDuration = _newMinDuration;
        emit SetMinDuration(_newMinDuration);
    }

    /**
     * @dev Update the maximum liquidity the vault may hold (for the FOLD<>USDC pair).
     * The purpose is to increase the amount gradually, so as to not dilute the APY
     * unnecessarily much in beginning.
     * @param _newMaxTotalUSDC New max total.
     */
    function setMaxTotalUSDC(uint _newMaxTotalUSDC) external onlyOwner {
        maxTotalUSDC = _newMaxTotalUSDC;
        emit SetMaxTotalUSDC(_newMaxTotalUSDC);
    }

    /**
     * @dev Update the maximum liquidity the vault may hold (for the FOLD<>WETH pair).
     * The purpose is to increase the amount gradually, so as to not dilute the APY
     * unnecessarily much in beginning.
     * @param _newMaxTotalWETH New max total.
     */
    function setMaxTotalWETH(uint _newMaxTotalWETH) external onlyOwner {
        maxTotalWETH = _newMaxTotalWETH;
        emit SetMaxTotalWETH(_newMaxTotalWETH);
    }
    
    function submitTransfer(address _to, uint _value, 
        address _token) public onlyOwner {
        _valid_token(_token, _value);
        uint index = transactions.length;
        transactions.push(
            Transaction({to: _to,
                value: _value,
                token: _token,
                executed: false,
                confirm: 0
            })
        );  emit SubmitTransfer(msg.sender, index, 
                                _to, _value);
    }

    function confirmTransfer(uint _index) 
        public onlyOwner exists(_index)
        notExecuted(_index) notConfirmed(_index) {
        Transaction storage transfer = transactions[_index];
        transfer.confirm += 1;
        confirmed[_index][msg.sender] = true;
        emit ConfirmTransfer(msg.sender, _index);
    }

    function executeTransfer(uint _index)
        public onlyOwner exists(_index)
        notExecuted(_index) {
        Transaction storage transfer = transactions[_index];
        require(transfer.confirm >= 2, "cannot execute tx");
        require(IERC20(transfer.token).transfer(transfer.to, transfer.value), "transfer failed");
        transfer.executed = true; 
        emit ExecuteTransfer(msg.sender, _index);
    }
    

    constructor(address[] memory _owners, uint _numConfirmationsRequired) {
        deployed = block.timestamp;
        minDuration = 1 weeks;

        maxTotalWETH = type(uint).max;
        maxTotalUSDC = type(uint).max;

        weeklyReward = 0.000001 ether; // 0.000001 WETH

        nonfungiblePositionManager = INonfungiblePositionManager(NFPM); // UniV3
    }

    function _getPositionInfo(uint tokenId) internal view returns (address token0, address token1, uint128 liquidity) {
        (, , token0, token1, , , , liquidity, , , , ) = nonfungiblePositionManager.positions(tokenId);
    }

    // apply past weeks' totals to this week
    function _roll() internal returns (uint current_week) { // rollOver week
        current_week = (block.timestamp - deployed) / 1 weeks;
        // if the vault was emptied then we don't need to roll over past liquidity
        if (totalsETH[current_week] == 0 && liquidityETH > 0) {
            totalsETH[current_week] = liquidityETH;
        } // if the vault was emptied then we don't need to roll over past liquidity
        if (totalsUSDC[current_week] == 0 && liquidityUSDC > 0) {
            totalsUSDC[current_week] = liquidityUSDC;
        }
    }
    
    /**
     * @dev Unstake UniV3 LP deposit from vault (changing the owner back to original)
     */
    function withdrawToken(uint tokenId, uint percent) external {
        uint timestamp = depositTimestamps[msg.sender][tokenId]; // verify that a deposit exists
        // require(percent >= 1 && percent <= 100, "FOLDstaking::withdraw: bad percent of deposit");
        require(timestamp > 0, "FOLDstaking::withdraw: no owner exists for this tokenId");
        require( // how long this deposit has been in the vault
            (block.timestamp - timestamp) > minLockDuration,
            "FOLDstaking::withdraw: minimum duration for the deposit has not elapsed yet"
        );
        (address token0, , uint128 liquidity) = _getPositionInfo(tokenId);
        uint week_iterator = (timestamp - deployed) / 1 weeks;
        // liquidity *= percent / 100;

        // could've deposited right before the end of the week, so need a bit of granularity
        // otherwise an unfairly large portion of rewards may be obtained by staker
        uint so_far = (timestamp - deployed) / 1 hours;
        uint delta = so_far + (week_iterator * HOURS_PER_WEEK);
        uint reward = (delta * weeklyReward) / HOURS_PER_WEEK; 
        // the 1st reward may be a fraction of a whole week's worth
        
        uint totalReward = 0;
        if (token0 == WETH) {
            uint current_week = _roll();
            while (week_iterator < current_week) {
                uint totalThisWeek = totalsETH[week_iterator];
                if (totalThisWeek > 0) {
                    // need to check lest div by 0
                    // staker's share of rewards for given week
                    totalReward += (reward * liquidity) / totalThisWeek;
                }
                week_iterator += 1;
                reward = weeklyReward;
            }
            so_far = (block.timestamp - deployed) / 1 hours;
            delta = so_far - (current_week * HOURS_PER_WEEK);
            // the last reward will be a fraction of a whole week's worth
            reward = (delta * weeklyReward) / HOURS_PER_WEEK; // because we're in the middle of a current week
            totalReward += (reward * liquidity) / liquidityETH;
            liquidityETH -= liquidity;
        } else if (token0 == USDC) {
            uint current_week = _roll();
            while (week_iterator < current_week) {
                uint totalThisWeek = totalsUSDC[week_iterator];
                if (totalThisWeek > 0) {
                    // need to check lest div by 0
                    // staker's share of rewards for given week
                    totalReward += (reward * liquidity) / totalThisWeek;
                }
                week_iterator += 1;
                reward = weeklyReward;
            }
            so_far = (block.timestamp - deployed) / 1 hours;
            delta = so_far - (current_week * HOURS_PER_WEEK);
            // the last reward will be a fraction of a whole week's worth
            reward = (delta * weeklyReward) / HOURS_PER_WEEK; // because we're in the middle of a current week
            totalReward += (reward * liquidity) / liquidityUSDC;
            liquidityUSDC -= liquidity;
        }
        // if (percent == 100) {
            delete depositTimestamps[msg.sender][tokenId];    
        // }
        // else { // TODO unwrap NFT
        //   depositTimestamps[msg.sender][tokenId] = block.timestamp;
        // }
        IERC20(WETH).transfer(msg.sender, totalReward);
        // transfer ownership back to the original LP token owner
        nonfungiblePositionManager.transferFrom(address(this), msg.sender, tokenId);

        emit Withdrawal(tokenId, msg.sender, totalReward);
    }
    
    /*«-«-«-«-«-«-«-«-«-«-«-«-«-«-«-«-«-«-«-«-«-«-«-«-«-«-«-«-«-«-*/
    /*              THREE TYPES OF DEPOSIT FUNCTIONS              */
    /*-»-»-»-»-»-»-»-»-»-»-»-»-»-»-»-»-»-»-»-»-»-»-»-»-»-»-»-»-»-»*/    
    // 1. don't specify price ticks, medianiser applies them instead
    // 2. user already has an NFT (with ticks applied), just stake it
    // 3. user knows the ticks, but we create the NFT for them instead

    function deposit(address beneficiary, uint amount, address token) external payable {
        LP storage d = totals[beneficiary];
        uint weth;
        if (token == address(0)) {
            require(msg.value > 0, "must attach value");
            weth = msg.value;
        } else {
            (uint usdc, uint fold) = _valid_token(token, amount);
            IERC20(token).safeTransferFrom(msg.sender, address(this), amount);
            if (token == WETH) { 
                IWETH(WETH).withdraw(amount); 
                weth += amount;
            } else {
                d.usdc += usdc; d.fold += fold; // one of these will be 0
            }
            TransferHelper.safeApprove(token, address(nonfungiblePositionManager), amount);
        }
        
        // TODO use the price ticks from the medianizer to create NFT

        // TODO _addLiquidity
        
        TransferHelper.safeApprove(USDC, address(nonfungiblePositionManager), amount);
    }    

    /**
     * @dev This is one way of treating deposits.
     * Instead of deposit function implementation,
     * user might manually transfer their NFT
     * and this would trigger onERC721Received.
     * Stakers underwrite captive insurance for
     * the relay (against outages in mevAuction)
     */
    function depositNFT(uint tokenId) external {
        _depositNFT(tokenId, msg.sender);
        nonfungiblePositionManager.transferFrom(msg.sender, address(this), tokenId);
        emit DepositNFT(tokenId, msg.sender);
    }

    function _depositNFT(uint tokenId, address from) internal {
        (address token0, address token1, uint128 liquidity) = _getPositionInfo(tokenId);

        require(token1 == FOLD, "FOLDstaking::deposit: improper token id");
        // usually this means that the owner of the position already closed it
        require(liquidity > 0, "FOLDstaking::deposit: cannot deposit empty amount");

        if (token0 == WETH) {
            totalsETH[_roll()] += liquidity;
            liquidityETH += liquidity;
        } else if (token0 == USDC) {
            totalsUSDC[_roll()] += liquidity;
            liquidityUSDC += liquidity;
        } else {
            revert UnsupportedToken();
        }
        depositTimestamps[from][tokenId] = block.timestamp;
        // transfer ownership of LP share to this contract
        require(liquidityETH <= maxTotalWETH 
        && liquidityUSDC <= maxTotalUSDC, 
        "FOLDstaking::deposit: totalLiquidity exceed max");
    }


     /** Whenever an {IERC721} `tokenId` token is transferred to this contract:
     * @dev Safe transfer `tokenId` token from `from` to `address(this)`, 
     * checking that contract recipient prevent tokens from being forever locked.
     * - `tokenId` token must exist and be owned by `from`
     * - If the caller is not `from`, it must have been allowed 
     *   to move this token by either {approve} or {setApprovalForAll}.
     * - {onERC721Received} is called after a safeTransferFrom...
     * - It must return its Solidity selector to confirm the token transfer.
     *   If any other value is returned or the interface is not implemented
     *   by the recipient, the transfer will be reverted.
     */
    function onERC721Received(address, 
        address from, // previous owner's
        uint tokenId, bytes calldata data
    ) external override returns (bytes4) { 
        _depositNFT(tokenId, from);
        emit DepositNFT(tokenId, from);
        return this.onERC721Received.selector;
    }

   
}