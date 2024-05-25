const {
    loadFixture, time
} = require("@nomicfoundation/hardhat-toolbox/network-helpers");
const BN = require('bn.js'); const { expect } = require("chai");

describe("Fold staking contract", function () {
    async function deployFixture() { // plain, and empty deployment
        const currentTime = (Date.now() / 1000).toFixed(0)

        const [owner, addr1, addr2, 
            addr3, addr4, addr5 ] = await ethers.getSigners()
            
        const FOLD = await ethers.deployContract("mock")
        await FOLD.waitForDeployment()

        const FOLDstaking = await ethers.deployContract("FOLDstaking", [sDAI.target]);
        await FOLDstaking.waitForDeployment()

       
        return { FOLD, FOLDstaking, owner, 
            addr1, addr2, addr3,
            addr4, addr5, currentTime }
    }

    it("Test mint", async function () {

    });

});