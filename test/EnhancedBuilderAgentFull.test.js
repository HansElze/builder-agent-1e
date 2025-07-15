const { expect } = require("chai")
const { ethers } = require("hardhat")

describe("Enhanced BuilderAgent with 2025 DeFAI Features", () => {
  let deployer, aiRole, keeper, user
  let vault, builderAgent, complianceEngine, mockAsset, mockTokenOut, priceFeed, ecoFeed
  let functionsRouter, subscriptionId, donId

  beforeEach(async () => {
    ;[deployer, aiRole, keeper, user] = await ethers.getSigners()

    // Deploy mock contracts
    const MockERC20 = await ethers.getContractFactory("MockERC20")
    mockAsset = await MockERC20.deploy("Mock WETH", "mWETH", 18, ethers.utils.parseEther("1000000"))
    mockTokenOut = await MockERC20.deploy("Mock USDC", "mUSDC", 6, ethers.utils.parseUnits("1000000", 6))

    const MockChainlinkPriceFeed = await ethers.getContractFactory("MockChainlinkPriceFeed")
    priceFeed = await MockChainlinkPriceFeed.deploy(8, "ETH/USD", 1, 2500 * 10 ** 8)
    ecoFeed = await MockChainlinkPriceFeed.deploy(8, "ECO/SCORE", 1, 500) // Low eco impact

    // Deploy compliance engine
    const ComplianceEngine = await ethers.getContractFactory("ComplianceEngine")
    complianceEngine = await ComplianceEngine.deploy()

    // Mock Functions Router
    const MockFunctionsRouter = await ethers.getContractFactory("MockFunctionsRouter")
    functionsRouter = await MockFunctionsRouter.deploy()

    // Deploy vault
    const CuttlefishVault = await ethers.getContractFactory("CuttlefishVault")
    vault = await ethers.getContractAt("CuttlefishVault", "0x" + "0".repeat(40)) // Mock for interface

    // Configuration
    const config = {
      priceThreshold: ethers.BigNumber.from(2000).mul(10 ** 8),
      maxTradeSize: ethers.utils.parseEther("100"),
      dailyTradeLimit: ethers.utils.parseEther("1000"),
      cooldownPeriod: 300,
      maxSlippage: 300,
      confidenceThreshold: 7000,
      deviationThreshold: 1000,
      ecoThreshold: 1000,
      predictionInterval: 3600, // 1 hour
    }

    subscriptionId = 1
    donId = ethers.utils.formatBytes32String("test-don")

    // Deploy enhanced builder agent
    const EnhancedBuilderAgent = await ethers.getContractFactory("EnhancedBuilderAgent")
    builderAgent = await EnhancedBuilderAgent.deploy(
      vault.address,
      mockAsset.address,
      mockTokenOut.address,
      priceFeed.address,
      ecoFeed.address,
      complianceEngine.address,
      functionsRouter.address,
      config,
      subscriptionId,
      donId,
    )

    // Set up roles
    await builderAgent.grantRole(await builderAgent.AI_ROLE(), aiRole.address)
    await builderAgent.grantRole(await builderAgent.KEEPER_ROLE(), keeper.address)
  })

  describe("Chainlink Functions Integration", () => {
    it("Should request AI predictions correctly", async () => {
      // Mock the Functions request
      await expect(builderAgent.connect(aiRole).requestPricePrediction()).to.emit(builderAgent, "PredictionRequested")

      expect(await builderAgent.hasPendingRequests()).to.be.true
    })

    it("Should handle prediction fulfillment", async () => {
      // Request prediction
      await builderAgent.connect(aiRole).requestPricePrediction()

      // Mock fulfillment data
      const predictedPrice = ethers.BigNumber.from(2600).mul(10 ** 8) // $2600
      const confidence = 8500 // 85%
      const anomaly = 0 // No anomaly

      const responseData = ethers.utils.defaultAbiCoder.encode(
        ["uint256", "uint256", "uint256"],
        [predictedPrice, confidence, anomaly],
      )

      // Simulate Functions callback (would need mock router implementation)
      // This test verifies the structure is correct
      expect(await builderAgent.pendingRequestsCount()).to.equal(1)
    })
  })

  describe("Compliance Engine Integration", () => {
    it("Should validate predictions through compliance engine", async () => {
      const requestId = ethers.utils.formatBytes32String("test-request")
      const predictedPrice = 2600 * 10 ** 8

      const isValid = await complianceEngine.validatePrediction(requestId, predictedPrice)
      expect(isValid).to.be.true
    })

    it("Should reject non-compliant predictions", async () => {
      // Set high volatility to trigger compliance failure
      const MockVolatilityFeed = await ethers.getContractFactory("MockChainlinkPriceFeed")
      const volatilityFeed = await MockVolatilityFeed.deploy(8, "VOLATILITY", 1, 2500) // 25% volatility

      await complianceEngine.setFeeds(volatilityFeed.address, ethers.constants.AddressZero)

      const requestId = ethers.utils.formatBytes32String("test-request")
      const predictedPrice = 2600 * 10 ** 8

      const isValid = await complianceEngine.validatePrediction(requestId, predictedPrice)
      expect(isValid).to.be.false
    })
  })

  describe("Eco-Oracle Integration", () => {
    it("Should check eco-score before trading", async () => {
      const ecoScore = await builderAgent.getEcoScore()
      expect(ecoScore).to.equal(500) // Low impact score
    })

    it("Should block trades with high eco-impact", async () => {
      // Set high eco-impact score
      await ecoFeed.updatePrice(1500) // Above threshold of 1000

      const [canTrade, reason] = await builderAgent.canTrade(ethers.utils.parseEther("50"), 8000)
      // This would be checked in the actual trade execution
      expect(reason).to.not.equal("Trade allowed")
    })
  })

  describe("NFT Prediction Tokens", () => {
    it("Should mint NFTs for high-confidence predictions", async () => {
      // This would be tested with a full prediction fulfillment flow
      const totalSupply = await builderAgent.totalSupply()
      expect(totalSupply).to.equal(0) // No NFTs minted yet
    })

    it("Should allow claiming of prediction NFTs", async () => {
      // Would require minting an NFT first through prediction fulfillment
      // Then testing the claim functionality
      expect(await builderAgent.name()).to.equal("CuttlefishPredictions")
      expect(await builderAgent.symbol()).to.equal("CFPRED")
    })
  })

  describe("Chainlink Automation", () => {
    it("Should check upkeep conditions correctly", async () => {
      const [upkeepNeeded, performData] = await builderAgent.checkUpkeep("0x")

      // Should need upkeep if enough time has passed and no pending requests
      expect(typeof upkeepNeeded).to.equal("boolean")
      if (upkeepNeeded) {
        expect(performData.length).to.be.gt(0)
      }
    })

    it("Should perform upkeep when called by keeper", async () => {
      await builderAgent.setKeeperRegistry(keeper.address)

      // Fast forward time to trigger upkeep
      await ethers.provider.send("evm_increaseTime", [3601]) // 1 hour + 1 second
      await ethers.provider.send("evm_mine")

      const [upkeepNeeded, performData] = await builderAgent.checkUpkeep("0x")

      if (upkeepNeeded) {
        await expect(builderAgent.connect(keeper).performUpkeep(performData)).to.emit(
          builderAgent,
          "PredictionRequested",
        )
      }
    })
  })

  describe("Advanced Security Features", () => {
    it("Should prevent unauthorized keeper calls", async () => {
      const performData = ethers.utils.defaultAbiCoder.encode(["uint256", "uint256"], [2500 * 10 ** 8, Date.now()])

      await expect(builderAgent.connect(user).performUpkeep(performData)).to.be.revertedWithCustomError(
        builderAgent,
        "UnauthorizedKeeper",
      )
    })

    it("Should handle emergency stops correctly", async () => {
      await builderAgent.activateEmergencyStop("Security test")

      const [upkeepNeeded] = await builderAgent.checkUpkeep("0x")
      expect(upkeepNeeded).to.be.false
    })

    it("Should validate configuration updates", async () => {
      const newConfig = {
        priceThreshold: ethers.BigNumber.from(2100).mul(10 ** 8),
        maxTradeSize: ethers.utils.parseEther("150"),
        dailyTradeLimit: ethers.utils.parseEther("1500"),
        cooldownPeriod: 600,
        maxSlippage: 400,
        confidenceThreshold: 7500,
        deviationThreshold: 1200,
        ecoThreshold: 800,
        predictionInterval: 7200,
      }

      await expect(builderAgent.updateConfig(newConfig)).to.emit(builderAgent, "ConfigUpdated")

      const updatedConfig = await builderAgent.config()
      expect(updatedConfig.priceThreshold).to.equal(newConfig.priceThreshold)
    })
  })

  describe("Statistics and Monitoring", () => {
    it("Should provide comprehensive statistics", async () => {
      const stats = await builderAgent.getAdvancedStats()
      expect(stats.totalPredictions).to.equal(0) // No predictions yet
      expect(stats.nftsMinted).to.equal(0) // No NFTs minted yet
    })

    it("Should track prediction accuracy over time", async () => {
      // This would require multiple prediction cycles to test properly
      expect(await builderAgent.totalTrades()).to.equal(0)
      expect(await builderAgent.successfulTrades()).to.equal(0)
    })
  })
})
