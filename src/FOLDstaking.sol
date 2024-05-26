// SPDX-License-Identifier: MIT

pragma solidity =0.8.0;

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC721/IERC721.sol";
import "@openzeppelin/contracts/token/ERC721/IERC721Receiver.sol";
import "@openzeppelin/contracts/access/Ownable.sol";

/**
 * @title StakedUPT
 * @dev Lock users' Uniswap LP NFTs (V3 only) or creates an NFT for them (50:50 weighed) with WETH and FOLD
 * inspired by
 ** https://docs.uniswap.org/contracts/v3/guides/liquidity-mining/overview
 **  
 *
 * The contract manages the NFTs (price ranges) for the user, given their total deposit 
 *
 * All the validators that are connected to the Manifold relay can ONLY connect
 * to the Manifold relay (for mevAuction). If there's a service outage (of the relay)
 * Manifold needs to be able to cover the cost (of lost opportunity) for validators
 * missing out on blocks. Stakers are underwriting this risk of (captive insurance).
 *
 * Contract keeps track of the durations of each deposit. Rewards are paid individually
 * to each NFT (multiple deposits may be made of several V3 positions). The duration of
 * the deposit as well as the share of total liquidity deposited in the vault determines
 * how much the reward will be. It's paid from the WETH balance of the contract owner.
 *
 */

import {IUniswapV3Pool} from "@uniswap/v3-core/contracts/interfaces/IUniswapV3Pool.sol";
import {LiquidityAmounts} from "@uniswap/v3-periphery/contracts/libraries/LiquidityAmounts.sol";
interface INonfungiblePositionManager is IERC721 { // reward QD<>USDT or QD<>WETH liquidity deposits
    function positions(uint256 tokenId) external
    view returns (uint96 nonce,address operator,
        address token0, address token1, uint24 fee,
        int24 tickLower, int24 tickUpper, uint128 liquidity,
        uint feeGrowthInside0LastX128,
        uint feeGrowthInside1LastX128,
        uint128 tokensOwed0, uint128 tokensOwed1
    );
}

