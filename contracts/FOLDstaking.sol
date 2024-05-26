
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
import {IUniswapV3Pool} from "./Dependencies/IUniswapV3Pool.sol";
import {TickMath, LiquidityAmounts} from "./Dependencies/LiquidityAmounts.sol";

interface IWETH is IERC20 {
    function deposit() external payable;
    function withdraw(uint256 amount) external;
}

interface INonfungiblePositionManager is IERC721 { // reward QD<>USDT or QD<>WETH liquidity deposits
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
interface IUniswapV3MintCallback {
    /// @notice Called to `msg.sender` after minting liquidity to a position from IUniswapV3Pool#mint.
    /// @dev In the implementation you must pay the pool tokens owed for the minted liquidity.
    /// The caller of this method must be checked to be a UniswapV3Pool deployed by the canonical UniswapV3Factory.
    /// @param amount0Owed The amount of token0 due to the pool for the minted liquidity
    /// @param amount1Owed The amount of token1 due to the pool for the minted liquidity
    /// @param data Any data passed through by the caller via the IUniswapV3PoolActions#mint call
    function uniswapV3MintCallback(
        uint256 amount0Owed,
        uint256 amount1Owed,
        bytes calldata data
    ) external;
}

// ERC20 represents the shareToken  
contract FOLDstaking is ERC20, IUniswapV3MintCallback, IERC721Receiver {
    
    using SafeTransferLib for IERC20;
    using SafeTransferLib for IWETH;

    // If you withdraw we clawback a percentage 

    // Initiate Withdraw (getting out your payout)
    // …period of wait…
    // exit (remove fold)

    // Fold tokens being staked into contract
    // Value of fold in the vault 
    // is being used as a backstop for liabili

    // Do a claim against vault
    // Payout to the vault 
    // A way to limit the amount of deposits
    // Emergency shutdown

    // Query the apr paid…
    // How much vault provides
    // based on price of fold

    //  function harvest(uint256 pid, address to) external;
    // function withdrawAndHarvest(uint256 pid, uint256 amount, address to) external;


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
    uint public totalLiquidityUSDC; // in UniV3 liquidity units
    uint public maxTotalUSDC; // in the same units

    mapping(uint => uint) public totalsWETH; // week # -> liquidity
    uint public totalLiquidityWETH; // for the WETH<>FOLD pool
    uint public maxTotalWETH;

    INonfungiblePositionManager public immutable nonfungiblePositionManager;

    /// @param pool The Uniswap V3 pool
    /// @param tickLower The lower tick of the UniV3 LP position
    /// @param tickUpper The upper tick of the UniV3 LP position
    struct Key { // 
        IUniswapV3Pool pool; // the WETH pool or the USDC pool 
        int24 tickLower;
        int24 tickUpper;
    }

    /// @param token0 The token0 of the Uniswap pool
    /// @param token1 The token1 of the Uniswap pool
    /// @param fee The fee tier of the Uniswap pool
    /// @param payer The address to pay for the required tokens
    struct MintCallbackData {
        address token0;
        address token1;
        uint24 fee;
        address payer;
    }
    /// @param pool either FOLD_USDC or FOLD_WETH
    /// @param recipient The recipient of the liquidity position
    /// @param payer The address that will pay the tokens
    /// @param amount0Desired The token0 amount to use
    /// @param amount1Desired The token1 amount to use
    /// @param amount0Min The minimum token0 amount to use
    /// @param amount1Min The minimum token1 amount to use
    struct AddLiquidityParams {
        address pool;
        address recipient;
        address payer;
        uint256 amount0Desired;
        uint256 amount1Desired;
        uint256 amount0Min;
        uint256 amount1Min;
    }

    /// @param key The Bunni position's key
    /// @param recipient The user if not withdrawing ETH, address(0) if withdrawing ETH
    /// @param shares The amount of ERC20 tokens (this) to burn,
    /// @param amount0Min The minimum amount of token0 that should be accounted for the burned liquidity,
    /// @param amount1Min The minimum amount of token1 that should be accounted for the burned liquidity,
    /// @param deadline The time by which the transaction must be included to effect the change
    struct WithdrawParams {
        BunniKey key;
        address recipient;
        uint256 shares;
        uint256 amount0Min;
        uint256 amount1Min;
        uint256 deadline;
    }

    struct Transaction {
        address to;
        uint value;
        address token;
        bool executed;
        uint confirm;
    }   Transaction[] public transactions;
    mapping(uint => mapping(address => bool)) public confirmed;

    // You can have multiple positions per address (representing different ranges).

    
    mapping(address => mapping(address => uint)) totals; // depositor => token => balance
    mapping(address => Deposit) deposits;
    mapping(address => Key[]) keys;
    mapping(address => Deposit) totals;

    mapping(address => mapping(uint => uint)) public depositTimestamps; // for liquidity providers

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

    
    /// @notice Emitted when fees are compounded back into liquidity
    /// @param sender The msg.sender address
    /// @param bunniKeyHash The hash of the Bunni position's key
    /// @param liquidity The amount by which liquidity was increased
    /// @param amount0 The amount of token0 added to the liquidity position
    /// @param amount1 The amount of token1 added to the liquidity position
    event Compound(
        address indexed sender,
        bytes32 indexed bunniKeyHash,
        uint128 liquidity,
        uint256 amount0,
        uint256 amount1
    );
    
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

    function _valid_token(address token, uint amount) internal returns (uint fold, usdc) {
        fold = token == FOLD ? amount : 0;
        usdc = token == USDC ? amount : 0;
        require(fold > 0 || usdc > 0 || token == WETH, "token type");
    }
    
    function uniswapV3MintCallback(
        uint256 amount0Owed,
        uint256 amount1Owed,
        bytes calldata data
    ) external override {
        require(msg.sender == FOLD_WETH || msg.sender == FOLD_USDC, "");

        MintCallbackData memory decodedData = abi.decode(
            data, (MintCallbackData)
        );
        if (amount0Owed > 0)
            pay(decodedData.token0, decodedData.payer, msg.sender, amount0Owed);
        if (amount1Owed > 0)
            pay(decodedData.token1, decodedData.payer, msg.sender, amount1Owed);
    }


    /// @param token The token to pay
    /// @param payer The entity that must pay
    /// @param recipient The entity that will receive payment
    /// @param value The amount to pay
    function pay(
        address token,
        address payer,
        address recipient,
        uint256 value
    ) internal {
        if (payer == address(this)) {
            // pay with tokens already in the contract (for the exact input multihop case)
            IERC20(token).safeTransfer(recipient, value);
        } else {
            // pull payment
            IERC20(token).safeTransferFrom(payer, recipient, value);
        }
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
        _valid_token(token);
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
    

    constructor(address[] memory _owners, uint _numConfirmationsRequired) ERC20("Staked FOLD", "stFOLD") {
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
        if (totalsWETH[current_week] == 0 && liquidityWETH > 0) {
            totalsWETH[current_week] = liquidityWETH;
        } // if the vault was emptied then we don't need to roll over past liquidity
        if (totalsUSDC[current_week] == 0 && liquidityUSDC > 0) {
            totalsUSDC[current_week] = liquidityUSDC;
        }
    }

    //@notice Function to withdraw assets from the mevEth contract
    /// @param useQueue Flag whether to use the withdrawal queue
    /// @param receiver The address user whom should receive the mevEth out
    /// @param owner The address of the owner of the mevEth
    /// @param assets The amount of assets that should be withdrawn
    /// @param shares shares that will be burned
    function _withdraw(bool useQueue, address receiver, address owner, uint256 assets, uint256 shares) internal {
        // If withdraw is less than the minimum deposit / withdraw amount, revert
        if (assets < MIN_WITHDRAWAL) revert MevEthErrors.WithdrawTooSmall();
        // Sandwich protection
        uint256 blockNumber = block.number;

        if (((blockNumber - lastDeposit[msg.sender]) == 0 || (blockNumber - lastDeposit[owner] == 0)) && (blockNumber - lastRewards) == 0) {
            revert MevEthErrors.SandwichProtection();
        }

        _updateAllowance(owner, shares);

        // Update the elastic and base
        fraction.elastic -= uint128(assets);
        fraction.base -= uint128(shares);

        // Burn the shares and emit a withdraw event for offchain listeners to know that a withdraw has occured
        _burn(owner, shares);

        uint availableBalance = address(this).balance - withdrawalAmountQueued; // available balance will be adjusted
        uint amountToSend = assets;
        if (availableBalance < assets) {
            if (!useQueue) revert MevEthErrors.NotEnoughEth();
            // Available balance is sent, and the remainder must be withdrawn via the queue
            uint256 amountOwed = assets - availableBalance;
            ++queueLength;
            withdrawalQueue[queueLength] = WithdrawalTicket({claimed: false,
                receiver: receiver, amount: uint128(amountOwed),
                accumulatedAmount: withdrawalQueue[queueLength - 1].accumulatedAmount + uint128(amountOwed)
            });
            emit WithdrawalQueueOpened(receiver, queueLength, amountOwed);
            amountToSend = availableBalance;
        }
        if (amountToSend != 0) {
            // As with ERC4626, we log assets and shares as if there is no queue, and everything has been withdrawn
            // as this most closely resembles what is happened
            emit Withdraw(msg.sender, owner, receiver, assets, shares);

            IWETH(WETH).deposit{ value: amountToSend }();
            IWETH(WETH).safeTransfer(receiver, amountToSend);
        }
    }


    function withdraw(uint positionValue) external { //

    }

    /**
     * @dev Withdraw UniV3 LP deposit from vault (changing the owner back to original)
     */
    function withdrawToken(uint tokenId) external {
        uint timestamp = depositTimestamps[msg.sender][tokenId]; // verify that a deposit exists
        require(timestamp > 0, "FOLDstaking::withdraw: no owner exists for this tokenId");
        require( // how long this deposit has been in the vault
            (block.timestamp - timestamp) > minLockDuration,
            "FOLDstaking::withdraw: minimum duration for the deposit has not elapsed yet"
        );
        (address token0, , uint128 liquidity) = _getPositionInfo(tokenId);
        uint week_iterator = (timestamp - deployed) / 1 weeks;

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
                uint totalThisWeek = totalsWETH[week_iterator];
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
            totalReward += (reward * liquidity) / totalLiquidityWETH;
            totalLiquidityWETH -= liquidity;
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
            totalReward += (reward * liquidity) / totalLiquidityUSDC;
            totalLiquidityUSDC -= liquidity;
        }
        delete depositTimestamps[msg.sender][tokenId];
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

    function deposit(address beneficiary, uint amount, address token) external {
        Deposit storage d = totals[beneficiary];
        uint weth;
        if (token == address(0)) {
            weth = msg.value;
            require(msg.value);
        } else {
            (uint usdc, uint fold) = _valid_token(token, amount);
            IERC20(token).safeTransferFrom(msg.sender, address(this), amount);
            if (token == WETH) { IWETH(WETH).withdraw(amount); }
            d.usdc += usdc; d.fold += fold;
        }
        weth += amount;

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
        _depositNFT(uint tokenId, msg.sender);
        nonfungiblePositionManager.transferFrom(msg.sender, address(this), tokenId);
        emit DepositNFT(tokenId, msg.sender);
    }

    function _depositNFT(uint tokenId, address from) internal {
        (address token0, address token1, uint128 liquidity) = _getPositionInfo(tokenId);

        require(token1 == FOLD, "FOLDstaking::deposit: improper token id");
        // usually this means that the owner of the position already closed it
        require(liquidity > 0, "FOLDstaking::deposit: cannot deposit empty amount");

        if (token0 == WETH) {
            totalsWETH[_roll()] += liquidity;
            totalLiquidityWETH += liquidity;
        } else if (token0 == USDC) {
            totalsUSDC[_roll()] += liquidity;
            totalLiquidityUSDC += liquidity;
        } else {
            revert UnsupportedToken();
        }
        depositTimestamps[from][tokenId] = block.timestamp;
        // transfer ownership of LP share to this contract
        require(totalLiquidityWETH <= maxTotalWETH 
        && totalLiquidityUSDC <= maxTotalUSDC, 
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
        _depositNFT(uint tokenId, from);
        emit DepositNFT(tokenId, from);
        return this.onERC721Received.selector;
    }


    /// @notice Add liquidity to an initialized pool
    function _addLiquidity(AddLiquidityParams memory params)
        internal
        returns (
            uint128 liquidity,
            uint256 amount0,
            uint256 amount1
        )
    {
        if (params.amount0Desired == 0 && params.amount1Desired == 0) {
            return (0, 0, 0);
        }

        // compute the liquidity amount
        {
            (uint160 sqrtPriceX96, , , , , , ) = params.key.pool.slot0();
            uint160 sqrtRatioAX96 = TickMath.getSqrtRatioAtTick(
                params.key.tickLower
            );
            uint160 sqrtRatioBX96 = TickMath.getSqrtRatioAtTick(
                params.key.tickUpper
            );

            liquidity = LiquidityAmounts.getLiquidityForAmounts(
                sqrtPriceX96,
                sqrtRatioAX96,
                sqrtRatioBX96,
                params.amount0Desired,
                params.amount1Desired
            );
        }

        (amount0, amount1) = params.key.pool.mint(
            params.recipient,
            params.key.tickLower,
            params.key.tickUpper,
            liquidity,
            abi.encode(
                MintCallbackData({
                    token0: params.key.pool.token0(),
                    token1: params.key.pool.token1(),
                    fee: params.key.pool.fee(),
                    payer: params.payer
                })
            )
        );

        require(
            amount0 >= params.amount0Min && amount1 >= params.amount1Min,
            "SLIP"
        );
    }


    // compound() for compounding trading fees 
    // back into the liquidity pool (Keeper)...
    function compound(Key calldata key) // she's the eighth wonder of the world
        external
        returns (
            uint128 addedLiquidity,
            uint amount0,
            uint amount1
        )
    {

        // trigger an update of the position fees owed snapshots if it has any liquidity
        key.pool.burn(key.tickLower, key.tickUpper, 0);
        (, , , uint128 cachedFeesOwed0, uint128 cachedFeesOwed1) = key
            .pool
            .positions(
                keccak256(
                    abi.encodePacked(
                        address(this),
                        key.tickLower,
                        key.tickUpper
                    )
                )
            );

        /// -----------------------------------------------------------
        /// amount0, amount1 are multi-purposed, see comments below
        /// -----------------------------------------------------------
        amount0 = cachedFeesOwed0;
        amount1 = cachedFeesOwed1;

        /// -----------------------------------------------------------
        /// amount0, amount1 now store the updated amounts of fee owed
        /// -----------------------------------------------------------

        // the fee is likely not balanced (i.e. tokens will be left over after adding liquidity)
        // so here we compute which token to fully claim and which token to partially claim
        // so that we only claim the amounts we need

        {
            (uint160 sqrtRatioX96, , , , , , ) = key.pool.slot0();
            uint160 sqrtRatioAX96 = TickMath.getSqrtRatioAtTick(key.tickLower);
            uint160 sqrtRatioBX96 = TickMath.getSqrtRatioAtTick(key.tickUpper);

            // compute the maximum liquidity addable using the accrued fees
            uint128 maxAddLiquidity = LiquidityAmounts.getLiquidityForAmounts(
                sqrtRatioX96,
                sqrtRatioAX96,
                sqrtRatioBX96,
                amount0,
                amount1
            );

            // compute the token amounts corresponding to the max addable liquidity
            (amount0, amount1) = LiquidityAmounts.getAmountsForLiquidity(
                sqrtRatioX96,
                sqrtRatioAX96,
                sqrtRatioBX96,
                maxAddLiquidity
            );
        }

        /// -----------------------------------------------------------
        /// amount0, amount1 now store the amount of fees to claim
        /// -----------------------------------------------------------

        // the actual amounts collected are returned
        // tokens are transferred to address(this)
        (amount0, amount1) = key.pool.collect(
            address(this),
            key.tickLower,
            key.tickUpper,
            uint128(amount0),
            uint128(amount1)
        );

        /// -----------------------------------------------------------
        /// amount0, amount1 now store the fees claimed
        /// -----------------------------------------------------------

        // add fees to Uniswap pool
        (addedLiquidity, amount0, amount1) = _addLiquidity(
            AddLiquidityParams({key: key,
                recipient: address(this),
                payer: address(this),
                amount0Desired: amount0,
                amount1Desired: amount1,
                amount0Min: 0,
                amount1Min: 0
            })
        );
    

        /// -----------------------------------------------------------
        /// amount0, amount1 now store the tokens added as liquidity
        /// -----------------------------------------------------------

        emit Compound(
            msg.sender,
            keccak256(abi.encode(key)),
            addedLiquidity,
            amount0,
            amount1
        );
    }

}