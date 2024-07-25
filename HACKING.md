# Fold Captive Staking

> [!NOTE]
> For Developer Reference

## Introduction

All the validators that are connected to the Manifold relay can ONLY connect to the Manifold relay (for mevAuction). If there's a service outage (of the relay), Manifold needs to be able to cover the cost (of lost opportunity) for validators.

Stakers into the `FOLDstaking.sol` contract are underwriting this risk ([captive insurance](https://forums.manifoldfinance.com/t/captive-insurance-and-fold-staking/562)) of missing out on blocks. The contract keeps track of the durations of each deposit. Rewards are paid individually to each depositor.

Staking FOLD tokens transfers LP deposit ownership to the `FOLDstaking` contract. The contract's owners (msig) require the ability to permanently claim FOLD balances in the interest of captive insurance claims through the `claimInsurance` function.

In exchange, LPs are rewarded for staking (in addition to swap fees), and the compounding of their deposits' accrued fees is automated. This serves to incentivize a maximum number of compounds at optimal times with regards to gas costs.

Multiple deposits may be made of several V3 positions. The duration of each deposit as well as its share of the total liquidity deposited in the vault (for that pair) determines how much the reward will be (it's paid from the WETH balance of the contract).

There is no necessity for a Keeper to continuously compound rewards; however, withdrawals, after initiation, are pro-rated over 14 days if they are above a certain percentage of the total liquidity in the pool (borrowing from the queue design of mevETH with some small adjustment to fit).

## Materials and Methods

To become accustomed with the relevant contextual terrain for an undertaking of our scope, we've surveyed some existing work on the subject of "address[ing] the issue of attracting stable liquidity".

Case in point: https://docs.pangolin.exchange/faqs/understanding-sar

The formula therein for calculating rewards has a useful property:
(position stake / total staked) x (stake duration / average stake duration)

The useful property is in the second half of the expression. Division prevents an overflow from occurring (in the worst-case scenario) because, otherwise, duration would keep increasing (potentially indefinitely), and eventually cause an overflow in the result of the expression.

When it comes to calculating rewards, specifically, we don't take into account the stake's entire duration, looping through each week on a need-to-count basis (we divide and conquer the problem of aggregating rewards). Claiming rewards or removing liquidity resets the deposit's timestamp to the current week (reducing its total rewards).

For a separate matter, we do factor in the average stake duration. The following property is inherited from the so-called "sunshine & rainbow" design doc: "you can only have 1 position per wallet; you can always add on top of your current position, but you can’t split your position into multiple pieces."

Contrarily, Bunni, a lit protocol (*L*iquidity *I*ncentive *T*oken), wraps UNIv3 NFTs into a fungible token balance. Each balance is tightly coupled to the price range (ticks) for said NFT. As such, Bunni is its own sort of aggregator using multiple fungible token balances for one depositor.

## Analysis

On an individual basis, depositors may wish to decide the price range (ticks) *for their own* UNIv3 NFT. They can do this with `FOLDstaking.sol` by creating the NFT in advance (on an external platform), then calling our `deposit` function, which takes `DepositParams`.

Choosing price ranges for the individual deposit automatically applies a vote to affect the deposits of stakers who show no personal preference for their own NFT. This is because *we don't force* (though we do *encourage*) our depositors to accept the responsibility of this choice.

Instead, by calling our third `deposit` function (with the least number of parameters) they may accept the time-weighted median for the price range (which factors in the individual decisions of depositors for each pool, respectively).

It is not necessary for LPs to manually claim fees collected by a V3 pool and redeposit them to increase the liquidity of a deposit. Uniswap is designed to handle this automatically, ensuring that fees are continuously working to enhance the earning potential of LPs.

Bunni has a `compound` function to increase the value of share tokens (ERC20 balances that each correspond to a key, which is a pool and a price range to go with it). `FOLDstaking.sol` approaches rewards differently so there is no requirement for this.

The difference also relates to how Bunni pays rewards pro rata to depositors' contribution per price range (relative to the total liquidity for that price range). `FOLDstaking.sol` pays rewards solely based on the duration of the deposit and the total size of the deposit (across all price ranges) relative to the total liquidity in the pool (again, across all price ranges).
