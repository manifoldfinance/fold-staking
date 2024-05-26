
const axios = require('axios')
// require('dotenv').config()

const SUBGRAPH_URL = 'https://api.thegraph.com/subgraphs/name/uniswap/uniswap-v3'

TOKEN_IDS_QUERY_USDC = `
{
    positions(where: {
        owner: "0xb13Def621fDFb5C79c71ec8f55dc5D6075e68229"
        pool: "0xe081eeab0adde30588ba8d5b3f6ae5284790f54a"
    }) {
        id
        owner
    }  
}
`
TOKEN_IDS_QUERY_WETH = `
{
    positions(where: {
        owner: "0x14b8e5b39070558c5aed55b5bd48be6e8bd888d6"
        pool: "0x5ecef3b72cb00dbd8396ebaec66e0f87e9596e97"
    }) {
        id
        owner
    }  
}
`

// const { ethers } = require('ethers')
// const INFURA_URL = process.env.INFURA_URL
// const PROVIDER = new ethers.providers.JsonRpcProvider(INFURA_URL)

// const { abi : INonfungiblePositionManagerABI} = require('@uniswap/v3-periphery/artifacts/contracts/interfaces/INonfungiblePositionManager.sol/INonfungiblePositionManager.json')
// const POSITION_MANAGER_ADDRESS = '0xC36442b4a4522E871399CD717aBDD847Ab11FE88'

async function main() {
    const result_weth = await axios.post(SUBGRAPH_URL, { query: TOKEN_IDS_QUERY_WETH })
    const result_usdc = await axios.post(SUBGRAPH_URL, { query: TOKEN_IDS_QUERY_USDC })

    const positions_weth = result_weth.data.data.positions
    const positions_usdc = result_usdc.data.data.positions

    console.log('positions in weth', positions_weth)
    console.log('positions in usdc', positions_usdc)

    // const nonFugiblePositionManagerContract = new ethers.Contract(
    //     POSITION_MANAGER_ADDRESS,
    //     INonfungiblePositionManagerABI,
    //     PROVIDER
    // )

    // const weth = nonFugiblePositionManagerContract.positions(positions_weth[0].id)
    //     .then(res => {
    //         console.log((res.liquidity).toString()) 
    //     })

    // const usdc = nonFugiblePositionManagerContract.positions(positions_usdc[0].id)
    //     .then(res => {
    //         console.log((res.liquidity).toString())
    //     })
}

main()
