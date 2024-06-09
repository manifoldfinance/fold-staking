
// SPDX-License-Identifier: MIT

pragma solidity =0.8.8;


import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC721/IERC721Receiver.sol";

/**
 * @title Captive Insurance
 * @dev Lock users' Uniswap LP NFTs or create an NFT for them 
 */

import "./Dependencies/TransferHelper.sol";
import "./Dependencies/INonfungiblePositionManager.sol";
import {TickMath} from "./Dependencies/LiquidityAmounts.sol";

interface IWETH is IERC20 {
    function deposit() external payable;
    function withdraw(uint256 amount) external;
}


// ERC20 represents the shareToken  
contract FOLDstaking is IERC721Receiver {

    /// @notice Inidicates if staking is paused.
    bool public PAUSED;

    // minimum duration of being in the vault before withdraw can be called (triggering reward payment)
    
    uint public minLockDuration;
    uint public minDeposit;
    uint public weeklyReward;
    uint public immutable DEPLOYED; // timestamp when contract was DEPLOYED
    
    address[] public owners;
    mapping(address => bool) public isOwner;
    
    mapping(uint => uint) public totalsUSDC; // week # -> liquidity
    uint public liquidityUSDC; // in UniV3 liquidity units
    uint public maxTotalUSDC; // in the same units

    mapping(uint => uint) public totalsETH; // week # -> liquidity
    uint public liquidityETH; // for the WETH<>FOLD pool
    uint public maxTotalWETH;

    INonfungiblePositionManager public immutable nonfungiblePositionManager;

    uint public FEE_WETH = 0;
    uint public FEE_USDC = 0; 

    // MAKE IT A MAP
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
        PAUSED = !PAUSED;
    }

    function setPoolFee(uint24 fee, bool weth) external onlyOwner {
        if (weth) {
            FEE_WETH = fee;
        } else {
            FEE_USDC = fee;
        }

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
        require(_newMinDuration % 1 weeks == 0 
        && minDuration / 1 weeks >= 1, 
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
       
        FEE_WETH = 10000; FEE_USDC = 10000;
        DEPLOYED = block.timestamp;
        minDuration = 1 weeks;

        maxTotalWETH = type(uint).max;
        maxTotalUSDC = type(uint).max;

        weeklyReward = 0.000001 ether; // 0.000001 WETH

        nonfungiblePositionManager = INonfungiblePositionManager(NFPM); // UniV3
    }

    function _getPositionInfo(uint tokenId) internal view returns (address token0, uint128 liquidity) {
        (, , token0, token1, , , , liquidity, , , , ) = nonfungiblePositionManager.positions(tokenId);
        require(token1 == FOLD, "FOLDstaking: improper token id");
    }

    // apply past weeks' totals to this week
    function _roll() internal returns (uint current_week) { // rollOver week
        current_week = (block.timestamp - DEPLOYED) / 1 weeks;
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
    function withdrawToken(uint tokenId, bool burn) external {
        required(!PAUSED, "FOLDstaking: contract is paused");
        uint timestamp = depositTimestamps[msg.sender][tokenId]; // verify that a deposit exists
        // require(percent >= 1 && percent <= 100, "FOLDstaking::withdraw: bad percent of deposit");
        require(timestamp > 0, "FOLDstaking::withdraw: no owner exists for this tokenId");
        require( // how long this deposit has been in the vault
            (block.timestamp - timestamp) > minLockDuration,
            "FOLDstaking::withdraw: minimum duration for the deposit has not elapsed yet"
        );
        (address token0, uint128 liquidity) = _getPositionInfo(tokenId);
        
        
        if (burn) {
             nonfungiblePositionManager.decreaseLiquidity(
                INonfungiblePositionManager.DecreaseLiquidityParams(tokenId,
                                    liquidity, 0, 0, block.timestamp));

        }
        (uint rewardA, uint rewardB) = _collect(token0, tokenId);
        uint wethReward = _reward(timestamp, liquidity, token0);


        emit Withdrawal(tokenId, msg.sender, wethReward, rewardA, rewardB);
    }

    function _collect(address token0, uint tokenId, address receiver, bool reDeposit) returns (uint, uint) {
        
        (uint amount0, uint amount1) = nonfungiblePositionManager.collect(
            INonfungiblePositionManager.CollectParams(tokenId, 
            receiver, type(uint128).max, type(uint128).max)
        );  
        if (reDeposit) {
            TransferHelper.safeApprove(IERC20(FOLD), NFPM, amount1);
            TransferHelper.safeApprove(IERC20(token0), NFPM, amount0);
            (amount0, amount1) = nonfungiblePositionManager.increaseLiquidity(
                INonfungiblePositionManager.IncreaseLiquidityParams(tokenId,
                                    amount0, amount1, 0, 0, block.timestamp));
        }
    }

    function _reward(uint timestamp, uint liquidity, address token0) 
        internal returns (uint totalReward) {

        uint week_iterator = (timestamp - DEPLOYED) / 1 weeks;
    
        // could've deposited right before the end of the week, so need a bit of granularity
        // otherwise an unfairly large portion of rewards may be obtained by staker
        uint so_far = (timestamp - DEPLOYED) / 1 hours;
        uint delta = so_far + (week_iterator * HOURS_PER_WEEK);
        uint reward = (delta * weeklyReward) / HOURS_PER_WEEK; 
        // the 1st reward may be a fraction of a whole week's worth
        
        uint totalReward = 0;
        uint current_week = _roll();
        if (token0 == WETH) {
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
            so_far = (block.timestamp - DEPLOYED) / 1 hours;
            delta = so_far - (current_week * HOURS_PER_WEEK);
            // the last reward will be a fraction of a whole week's worth
            reward = (delta * weeklyReward) / HOURS_PER_WEEK; 
            // because we're in the middle of a current week

            totalReward += (reward * liquidity) / liquidityETH;
            liquidityETH -= liquidity;
        } else if (token0 == USDC) {
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
            so_far = (block.timestamp - DEPLOYED) / 1 hours;
            delta = so_far - (current_week * HOURS_PER_WEEK);
            // the last reward will be a fraction of a whole week's worth
            reward = (delta * weeklyReward) / HOURS_PER_WEEK; 
            // because we're in the middle of a current week

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

        
    }
    
    /*«-«-«-«-«-«-«-«-«-«-«-«-«-«-«-«-«-«-«-«-«-«-«-«-«-«-«-«-«-«-*/
    /*              THREE TYPES OF DEPOSIT FUNCTIONS              */
    /*-»-»-»-»-»-»-»-»-»-»-»-»-»-»-»-»-»-»-»-»-»-»-»-»-»-»-»-»-»-»*/    
    // 1. don't specify price ticks, min tick and max tick by default
    // 2. user already has an NFT (with ticks, etc), just stake to it

    function deposit(address beneficiary, uint amount, 
    address token, uint tokenId) external payable {
        LP storage d = totals[beneficiary]; uint weth;
        if (token == address(0)) {
            require(msg.value > 0, "must attach value");
            weth = msg.value;

            // check that beneficiary has at least one tokenId
            // if not create it, otherwise stake to min max  
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
        TransferHelper.safeApprove(USDC, address(nonfungiblePositionManager), amount);

        if (tokenId != 0) {
            
        }
    }    

    function packNFT(address token, uint amount, uint _tickUpper, uint _tickLower) external {
        // TODO use the price ticks from the medianizer to create NFT
        
        _valid_token(token, amount);
        if (_tickLower > 0) {
            require(_tickLower >= TickMath.MIN_TICK &&
            _tickUpper <= TickMath.MAX_TICK, "bad ticks");
        } else {
            _tickLower = TickMath.MIN_TICK;
            _tickUpper = TickMath.MAX_TICK;
        }
        uint poolFee = token == USDC ? FEE_USDC : FEE_WETH;

        INonfungiblePositionManager(nonfungiblePositionManager).MintParams memory params =
            INonfungiblePositionManager.MintParams({
                token0: token, token1: FOLD,
                fee: poolFee,
                tickLower: _tickLower,
                tickUpper: _tickUpper,
                amount0Desired: amount0ToMint,
                amount1Desired: amount1ToMint,
                amount0Min: 0,
                amount1Min: 0,
                recipient: address(this),
                deadline: block.timestamp
            });

     

        (tokenId, liquidity, amount0, amount1) = nonfungiblePositionManager.mint(params);

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
        required(!PAUSED, "FOLDstaking: contract is paused");
        (address token0, uint128 liquidity) = _getPositionInfo(tokenId);

        
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