contract FOLDstaking is Ownable  { // automatically has Re-entrancy Guard
    
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


    // TODO 
    // multisig
    // emergency shutdown
    // formation of NFT
    // de-composition into multiple NFTs
    // medianizer algorithm for price ranges
    // TESTS TESTS TESTS TESTS TESTS TESTS

    /// @notice Inidicates if staking is paused.
    bool public stakingPaused;

    // minimum duration of being in the vault before withdraw can be called (triggering reward payment)
    
    uint public minLockDuration;
    uint public weeklyReward;
    uint public immutable deployed; // timestamp when contract was deployed

    mapping(uint => uint) public totalsUSDC; // week # -> liquidity
    uint public totalLiquidityUSDC; // in UniV3 liquidity units
    uint public maxTotalUSDC; // in the same units

    mapping(uint => uint) public totalsWETH; // week # -> liquidity
    uint public totalLiquidityWETH; // for the WETH<>FOLD pool
    uint public maxTotalWETH;

    IERC20 public immutable weth;
    INonfungiblePositionManager public immutable nonfungiblePositionManager;

    /// @param pool The Uniswap V3 pool
    /// @param tickLower The lower tick of the UniV3 LP position
    /// @param tickUpper The upper tick of the UniV3 LP position
    struct Key { // 
        IUniswapV3Pool pool;
        int24 tickLower;
        int24 tickUpper;
    }

    // You can have multiple positions per address (representing different ranges).

    struct Deposit { 
        uint eth;
        uint fold;
        uint usdc;
    }
    mapping(address => Deposit) deposits;

    mapping(address => mapping(uint => uint)) public depositTimestamps; // for liquidity providers

    // ERC20 addresses (mainnet)
    address constant FOLD = 0xd084944d3c05CD115C09d072B9F44bA3E0E45921;
    address constant USDC = 0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48;
    address constant WETH = 0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2;

    // Uniswap's NonFungiblePositionManager (one for all new pools)
    address constant NFPM = 0xC36442b4a4522E871399CD717aBDD847Ab11FE88;

    uint256 constant HOURS_PER_WEEK = 168;

    error UnsupportedToken();
    error StakingPaused();

    event SetWeeklyReward(uint256 reward);
    event SetMinLockDuration(uint256 duration);

    event SetMaxTotalUSDC(uint256 maxTotal);
    event SetMaxTotalWETH(uint256 maxTotal);

    event Deposit(uint tokenId, address owner);
    event Withdrawal(uint tokenId, address owner, uint rewardPaid);

    event ConfirmTransfer(address indexed owner, uint indexed index);
    event RevokeTransfer(address indexed owner, uint indexed index);
    event ExecuteTransfer(address indexed owner, uint indexed index);

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



     /// @notice Ensures that staking is not paused when invoking a specific function.
    /// @dev This check is used on the createValidator, deposit and mint functions.
    function _stakingUnpaused() internal view {
        if (stakingPaused) revert StakingPaused();
    }

    /// @notice Pauses staking on the MevEth contract.
    /// @dev This function is only callable by addresses with the admin role.
    function pauseStaking() external onlyAdmin {
        stakingPaused = true;
        emit StakingPaused();
    }

    /**
     * @dev Update the weekly reward. Amount in WETH.
     * @param _newReward New weekly reward.
     */
    function setWeeklyReward(uint256 _newReward) external onlyOwner {
        weeklyReward = _newReward;
        emit SetWeeklyReward(_newReward);
    }

    /**
     * @dev Update the minimum lock duration for staked LP tokens.
     * @param _newMinLockDuration New minimum lock duration.(in weeks)
     */
    function setMinLockDuration(uint256 _newMinLockDuration) external onlyOwner {
        require(_newMinLockDuration % 1 weeks == 0, "UniStaker::deposit: Duration must be in units of weeks");
        minLockDuration = _newMinLockDuration;
        emit SetMinLockDuration(_newMinLockDuration);
    }

    /**
     * @dev Update the maximum liquidity the vault may hold (for the FOLD<>USDC pair).
     * The purpose is to increase the amount gradually, so as to not dilute the APY
     * unnecessarily much in beginning.
     * @param _newMaxTotalUSDC New max total.
     */
    function setMaxTotalUSDC(uint256 _newMaxTotalUSDC) external onlyOwner {
        maxTotalUSDC = _newMaxTotalUSDC;
        emit SetMaxTotalUSDC(_newMaxTotalUSDC);
    }

    /**
     * @dev Update the maximum liquidity the vault may hold (for the FOLD<>WETH pair).
     * The purpose is to increase the amount gradually, so as to not dilute the APY
     * unnecessarily much in beginning.
     * @param _newMaxTotalWETH New max total.
     */
    function setMaxTotalWETH(uint256 _newMaxTotalWETH) external onlyOwner {
        maxTotalWETH = _newMaxTotalWETH;
        emit SetMaxTotalWETH(_newMaxTotalWETH);
    }

    
    function submitTransfer(address _to, uint _value, 
        address _token) public onlyOwner {
        require(_token == MO.SFRAX() || _token == MO.SDAI(), "MO::bad address");
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
        require(transfer.confirm >= 2, "cannot execute tx");
        require(IERC20(transfer.token).transfer(transfer.to, transfer.value), "transfer failed");
        transfer.executed = true; 
        emit ExecuteTransfer(msg.sender, _index);
    }
    

    constructor(address[] memory _owners, uint256 _numConfirmationsRequired) Owned(msg.sender) {
        deployed = block.timestamp;
        minLockDuration = 1 weeks;

        maxTotalWETH = type(uint256).max;
        maxTotalUSDC = type(uint256).max;

        weeklyReward = 0.000001 ether; // 0.000001 WETH
        weth = IWETH(WETH);

        nonfungiblePositionManager = INonfungiblePositionManager(NFPM); // UniV3
    }

    function _getPositionInfo(uint tokenId) internal view returns (address token0, address token1, uint128 liquidity) {
        (, , token0, token1, , , , liquidity, , , , ) = nonfungiblePositionManager.positions(tokenId);
    }

    function _rollOverWETH() internal returns (uint current_week) {
        current_week = (block.timestamp - deployed) / 1 weeks;
        // if the vault was emptied then we don't need to roll over past liquidity
        if (totalsWETH[current_week] == 0 && totalLiquidityWETH > 0) {
            totalsWETH[current_week] = totalLiquidityWETH;
        }
    }

    function _rollOverUSDC() internal returns (uint current_week) {
        current_week = (block.timestamp - deployed) / 1 weeks;
        // if the vault was emptied then we don't need to roll over past liquidity
        if (totalLiquidityUSDC > 0 && totalsUSDC[current_week] == 0) {
            totalsUSDC[current_week] = totalLiquidityUSDC;
        }
    }

    /**
     * @dev Withdraw UniV3 LP deposit from vault (changing the owner back to original)
     */
    function withdrawToken(uint256 tokenId) external nonReentrant {
        uint timestamp = depositTimestamps[msg.sender][tokenId]; // verify that a deposit exists
        require(timestamp > 0, "UniStaker::withdraw: no owner exists for this tokenId");
        require( // how long this deposit has been in the vault
            (block.timestamp - timestamp) > minLockDuration,
            "UniStaker::withdraw: minimum duration for the deposit has not elapsed yet"
        );
        (address token0, , uint128 liquidity) = _getPositionInfo(tokenId);
        uint week_iterator = (timestamp - deployed) / 1 weeks;

        // could've deposited right before the end of the week, so need a bit of granularity
        // otherwise an unfairly large portion of rewards may be obtained by staker
        uint so_far = (timestamp - deployed) / 1 hours;
        uint delta = so_far - (week_iterator * HOURS_PER_WEEK);

        uint reward = (delta * weeklyReward) / HOURS_PER_WEEK; // the first reward may be a fraction of a whole week's worth
        uint totalReward = 0;
        if (token0 == WETH) {
            uint current_week = _rollOverWETH();
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
            uint current_week = _rollOverUSDC();
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
        weth.transfer(msg.sender, totalReward);
        // transfer ownership back to the original LP token owner
        nonfungiblePositionManager.transferFrom(address(this), msg.sender, tokenId);

        emit Withdrawal(tokenId, msg.sender, totalReward);
    }

    /**
     * @dev This is one way of treating deposits.
     * Instead of deposit function implementation,
     * user might manually transfer their NFT
     * and this would trigger onERC721Received.
     * Stakers underwrite captive insurance for
     * the relay (against outages in mevAuction)
     */
    function deposit(uint tokenId) external nonReentrant {
        (address token0, address token1, uint128 liquidity) = _getPositionInfo(tokenId);

        require(token1 == FOLD, "UniStaker::deposit: improper token id");
        // usually this means that the owner of the position already closed it
        require(liquidity > 0, "UniStaker::deposit: cannot deposit empty amount");

        if (token0 == WETH) {
            totalsWETH[_rollOverWETH()] += liquidity;
            totalLiquidityWETH += liquidity;
            require(totalLiquidityWETH <= maxTotalWETH, "UniStaker::deposit: totalLiquidity exceed max");
        } else if (token0 == USDC) {
            totalsUSDC[_rollOverUSDC()] += liquidity;
            totalLiquidityUSDC += liquidity;
            require(totalLiquidityUSDC <= maxTotalUSDC, "UniStaker::deposit: totalLiquidity exceed max");
        } else {
            revert UnsupportedToken();
        }
        depositTimestamps[msg.sender][tokenId] = block.timestamp;
        // transfer ownership of LP share to this contract
        nonfungiblePositionManager.transferFrom(msg.sender, address(this), tokenId);

        emit Deposit(tokenId, msg.sender);
    }

     /// @notice internal deposit function to process Weth or Eth deposits
    /// @param receiver The address user whom should receive the mevEth out
    /// @param assets The amount of assets to deposit
    /// @param shares The amount of shares that should be minted
    function _deposit(address receiver, uint256 assets, uint256 shares) internal {
        // If the deposit is less than the minimum deposit, revert
        if (assets < MIN_DEPOSIT) // revert MevEthErrors.DepositTooSmall();

        fraction.elastic += uint128(assets);
        fraction.base += uint128(shares);

        // Update last deposit block for the user recorded for sandwich protection
        lastDeposit[msg.sender] = block.number;
        lastDeposit[receiver] = block.number;

        if (msg.value == 0) {
            WETH9.safeTransferFrom(msg.sender, address(this), assets);
            WETH9.withdraw(assets);
        } else {
            if (msg.value != assets) revert MevEthErrors.WrongDepositAmount();
        }

        // Mint MevEth shares to the receiver
        _mint(receiver, shares);

        // Emit the deposit event to notify offchain listeners that a deposit has occured
        emit Deposit(msg.sender, receiver, assets, shares);
    }

    /// @notice Function to deposit assets into the mevEth contract
    /// @param assets The amount of WETH which should be deposited
    /// @param receiver The address user whom should receive the mevEth out
    /// @return shares The amount of shares minted
    function deposit(uint256 assets, address receiver) external payable returns (uint256 shares) {
        _stakingUnpaused();

        // Convert the assets to shares and update the fraction elastic and base
        shares = convertToShares(assets);

        // Deposit the assets
        _deposit(receiver, assets, shares);
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
        uint256 tokenId, bytes calldata data
    ) external override returns (bytes4) { 

        return this.onERC721Received.selector;
    }

    // compound() for compounding trading fees back into the liquidity pool
    function compound(Key calldata key)
        external
        virtual
        override
        returns (
            uint128 addedLiquidity,
            uint256 amount0,
            uint256 amount1
        )
    {
        uint256 protocolFee_ = protocolFee;

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

        if (protocolFee_ > 0) {
            // take fee from amount0 and amount1 and transfer to factory
            // amount0 uses 128 bits, protocolFee uses 60 bits
            // so amount0 * protocolFee can't overflow 256 bits
            uint256 fee0 = (amount0 * protocolFee_) / WAD;
            uint256 fee1 = (amount1 * protocolFee_) / WAD;

            // add fees (minus protocol fees) to Uniswap pool
            (addedLiquidity, amount0, amount1) = _addLiquidity(
                LiquidityManagement.AddLiquidityParams({
                    key: key,
                    recipient: address(this),
                    payer: address(this),
                    amount0Desired: amount0 - fee0,
                    amount1Desired: amount1 - fee1,
                    amount0Min: 0,
                    amount1Min: 0
                })
            );

            // the protocol fees are now stored in the factory itself
            // and can be withdrawn by the owner via sweepTokens()

            // emit event
            emit PayProtocolFee(fee0, fee1);
        } else {
            // add fees to Uniswap pool
            (addedLiquidity, amount0, amount1) = _addLiquidity(
                LiquidityManagement.AddLiquidityParams({
                    key: key,
                    recipient: address(this),
                    payer: address(this),
                    amount0Desired: amount0,
                    amount1Desired: amount1,
                    amount0Min: 0,
                    amount1Min: 0
                })
            );
        }

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