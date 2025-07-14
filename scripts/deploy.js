const { ethers, upgrades, network } = require("hardhat")

async function main() {
  const [deployer] = await ethers.getSigners()

  console.log("🚀 Starting Cuttlefish Vault deployment...")
  console.log("Deploying with account:", deployer.address)
  console.log("Account balance:", ethers.utils.formatEther(await deployer.getBalance()), "ETH")

  try {
    // Deploy mock asset
    console.log("\n📦 Deploying Mock WETH...")
    const MockERC20 = await ethers.getContractFactory("MockERC20")
    const mockAsset = await MockERC20.deploy("Mock WETH", "mWETH", 18, ethers.utils.parseEther("1000000"))
    await mockAsset.deployed()
    console.log("Mock WETH deployed at:", mockAsset.address)

    // Deploy mock output token for swaps
    console.log("\n📦 Deploying Mock USDC...")
    const mockTokenOut = await MockERC20.deploy("Mock USDC", "mUSDC", 6, ethers.utils.parseUnits("1000000", 6))
    await mockTokenOut.deployed()
    console.log("Mock USDC deployed at:", mockTokenOut.address)

    // Deploy mock Chainlink price feed
    console.log("\n📊 Deploying Mock Chainlink Price Feed...")
    const MockChainlinkPriceFeed = await ethers.getContractFactory("MockChainlinkPriceFeed")
    const initialPrice = 2500 * 10 ** 8 // $2500 with 8 decimals
    const priceFeed = await MockChainlinkPriceFeed.deploy(
      8, // decimals
      "ETH/USD",
      1, // version
      initialPrice,
    )
    await priceFeed.deployed()
    console.log("Mock Price Feed deployed at:", priceFeed.address)
    console.log("Initial ETH price set to: $2500")

    // Deploy mock Uniswap router
    console.log("\n📦 Deploying Mock Uniswap Router...")
    const MockUniswapRouter = await ethers.getContractFactory("MockUniswapRouter")
    const mockRouter = await MockUniswapRouter.deploy()
    await mockRouter.deployed()
    console.log("Mock Uniswap router deployed at:", mockRouter.address)

    // Fund mock router with output tokens
    await mockTokenOut.mint(mockRouter.address, ethers.utils.parseUnits("100000", 6))
    console.log("Mock router funded with 100,000 mUSDC")

    // Deploy vault as upgradable proxy
    console.log("\n🦑 Deploying Cuttlefish Vault...")
    const CuttlefishVault = await ethers.getContractFactory("CuttlefishVault")
    const vault = await upgrades.deployProxy(CuttlefishVault, [
      mockAsset.address,
      deployer.address, // Initial builderAgent (updated below)
      deployer.address, // feeCollector
      mockRouter.address,
    ])
    await vault.deployed()

    const implementationAddress = await upgrades.erc1967.getImplementationAddress(vault.address)

    console.log("Vault proxy deployed at:", vault.address)
    console.log("Vault implementation at:", implementationAddress)

    // Deploy builder agent with price feed
    console.log("\n🤖 Deploying Builder Agent with Chainlink integration...")
    const BuilderAgent = await ethers.getContractFactory("BuilderAgent")
    const priceThreshold = 2000 * 10 ** 8 // $2000 threshold
    const builderAgent = await BuilderAgent.deploy(
      vault.address,
      mockAsset.address,
      mockTokenOut.address,
      priceFeed.address,
      priceThreshold,
    )
    await builderAgent.deployed()
    console.log("BuilderAgent deployed at:", builderAgent.address)
    console.log("Price threshold set to: $2000")

    // Update vault to use BuilderAgent as the role
    console.log("\n🔐 Configuring Builder Agent role...")
    await vault.addBuilderAgent(builderAgent.address)
    console.log("BuilderAgent assigned role in vault")

    // Fund vault for testing
    console.log("\n💰 Funding vault for testing...")
    await mockAsset.mint(vault.address, ethers.utils.parseEther("10000"))
    console.log("Vault funded with 10,000 mWETH")

    // Verify deployment
    console.log("\n✅ Verifying deployment...")
    const vaultInfo = await vault.getVaultInfo()
    const currentPrice = await builderAgent.getLatestPrice()
    console.log("Total Assets:", ethers.utils.formatEther(vaultInfo._totalAssets))
    console.log("Current ETH Price:", (currentPrice[0] / 10 ** 8).toString(), "USD")
    console.log("Price Threshold:", (priceThreshold / 10 ** 8).toString(), "USD")

    // Output summary for CI/CD
    console.log("\n🎉 Deployment completed successfully!")
    console.log("\n📋 Contract Summary:")
    console.log("Network:", network.name)
    console.log("Deployer:", deployer.address)
    console.log("Mock WETH:", mockAsset.address)
    console.log("Mock USDC:", mockTokenOut.address)
    console.log("Price Feed:", priceFeed.address)
    console.log("Mock Router:", mockRouter.address)
    console.log("Vault Proxy:", vault.address)
    console.log("Vault Implementation:", implementationAddress)
    console.log("Builder Agent:", builderAgent.address)

    // Save deployment info to JSON for other scripts
    const deploymentInfo = {
      network: network.name,
      deployer: deployer.address,
      contracts: {
        mockWETH: mockAsset.address,
        mockUSDC: mockTokenOut.address,
        priceFeed: priceFeed.address,
        mockRouter: mockRouter.address,
        vaultProxy: vault.address,
        vaultImplementation: implementationAddress,
        builderAgent: builderAgent.address,
      },
      config: {
        initialPrice: initialPrice,
        priceThreshold: priceThreshold,
      },
      timestamp: new Date().toISOString(),
      blockNumber: await ethers.provider.getBlockNumber(),
    }

    // Write to file for other processes to use
    const fs = require("fs")
    fs.writeFileSync("deployment-info.json", JSON.stringify(deploymentInfo, null, 2))
    console.log("\n📄 Deployment info saved to deployment-info.json")
  } catch (error) {
    console.error("❌ Deployment failed:", error)
    process.exit(1)
  }
}

main()
  .then(() => process.exit(0))
  .catch((error) => {
    console.error(error)
    process.exit(1)
  })
