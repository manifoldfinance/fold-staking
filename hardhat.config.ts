import '@nomiclabs/hardhat-ethers'
import '@typechain/hardhat'
import '@nomicfoundation/hardhat-toolbox'
import 'hardhat-contract-sizer'

import { resolve } from "path";
import { config as dotenvConfig } from "dotenv";
dotenvConfig({ path: resolve(__dirname, "./.env") });

import '@nomicfoundation/hardhat-verify'
import { HardhatUserConfig } from 'hardhat/config'
import { SolcUserConfig } from 'hardhat/types'
import 'solidity-coverage'

const DEFAULT_COMPILER_SETTINGS: SolcUserConfig = {
  version: '0.8.8',
  settings: {
    optimizer: {
      enabled: true,
      runs: 10_000_000,
    },
    
    metadata: {
      bytecodeHash: 'none',
    },
  },
}

if (process.env.RUN_COVERAGE == '1') {
  /**
   * Updates the default compiler settings when running coverage.
   *
   * See https://github.com/sc-forks/solidity-coverage/issues/417#issuecomment-730526466
   */
  console.info('Using coverage compiler settings')
  DEFAULT_COMPILER_SETTINGS.settings.details = {
    yul: true,
    yulDetails: {
      stackAllocation: true,
    },
  }
}

const privateKey: string | undefined = process.env.PRIVATE_KEY_DEV;
  if (!privateKey) {
    throw new Error("Please set your PRIVATE_KEY in a .env file");
  }

const infuraApiKey: string | undefined = process.env.INFURA_API_KEY;
  if (!infuraApiKey) {
    throw new Error("Please set your INFURA_API_KEY in a .env file");
  }

const etherscanApiKey: string | undefined = process.env.ETHERSCAN_API_KEY;
  if (!etherscanApiKey) {
    throw new Error("Please set your ETHERSCAN_API_KEY in a .env file");
  }

const config: HardhatUserConfig = {
  defaultNetwork: "hardhat",
  networks: {
    hardhat: {
      allowUnlimitedContractSize: true,
    },
    cantoTestnet: {
      url: "https://canto-testnet.plexnode.wtf",
      chainId: 7701,
      accounts: [privateKey],
    },
    canto: {
      url: "https://canto.slingshot.finance",
      chainId: 7700,
      accounts: [privateKey]
    },
    sepolia: {
      url: `https://sepolia.infura.io/v3/${process.env.INFURA_API_KEY}`,
      chainId: 11155111,
      accounts: [privateKey]
    },
    mainnet: {
      url: `https://mainnet.infura.io/v3/${process.env.INFURA_API_KEY}`,
      chainId: 1,
      accounts: [privateKey]
    },
    arbitrumTestnet: {
      url: `https://arbitrum-sepolia.infura.io/v3/${process.env.INFURA_API_KEY}`,
      chainId: 421614,
      accounts: [privateKey]

    },
    arbitrum: {
      url: `https://arbitrum-mainnet.infura.io/v3/${process.env.INFURA_API_KEY}`,
      chainId: 42161,
      accounts: [privateKey]
    },

  },
  solidity: {
    compilers: [DEFAULT_COMPILER_SETTINGS],
  },
  contractSizer: {
    alphaSort: false,
    disambiguatePaths: true,
    runOnCompile: false,
  },
}

export default config
