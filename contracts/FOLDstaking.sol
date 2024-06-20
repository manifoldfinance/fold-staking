
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
    
    uint public minDeposit;
    
    
    uint public weeklyRewardUSDC;
    uint public weeklyRewardWETH;
    
    uint public immutable DEPLOYED; // timestamp when contract was DEPLOYED
    
    address[] public owners;
    mapping(address => bool) public isOwner;


    mapping(uint => uint) public totalsUSDC; // week # -> liquidity
    uint public liquidityUSDC; // in UniV3 liquidity units
    uint public maxTotalUSDC; // in the same units

    mapping(uint => uint) public totalsETH; // week # -> liquidity
    uint public liquidityWETH; // for the WETH<>FOLD pool
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


    mapping(address => mapping(uint => uint)) public depositTimestamps; // owner => NFTid => timestamp
    mapping(address => uint[]) public wethIDs; 
    mapping(address => uint[]) public usdcIDs; 
    
    // Depositors can have multiple positions, representing different price ranges (ticks)
    // if they never pick, there should be at least one depositId (for the full tick range)

    // ERC20 addresses (mainnet) of tokens
    address constant FOLD = 0xd084944d3c05CD115C09d072B9F44bA3E0E45921;
    address constant USDC = 0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48;
    address constant WETH = 0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2;
    
    // Pools addresses (mainnet) so we don't need to import IUniswapV3Factory
    address public FOLD_WETH = 0x5eCEf3b72Cb00DBD8396EBAEC66E0f87E9596e97;
    address public FOLD_USDC = 0xe081EEAB0AdDe30588bA8d5B3F6aE5284790F54A;

    // Uniswap's NonFungiblePositionManager (one for all new pools)
    address constant NFPM = 0xC36442b4a4522E871399CD717aBDD847Ab11FE88;

    uint constant public WAD = 1e18; 
    uint constant HOURS_PER_WEEK = 168;
    uint public minDuration;

    error UnsupportedToken();

    event NewMinDuration(uint duration);
    event NewMinDeposit(uint _minDeposit);

    event NewWeeklyRewardUSDC(uint reward);
    event NewWeeklyRewardWETH(uint reward);
    
    event NewMaxTotalUSDC(uint maxTotal);
    event NewMaxTotalWETH(uint maxTotal);

    event DepositNFT(uint tokenId, address owner);
    event Withdrawal(uint tokenId, address owner);
    
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

    // This is rarely (if ever) called, when (if) 
    // a new pool is created (with a new fee)... 
    function setPoolFee(uint24 fee, bool weth, 
    address poolAddress) external onlyOwner {
        if (weth) { FEE_WETH = fee;
            FOLD_WETH = poolAddress;
        } else { FEE_USDC = fee;
            FOLD_USDC = poolAddress;
        }
    }

    function _min(uint _a, uint _b) internal pure returns (uint) {
        return (_a < _b) ? _a : _b;
    }

    /**
     * @dev Update the weekly reward. Amount in USDC
     * @param _newReward New weekly reward.
     */
    function setWeeklyRewardUSDC(uint _newReward) external onlyOwner {
        weeklyRewardUSDC = _newReward;
        emit NewWeeklyRewardUSDC(_newReward);
    }

    /**
     * @dev Update the weekly reward. Amount in WETH
     * @param _newReward New weekly reward.
     */
    function setWeeklyRewardWETH(uint _newReward) external onlyOwner {
        weeklyRewardWETH = _newReward;
        emit NewWeeklyRewardWETH(_newReward);
    }

    /**
     * @dev Update the minimum deposit. Amount in WETH
     * @param _minDeposit New minimum deposit.
     */
    function setMinDepositWETH(uint _minDeposit) external onlyOwner {
        minDepositWETH = _minDeposit;
        emit NewMinDepositWETH(_minDeposit);
    }

    /**
     * @dev Update the minimum deposit. Amount in USDC
     * @param _minDeposit New minimum deposit.
     */
    function setMinDepositWETH(uint _minDeposit) external onlyOwner {
        minDepositUSDC = _minDeposit;
        emit NewMinDepositUSDC(_minDeposit);
    }

    /**
     * @dev Update the minimum lock duration for staked LP tokens.
     * @param _newDuration New minimum lock duration (in weeks)
     */
    function setMinDuration(uint _newDuration) external onlyOwner {
        require(_newDuration % 1 weeks == 0 && minDuration / 1 weeks >= 1, 
        "Duration must be in units of weeks");
        minDuration = _newDuration;
        emit NewMinDuration(_newDuration);
    }

    /**
     * @dev Update the maximum liquidity the vault may hold (for the FOLD<>USDC pair).
     * The purpose is to increase the amount gradually, so as to not dilute the APY
     * unnecessarily much in beginning.
     * @param _newMaxTotalUSDC New max total.
     */
    function setMaxTotalUSDC(uint _newMaxTotalUSDC) external onlyOwner {
        maxTotalUSDC = _newMaxTotalUSDC;
        emit NewMaxTotalUSDC(_newMaxTotalUSDC);
    }

    /**
     * @dev Update the maximum liquidity the vault may hold (for the FOLD<>WETH pair).
     * The purpose is to increase the amount gradually, so as to not dilute the APY
     * unnecessarily much in beginning.
     * @param _newMaxTotalWETH New max total.
     */
    function setMaxTotalWETH(uint _newMaxTotalWETH) external onlyOwner {
        maxTotalWETH = _newMaxTotalWETH;
        emit NewMaxTotalWETH(_newMaxTotalWETH);
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

    constructor(address[] memory _owners, 
    uint _numConfirmationsRequired) {
       
        FEE_WETH = 10000; FEE_USDC = 10000;
        DEPLOYED = block.timestamp;
        minDuration = 1 weeks;

        maxTotalWETH = type(uint).max;
        maxTotalUSDC = type(uint).max;

        weeklyRewardWETH = ; // 
        weeklyRewardUSDC = ; // 

        nonfungiblePositionManager = INonfungiblePositionManager(NFPM); // UniV3
    }

    // rollOver past weeks' snapshots of total liquidity to this week
    function _roll() internal returns (uint current_week) { 
        current_week = (block.timestamp - DEPLOYED) / 1 weeks;
        totalsETH[current_week] = liquidityWETH;
        totalsUSDC[current_week] = liquidityUSDC;
    }
    
    /**
     * @dev Unstake UniV3 LP deposit from vault (changing the owner back to original)
     */
    function withdrawToken(uint tokenId, bool burn) external {
        required(!PAUSED, "FOLDstaking: contract is paused");
        uint timestamp = depositTimestamps[msg.sender][tokenId]; 
        require(timestamp > 0, "FOLDstaking::withdraw: deposit doesn't exist");
        require( // how long this deposit has been in the vault
            (block.timestamp - timestamp) > minDuration,
            "FOLDstaking::withdraw: minimum duration for deposit has'nt elapsed"
        );
        (, , address token0, , , , , uint128 liquidity, , , , ) = nonfungiblePositionManager.positions(tokenId);
        address receiver = address(this);
        uint wethReward = _reward(timestamp, liquidity, token0);
        if (burn) { receiver = msg.sender;
            IERC20(WETH).transfer(msg.sender, wethReward); // TODO adapt based on token type
            // this makes the liquidity collectable in the next function call
            nonfungiblePositionManager.decreaseLiquidity(
                INonfungiblePositionManager.DecreaseLiquidityParams(tokenId, liquidity,
                                                                   0, 0, block.timestamp));
        } else {
            // transfer ownership back to the original LP token owner
            nonfungiblePositionManager.transferFrom(address(this), msg.sender, tokenId);
        }
        (uint rewardA, uint rewardB) = _collect(token0, tokenId, msg.sender);
        
        delete depositTimestamps[msg.sender][tokenId];
        
        liquidityUSDC -= liquidity; // TODO or WETH

        

        emit Withdrawal(tokenId, msg.sender);
    }

    // rewards will be re-deposited into their respective NFTs
    function compound(address beneficiary) external {
        uint[] memory weths = wethIDs[beneficiary];
        uint[] memory usdcs = usdcIDs[beneficiary];
        uint tokenId, reward0, reward1;
        for (uint i = 0; i < weths.length; i++) {
            tokenId = weths[i];
            (reward0, reward1) = _collect(WETH, tokenId, address(this));

        }
        for (uint i = 0; i < usdcs.length; i++) {
            tokenId = usdcs[i];
            (reward0, reward1) = _collect(USDC, tokenId, address(this));
        }

        
        uint wethReward = _reward(timestamp, liquidity, token0);
        IERC20(WETH).transfer(msg.sender, totalReward); // TODO increaseLiqudity
    }

    function _collect(address token0, uint tokenId, address receiver) returns (uint, uint) {
        (uint amount0, uint amount1) = nonfungiblePositionManager.collect(
            INonfungiblePositionManager.CollectParams(tokenId, 
            receiver, type(uint128).max, type(uint128).max)
        );  
        if (receiver == address(this)) {
            TransferHelper.safeApprove(IERC20(FOLD), NFPM, amount1);
            TransferHelper.safeApprove(IERC20(token0), NFPM, amount0);
            (amount0, amount1) = nonfungiblePositionManager.increaseLiquidity(
                INonfungiblePositionManager.IncreaseLiquidityParams(tokenId,
                                    amount0, amount1, 0, 0, block.timestamp));
        }
    }

    // timestamp (input) indicates when reward was last collected
    function _reward(uint timestamp, uint liquidity, address token0) 
        internal returns (uint totalReward) {

        // when had the NFT deposit been made
        // relative to the time when contract was deployed
        uint week_iterator = (timestamp - DEPLOYED) / 1 weeks;
    
        // could've deposited right before the end of the week, so need a bit of granularity
        // otherwise an unfairly large portion of rewards may be obtained by staker
        uint so_far = (timestamp - DEPLOYED) / 1 hours;
        uint delta = so_far + (week_iterator * HOURS_PER_WEEK);
        // the 1st reward may be a fraction of a whole week's worth
        
        uint reward, totalReward;
        uint current_week = _roll();
        if (token0 == WETH) {
            reward = (delta * weeklyRewardWETH) / HOURS_PER_WEEK; 

            while (week_iterator < current_week) {
                uint totalThisWeek = totalsETH[week_iterator];
                if (totalThisWeek > 0) {
                    // need to check lest div by 0
                    // staker's share of rewards for given week
                    totalReward += (reward * liquidity) / totalThisWeek;
                }
                week_iterator += 1;
                reward = weeklyRewardWETH;
            }
            so_far = (block.timestamp - DEPLOYED) / 1 hours;
            delta = so_far - (current_week * HOURS_PER_WEEK);
            
            // the last reward will be a fraction of a whole week's worth
            reward = (delta * weeklyReward) / HOURS_PER_WEEK; 
            // because we're in the middle of a current week
            
            totalReward += (reward * liquidity) / liquidityWETH;
        } else if (token0 == USDC) {
            reward = (delta * weeklyRewardUSDC) / HOURS_PER_WEEK; 
            while (week_iterator < current_week) {
                uint totalThisWeek = totalsUSDC[week_iterator];
                if (totalThisWeek > 0) {
                    // need to check lest div by 0
                    // staker's share of rewards for given week
                    totalReward += (reward * liquidity) / totalThisWeek;
                }
                week_iterator += 1;
                reward = weeklyRewardUSDC;
            }
            so_far = (block.timestamp - DEPLOYED) / 1 hours;
            delta = so_far - (current_week * HOURS_PER_WEEK);
            
            // the last reward will be a fraction of a whole week's worth
            reward = (delta * weeklyRewardUSDC) / HOURS_PER_WEEK; 
            // because we're in the middle of a current week

            totalReward += (reward * liquidity) / liquidityUSDC;
        }
        depositTimestamps[msg.sender][tokenId] = block.timestamp;
        // update when rewards were collected for this tokenId 
    }
    
    // provide a tokenId if beneficiary already has an NFT
    // otherwise, an NFT deposit will be created for the corresponding pool
    // targetting the full price range 
    // if FOLD is the passed in token, then the pool is WETH by default
    function deposit(address beneficiary, uint amount, 
    address token, uint tokenId) external payable {
        if (token == address(0)) {
            require(msg.value > 0, "must attach value");
            // check that beneficiary has at least one tokenId
            // if not create it, otherwise stake to min max  
        } 
        else {
            require(token == FOLD || token == WETH || token == USDC, 
                    "FOLDstaking::deposit: pass in a good token");
        }
        amount = _min(amount, IERC20(token).balanceOf(msg.sender));
        uint amount1ToMint = token == FOLD ? amount : 0;
        uint amount0ToMint = amount;
        if (amount1ToMint > 0) {
            token0 = WETH;
            amount0ToMint = 0;
        }
        
        if (msg.value > 0) { 
            IWETH(WETH).deposit{value: msg.value}();
            amount0ToMint += msg.value;
            require(amount0ToMint >= minDepositWETH, 
            "FOLDstaking::deposit: below minimum");
        }
        
        IERC20(token).safeTransferFrom(msg.sender, address(this), amount);
        TransferHelper.safeApprove(token, address(nonfungiblePositionManager), amount);
        
        if (tokenId!= 0) {

            require(depositTimestamps[beneficiary][tokenId] > 0,
                "FOLDstaking::deposit: tokenId doesn't exist");
            

            
        } else { // require that no tokenIds exist for depositor
            require(wethIDs[beneficiary].length == 0 
            && usdcIDs[beneficiary].length == 0, "FOLDstaking::deposit: no tokenIds");

            require(tokenIds.length == 0, "FOLDstaking::deposit: pass in a good tokenId");
            uint poolFee = token == USDC ? FEE_USDC : FEE_WETH;
            
            INonfungiblePositionManager(nonfungiblePositionManager).MintParams memory params =
            INonfungiblePositionManager.MintParams({
                token0: token, token1: FOLD,
                fee: poolFee,
                tickLower: TickMath.MIN_TICK,
                tickUpper: TickMath.MAX_TICK,
                amount0Desired: amount0ToMint,
                amount1Desired: amount1ToMint,
                amount0Min: 0, amount1Min: 0,
                recipient: address(this),
                deadline: block.timestamp
            });
            (tokenId, liquidity, amount0, amount1) = nonfungiblePositionManager.mint(params);
            depositTimestamps[beneficiary][tokenId] = block.timestamp;
        }
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
        address from, // previous owner
        uint tokenId, bytes calldata data
    ) external override returns (bytes4) { 
        _depositNFT(tokenId, from);
        emit DepositNFT(tokenId, from);
        return this.onERC721Received.selector;
    }

    function depositNFT(uint tokenId) external { // alternative version, using transferFrom
        _depositNFT(tokenId, msg.sender); // prep
        
        // transfer ownership of LP share to this contract
        nonfungiblePositionManager.transferFrom(msg.sender, address(this), tokenId);
    
        emit DepositNFT(tokenId, msg.sender);
    }

    function _depositNFT(uint tokenId, address from) internal {
        require(!PAUSED, "FOLDstaking: contract is paused");
        
        (, , address token0, address token1,
         , , , uint128 liquidity, , , , ) = nonfungiblePositionManager.positions(tokenId);
        require(token1 == FOLD, "FOLDstaking: improper token id");

        // usually this means that the owner of the position already closed it
        require(liquidity > 0, "FOLDstaking::deposit: cannot deposit empty amount");

        if (token0 == WETH) {
            wethIDs[from].push(tokenId);
            totalsETH[_roll()] += liquidity;
            liquidityWETH += liquidity;
        } else if (token0 == USDC) {
            usdcIDs[from].push(tokenId);
            totalsUSDC[_roll()] += liquidity;
            liquidityUSDC += liquidity;
        } else {
            revert UnsupportedToken();
        }
        depositTimestamps[from][tokenId] = block.timestamp;
     
        require(liquidityWETH <= maxTotalWETH 
        && liquidityUSDC <= maxTotalUSDC, 
        "FOLDstaking::deposit: totalLiquidity exceed max");
    }
   
}