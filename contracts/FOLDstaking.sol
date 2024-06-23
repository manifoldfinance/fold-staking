
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

interface IWETH is IERC20 {
    function deposit() external payable;
    function withdraw(uint256 amount) external;
}

contract FOLDstaking is IERC721Receiver {
    uint public minLiquidity; // in uniswap units
    uint public minDuration; // in seconds
    // minimum duration of NFT being staked
    // before rewards are obtainable
    event NewMinLiquidity(uint liquidity);
    event NewMinDuration(uint duration);
    uint internal constant HOURS_PER_WEEK = 168;
    int24 internal constant MIN_TICK = -887272;
    int24 internal constant MAX_TICK = 887272;

    uint public immutable DEPLOYED; // timestamp of deployment
    bool public PAUSED; // if staking is paused actions are frozen
    error UnsupportedToken();
    // ERC20 addresses (mainnet) of tokens
    address constant FOLD = 0xd084944d3c05CD115C09d072B9F44bA3E0E45921;
    address constant USDC = 0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48;
    address constant WETH = 0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2;
    
    // Pools addresses (mainnet), may be updated by MSIG owners
    address public FOLD_WETH = 0x5eCEf3b72Cb00DBD8396EBAEC66E0f87E9596e97;
    address public FOLD_USDC = 0xe081EEAB0AdDe30588bA8d5B3F6aE5284790F54A;
    // Uniswap's NonFungiblePositionManager (one for all new pools)
    address constant NFPM = 0xC36442b4a4522E871399CD717aBDD847Ab11FE88;

    event DepositNFT(uint tokenId, address owner);
    event Withdrawal(uint tokenId, address owner);
    // withdrawal may either burn the NFT and release funds to the owner
    // or keeps the funds inside the NFT and transfer it back to the owner
    mapping(address => mapping(uint => uint)) public depositTimestamps; // owner => NFTid => timestamp
    // Depositors can have multiple positions, representing different price ranges (ticks)
    // if they never pick, there should be at least one depositId (for the full tick range)
    struct NFT {
        bool burned;
        uint id;
    }

    mapping(address => NFT[]) public usdcIDs; 
    mapping(uint => uint) public totalsUSDC; // week # -> snapshot of liquidity
    uint public weeklyRewardUSDC; // in units of USDC
    uint public liquidityUSDC; // total for all LP deposits
    uint public maxTotalUSDC; // in UniV3 liquidity units
    uint24 public FEE_USDC = 0; 

    event NewWeeklyRewardUSDC(uint reward);
    event NewMaxTotalUSDC(uint total);
    
    mapping(address => NFT[]) public wethIDs; 
    mapping(uint => uint) public totalsWETH; // week # -> snapshot of liquidity
    uint public weeklyRewardWETH;
    uint public liquidityWETH; // for the WETH<>FOLD pool
    uint public maxTotalWETH;
    uint24 public FEE_WETH = 0; // the pool fee
    
    event NewWeeklyRewardWETH(uint reward);
    event NewMaxTotalWETH(uint total);

    // MSIG 
    mapping(address => bool) public isOwner;
    struct Transfer {
        address to;
        uint value;
        address token;
        bool executed;
        uint confirm;
    }   Transfer[] public transfers;
    mapping(uint => mapping(address => bool)) public confirmed;
    
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
        require(_index < transfers.length, "does not exist");
        _;
    }

    modifier notExecuted(uint _index) {
        require(!transfers[_index].executed, "already executed");
        _;
    }

    modifier notConfirmed(uint _index) {
        require(!confirmed[_index][msg.sender], "already confirmed");
        _;
    }

    function _min(uint _a, uint _b) internal pure returns (uint) {
        return (_a < _b) ? _a : _b;
    }

    function toggleStaking() external onlyOwner {
        PAUSED = !PAUSED;
    }

    // This is rarely (if ever) called, when (if) 
    // a new pool is created (with a new fee)... 
    function setPool(uint24 fee, bool weth, 
    address poolAddress) external onlyOwner {
        if (weth) { FEE_WETH = fee;
            FOLD_WETH = poolAddress;
        } else { FEE_USDC = fee;
            FOLD_USDC = poolAddress;
        }
    }

    function setMinLiquidity(uint128 _minLiquidity) external onlyOwner {
        minLiquidity = _minLiquidity;
        emit NewMinLiquidity(_minLiquidity);
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
     * @dev Update the weekly reward. Amount in USDC
     * @param _newReward New weekly reward.
     */
    function setWeeklyRewardUSDC(uint _newReward) external onlyOwner {
        weeklyRewardUSDC = _newReward;
        emit NewWeeklyRewardUSDC(_newReward);
    }

    /**
     * @dev Update the maximum liquidity the vault may hold (for the FOLD<>USDC pair).
     * The purpose is to increase the amount gradually, so as to not dilute the APY
     * unnecessarily much in beginning.
     * @param _newMaxTotal New max total.
     */
    function setMaxTotalUSDC(uint128 _newMaxTotal) external onlyOwner {
        maxTotalUSDC = _newMaxTotal;
        emit NewMaxTotalUSDC(_newMaxTotal);
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
     * @dev Update the maximum liquidity the vault may hold (for the FOLD<>WETH pair).
     * The purpose is to increase the amount gradually, so as to not dilute the APY
     * unnecessarily much in beginning.
     * @param _newMaxTotal New max total.
     */
    function setMaxTotalWETH(uint _newMaxTotal) external onlyOwner {
        maxTotalWETH = _newMaxTotal;
        emit NewMaxTotalWETH(_newMaxTotal);
    }
    
    function submitTransfer(address _to, uint _value, 
        address _token) public onlyOwner {
        uint index = transfers.length;
        transfers.push(
            Transfer({to: _to,
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
        Transfer storage transfer = transfers[_index];
        transfer.confirm += 1;
        confirmed[_index][msg.sender] = true;
        emit ConfirmTransfer(msg.sender, _index);
    }

    function executeTransfer(uint _index)
        public onlyOwner exists(_index)
        notExecuted(_index) {
        Transfer storage transfer = transfers[_index];
        require(transfer.confirm >= 3, "cannot execute tx");
        TransferHelper.safeTransfer(transfer.token, 
            transfer.to, transfer.value);  
            transfer.executed = true; 
        emit ExecuteTransfer(msg.sender, _index);
    }

    constructor(address[] memory _owners) {
        for (uint i = 0; i < _owners.length; i++) {
            address owner = _owners[i];
            require(owner != address(0), "invalid owner");
            require(!isOwner[owner], "owner not unique");
            isOwner[owner] = true;
        }   
        FEE_WETH = 10000; FEE_USDC = 10000;
        DEPLOYED = block.timestamp;
        minDuration = 1 weeks;
        minLiquidity = 0;

        maxTotalUSDC = type(uint).max;
        maxTotalWETH = type(uint).max;

        weeklyRewardUSDC = 100000; // 10 cents per unit of liquidity staked
        weeklyRewardWETH = 10000000000; // 0.00001 ETH or roughly 4 cents
    }

    // rollOver past weeks' snapshots of total liquidity to this week
    function _roll() internal returns (uint current_week) { 
        current_week = (block.timestamp - DEPLOYED) / 1 weeks;
        totalsWETH[current_week] = liquidityWETH; 
        totalsUSDC[current_week] = liquidityUSDC;
    }
    
    /**
     * @dev Unstake UniV3 LP deposit from vault (changing the owner back to original)
     */
    function withdrawToken(uint tokenId, bool burn) external {
        require(!PAUSED, "FOLDstaking: contract paused");
        uint timestamp = depositTimestamps[msg.sender][tokenId]; 
        require(timestamp > 0, "FOLDstaking::withdraw: no deposit");
        require( // how long this deposit has been in the vault
            (block.timestamp - timestamp) > minDuration,
            "FOLDstaking::withdraw: not yet"
        );
        (,, address token0,,,,, uint128 liquidity,,,,) = INonfungiblePositionManager(NFPM).positions(tokenId);
        uint current_week = _roll(); NFT memory nft;
        uint reward = _reward(timestamp, liquidity, 
                              token0, current_week);
        if (burn) {
            TransferHelper.safeTransfer(token0, msg.sender, reward);
            // this makes all of the liquidity collectable in the next function call
            INonfungiblePositionManager(NFPM).decreaseLiquidity(
                INonfungiblePositionManager.DecreaseLiquidityParams(tokenId, liquidity,
                                                                    0, 0, block.timestamp));
            _collect(token0, tokenId, msg.sender, 0, 0);
            INonfungiblePositionManager(NFPM).burn(tokenId);
        } 
        else {
            // increase liquidity of the NFT using collected fees and the reward
            _collect(token0, tokenId, address(this), reward, 0); 
            // transfer ownership back to the original LP token owner
            INonfungiblePositionManager(NFPM).transferFrom(address(this), msg.sender, tokenId);
        }
        if (token0 == WETH) {
            liquidityWETH -= liquidity;
            for (uint i = 0; i < wethIDs[msg.sender].length; i++) {
                nft = wethIDs[msg.sender][i];
                if (nft.id == tokenId) {
                    wethIDs[msg.sender][i].burned = true;
                }
            }
        } else {
            liquidityUSDC -= liquidity;
            for (uint i = 0; i < usdcIDs[msg.sender].length; i++) {
                nft = usdcIDs[msg.sender][i];
                if (nft.id == tokenId) {
                    usdcIDs[msg.sender][i].burned = true;
                }
            }
        }
        delete depositTimestamps[msg.sender][tokenId];
        emit Withdrawal(tokenId, msg.sender);
    }

    // depositors must call this individually at their leisure
    // rewards will be re-deposited into their respective NFTs
    function compound(address beneficiary) external {
        require(!PAUSED, "FOLDstaking: contract paused");
        uint i = 0; uint amount; uint timestamp; 
        uint tokenId; NFT memory nft; 
        uint current_week = _roll();
        for (i = 0; i < wethIDs[beneficiary].length; i++) {
            nft = wethIDs[beneficiary][i];
            if (nft.burned) {
                continue;
            }
            tokenId = nft.id;
            (,,,,,,,uint128 liquidity,,,,) = INonfungiblePositionManager(NFPM).positions(tokenId);
            timestamp = depositTimestamps[msg.sender][tokenId]; 
            // amount to draw from address(this) and deposit into NFT position
            amount = _reward(timestamp, liquidity, WETH, current_week);
            depositTimestamps[msg.sender][tokenId] = block.timestamp;
            
            liquidityWETH -= liquidity;
            liquidityWETH += _collect(WETH, tokenId, 
                            address(this), amount, 0);  // reward + collected fees from uniswap
        }
        for (i = 0; i < usdcIDs[beneficiary].length; i++) {
            nft = usdcIDs[beneficiary][i];
            if (nft.burned) {
                continue;
            }
            tokenId = nft.id;
            (,,,,,,,uint128 liquidity,,,,) = INonfungiblePositionManager(NFPM).positions(tokenId);
            timestamp = depositTimestamps[msg.sender][tokenId]; 
            // amount to draw from address(this) and deposit into NFT position
            amount = _reward(timestamp, liquidity, USDC, current_week);
            depositTimestamps[msg.sender][tokenId] = block.timestamp; 
           
            liquidityUSDC -= liquidity;
            liquidityUSDC += _collect(USDC, tokenId, 
                            address(this), amount, 0); // reward + collected fees from uniswap
        }
    }

    function _collect(address token0, uint tokenId, 
        address receiver, uint amountA, uint amountB) 
        internal returns (uint128 liquidity) {
        (uint amount0, uint amount1) = INonfungiblePositionManager(NFPM).collect(
            INonfungiblePositionManager.CollectParams(tokenId, 
                receiver, type(uint128).max, type(uint128).max)
        );
        if (receiver == address(this)) { // not a withdrawal
            amount0 += amountA; amount1 += amountB;
            if (amount1 > 0) {
                TransferHelper.safeApprove(FOLD, NFPM, amount1);
            }
            if (amount0 > 0) {
                TransferHelper.safeApprove(token0, NFPM, amount0);
            }
            (liquidity,,) = INonfungiblePositionManager(NFPM).increaseLiquidity(
                INonfungiblePositionManager.IncreaseLiquidityParams(tokenId,
                                    amount0, amount1, 0, 0, block.timestamp));
        }
    }

    // timestamp (input variable) indicates when reward was last collected
    function _reward(uint timestamp, uint liquidity, 
        address token0, uint current_week) 
        internal returns (uint totalReward) {

        // when had the NFT deposit been made
        // relative to the time when contract was deployed
        uint week_iterator = (timestamp - DEPLOYED) / 1 weeks;
    
        // could've deposited right before the end of the week, so need a bit of granularity
        // otherwise an unfairly large portion of rewards may be obtained by staker
        uint so_far = (timestamp - DEPLOYED) / 1 hours;
        uint delta = so_far + (week_iterator * HOURS_PER_WEEK);
        // the 1st reward may be a fraction of a whole week's worth
        
        uint reward;
        if (token0 == WETH) {
            reward = (delta * weeklyRewardWETH) / HOURS_PER_WEEK; 

            while (week_iterator < current_week) {
                uint totalThisWeek = totalsWETH[week_iterator];
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
            reward = (delta * weeklyRewardWETH) / HOURS_PER_WEEK; 
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
        // update when rewards were collected for this tokenId 
    }
    
    // provide a tokenId if beneficiary already has an NFT
    // otherwise, an NFT deposit will be created for the corresponding pool
    // targetting the full price range 
    // if no tokenId is provided AND
    // FOLD is also the passed in token, then the pool is WETH by default
    // it's possible to pass in msg.value to provide both tokens to the pool
    // so the only way to create an NFT for the FOLD<>USDC pool is to first 
    // provide USDC, get the tokenId from the created NFT,
    // and then call deposit again with FOLD and pass in the tokenId 
    function deposit(address beneficiary, uint amount, 
    address token, uint tokenId) external payable {
        require(!PAUSED, "FOLDstaking: contract paused");
        amount = _min(amount, IERC20(token).balanceOf(msg.sender));
        uint amount1;
        uint amount0;
        uint24 poolFee;
        if (token == FOLD) { 
            TransferHelper.safeTransferFrom(token, msg.sender, address(this), amount);
            TransferHelper.safeApprove(token, NFPM, amount);
            amount1 = amount;
            poolFee = FEE_WETH; // only used if no tokenId passed in
        } else {
            amount0 = amount;
            if (token == USDC) {
                poolFee = FEE_USDC;
            } else if (token == WETH) {
                poolFee = FEE_WETH;
            } else {
                revert UnsupportedToken();
            }
            TransferHelper.safeTransferFrom(token, msg.sender, address(this), amount);
            TransferHelper.safeApprove(token, NFPM, amount);
        }
        if (msg.value > 0) { require(token != USDC, "FOLDstaking::deposit: bad combo");
            IWETH(WETH).deposit{value: msg.value}(); // WETH balance available to address(this)
            amount0 += msg.value; 
            uint allowance = IERC20(WETH).allowance(address(this), NFPM);
            TransferHelper.safeApprove(WETH, NFPM, allowance + msg.value);
        }
        if (tokenId != 0) {
            uint timestamp = depositTimestamps[beneficiary][tokenId];
            require(timestamp > 0, "FOLDstaking::deposit: tokenId doesn't exist");
            (,, address token0,,
             ,,, uint128 liquidity,,,,) = INonfungiblePositionManager(NFPM).positions(tokenId);
            uint current_week = _roll();
            uint reward = _reward(timestamp, liquidity, 
                                  token0, current_week);
            if (token0 == WETH) {
                liquidityWETH -= liquidity;
            } else {
                liquidityUSDC -= liquidity;
            }
            liquidity = _collect(token0, tokenId, address(this), 
                                 amount0 + reward, amount1);
            if (token0 == WETH) {
                liquidityWETH += liquidity;
            } else {
                liquidityUSDC += liquidity;
            }
            depositTimestamps[msg.sender][tokenId] = block.timestamp;
        } else {
            if (token == FOLD) token = WETH;
            INonfungiblePositionManager.MintParams memory params =
            INonfungiblePositionManager.MintParams({
                token0: token, token1: FOLD,
                fee: poolFee,
                tickLower: MIN_TICK,
                tickUpper: MAX_TICK,
                amount0Desired: amount0,
                amount1Desired: amount1,
                amount0Min: 0, amount1Min: 0,
                recipient: address(this),
                deadline: block.timestamp
            });
            (uint tokenID, uint128 liquidity,,) = INonfungiblePositionManager(NFPM).mint(params);
            depositTimestamps[beneficiary][tokenID] = block.timestamp;
            NFT memory nft; nft.id = tokenID; 
            if (token == WETH) {
                wethIDs[beneficiary].push(nft);
                liquidityWETH += liquidity;
            } else {
                usdcIDs[beneficiary].push(nft);
                liquidityUSDC += liquidity;
            }
            require(liquidity >= minLiquidity, "FOLDstaking::deposit: minLiquidity");
        }
        require(liquidityWETH <= maxTotalWETH &&
                liquidityUSDC <= maxTotalUSDC, 
                "FOLDstaking::deposit: exceed max");
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
        require(!PAUSED, "FOLDstaking: contract paused");
        _depositNFT(tokenId, from);
        emit DepositNFT(tokenId, from);
        return this.onERC721Received.selector;
    }

    function depositNFT(uint tokenId) external { // alternative version, using transferFrom
        _depositNFT(tokenId, msg.sender); // prep work
        
        // transfer ownership of LP share to this contract
        INonfungiblePositionManager(NFPM).transferFrom(msg.sender, address(this), tokenId);
    
        emit DepositNFT(tokenId, msg.sender);
    }

    function _depositNFT(uint tokenId, address from) internal {
        (,, address token0, address token1,
         ,,, uint128 liquidity,,,,) = INonfungiblePositionManager(NFPM).positions(tokenId);
        require(token1 == FOLD, "FOLDstaking: improper token id");

        // usually this means that the owner of the position already closed it
        require(liquidity > 0, "FOLDstaking::deposit: cannot deposit empty amount");
        NFT memory nft;
        nft.id = tokenId;
        nft.burned = false;
        if (token0 == WETH) { 
            require(wethIDs[from].length < 22, 
                "FOLDstaking::deposit: exceeding max");
            
            wethIDs[from].push(nft);
            totalsWETH[_roll()] += liquidity;
            
            liquidityWETH += liquidity;
            require(liquidityWETH <= maxTotalWETH,
                "FOLDstaking::deposit: exceeding max liquidity");
        } 
        else if (token0 == USDC) {
            require(usdcIDs[from].length < 22, 
                "FOLDstaking::deposit: exceeding max");
            
            usdcIDs[from].push(nft);
            totalsUSDC[_roll()] += liquidity;
            
            liquidityUSDC += liquidity;
            require(liquidityUSDC <= maxTotalUSDC, 
                "FOLDstaking::deposit: exceeding max liquidity");
        } else {
            revert UnsupportedToken();
        }
        depositTimestamps[from][tokenId] = block.timestamp;
    }
}
