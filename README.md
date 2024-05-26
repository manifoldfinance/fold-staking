
## Introduction 

All the validators that are connected to the Manifold relay can ONLY connect
to the Manifold relay (for mevAuction). If there's a service outage (of the relay). Manifold needs to be able to cover the cost (of lost opportunity) for validators.

Stakers into the `FOLDstaking.sol` contract are underwriting this risk (captive insurance) of missing out on blocks. The contract keeps track of the durations of each deposit. Rewards are paid individually to each depositor.

Multiple deposits may be made of several V3 positions. The duration of each deposit as well as its share of the total liquidity deposited in the vault (for that pair) determines how much the reward will be (it's paid from the WETH balance of the contract).

There is no necessity for a Keeper to continuously compound rewards; however, withdrawals, after initiation, are pro-rated over 14 days if they are above a certain % of the total liquidity in the pool.

## Materials and methods

To become accustomed with the relevant contextual terrain for an undertaking of our scope, we've surveyed some existing work on the subject of "address[ing] the issue of attracting stable liquidity"

Case in point: https://docs.pangolin.exchange/faqs/understanding-sar

The formula there-in for calculating rewards has a useful property:
(position stake / total staked) x (stake duration / average stake duration)

The useful property is in the second half of the expression. Division prevents an overflow from occuring (in the worst-case scenario) because, otherwise, duration would keep increasing (potentially indefinitely), and eventually cause an overflow in the result of the expression. 

When it comes to calculating rewards, specifically, we don't take into account the stake's entire duration, looping through each week on a need-to-count basis (we divide and conquer the problem of aggregating rewards).

For a separate matter, we do factor in the average stake duration. The following property is inherited from the so-called "sunshine & rainbow" design doc: "you can only have 1 position per wallet; you can always add on top of your current position, but you can’t split your position into multiple pieces."

Contrarily, Bunni, a lit protocol (*L*iquidity *I*ncentive *T*oken), wraps UNIv3 NFTs into a fungible token balance. Each balance is tightly coupled to the price range (ticks) for said NFT. As such, Bunni is its own sort of aggregator using multiple fungible token balances for one depositor.

## Analysis 

On an individual basis, depositors to may wish to decide the price range (ticks) *for their own* UNIv3 NFT. They can do this with `FOLDstaking.sol` by creating the NFT in advance (on an external platform), then calling our `depositNFT` function, or by instructing the details for having this NFT be constructed for them through the `deposit` function which takes `DepositParams` 

Choosing price ranges for the individual deposit automatically applies a vote is used to affect the deposits of stakers who show no personal preference for their own NFT. This is because *we don't force* (though we do *encourage*) our depositors to accept the responsibility of this choice.

Instead, by calling our third `deposit` function (with the least number of parameters) they may accept the time-weighted median for the price range (which factors in the individual decisions of depositors for each pool, respectively).

## Observations and results

`npx hardhat test`