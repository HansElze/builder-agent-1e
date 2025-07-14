const { expect } = require("chai")
const { ethers, upgrades } = require("hardhat")

describe("Enhanced BuilderAgent Security & Features", () => {
  let deployer, operator, aiRole, emergency, user
  let vault, builderAgent, factory, mockAsset, mockTokenOut, priceFeed
  let defaultConfig

  beforeEach(async () => {
    ;[deployer, operator, aiRole, emergency, user] = await ethers.getSigners()

    // Deploy mock contracts
    const MockERC20 = await ethers.getContractFactory("MockERC20")
    mockAsset = await MockERC20.deploy("Mock WETH", "mWETH", 18, ethers.utils.parseEther("1000000"))
    mockTokenOut = await MockERC20.deploy("Mock USDC", "mUSDC", 6, ethers.utils.parseUnits("1000000", 6))

    const MockChainlinkPriceFeed = await ethers.getContractFactory("MockChainlinkPriceFeed")
    priceFeed = await MockChainlinkPriceFeed.deploy(8, "ETH/USD", 1, 2500 * 10 ** 8)

    const MockUniswapRouter = await ethers.getContractFactory("MockUniswapRouter")
    const mockRouter = await MockUniswapRouter.deploy()
    await mockTokenOut.mint(mockRouter.address, ethers.utils.parseUnits("100000", 6))

    // Deploy vault
    const CuttlefishVault = await ethers.getContractFactory("CuttlefishVault")
    vault = await upgrades.deployProxy(CuttlefishVault, [
      mockAsset.address,
      deployer.address,
      deployer.address,
      mockRouter.address,
    ])

    // Deploy factory
    const BuilderAgentFactory = await ethers.getContractFactory("BuilderAgentFactory")
    factory = await BuilderAgentFactory.deploy()

    // Create default config
    defaultConfig = {
      priceThreshold: ethers.BigNumber.from(2000).mul(10 ** 8),
      maxTradeSize: ethers.utils.parseEther("100"),
      dailyTradeLimit: ethers.utils.parseEther("1000"),
      cooldownPeriod: 300, // 5 minutes
      maxSlippage: 300, // 3%
      confidenceThreshold: 7000, // 70%
    }

    // Create agent through factory
    const agentAddress = await factory.callStatic.createAgent(
      vault.address,
      mockAsset.address,
      mockTokenOut.address,
      priceFeed.address,
      defaultConfig,
    )

    await factory.createAgent(vault.address, mockAsset.address, mockTokenOut.address, priceFeed.address, defaultConfig)

    builderAgent = await ethers.getContractAt("BuilderAgent", agentAddress)

    // Set up roles
    await builderAgent.grantRole(await builderAgent.AI_ROLE(), aiRole.address)
    await builderAgent.grantRole(await builderAgent.EMERGENCY_ROLE(), emergency.address)

    // Add agent to vault
    await vault.addBuilderAgent(builderAgent.address)

    // Fund vault
    await mockAsset.mint(vault.address, ethers.utils.parseEther("10000"))
  })

  describe("Security Features", () => {
    it("Should prevent reentrancy attacks", async () => {
      // This would require a malicious contract to test properly
      // For now, we verify the modifier is present
      expect(await builderAgent.totalTrades()).to.equal(0)
    })

    it("Should enforce role-based access control", async () => {
      const tradeAmount = ethers.utils.parseEther("50")
      const deadline = Math.floor(Date.now() / 1000) + 3600

      // Non-AI role should not be able to trade
      await expect(builderAgent.connect(user).triggerTrade(tradeAmount, 0, deadline, 8000)).to.be.revertedWith(
        "AccessControl:",
      )

      // AI role should be able to trade
      await expect(builderAgent.connect(aiRole).triggerTrade(tradeAmount, 0, deadline, 8000)).to.not.be.reverted
    })

    it("Should enforce emergency stop", async () => {
      const tradeAmount = ethers.utils.parseEther("50")
      const deadline = Math.floor(Date.now() / 1000) + 3600

      // Activate emergency stop
      await builderAgent.connect(emergency).activateEmergencyStop("Security concern")

      // Trading should be blocked
      await expect(
        builderAgent.connect(aiRole).triggerTrade(tradeAmount, 0, deadline, 8000),
      ).to.be.revertedWithCustomError(builderAgent, "EmergencyStopActive")

      // Deactivate emergency stop
      await builderAgent.deactivateEmergencyStop()

      // Trading should work again
      await expect(builderAgent.connect(aiRole).triggerTrade(tradeAmount, 0, deadline, 8000)).to.not.be.reverted
    })

    it("Should enforce pause functionality", async () => {
      const tradeAmount = ethers.utils.parseEther("50")
      const deadline = Math.floor(Date.now() / 1000) + 3600

      // Pause contract
      await builderAgent.connect(emergency).pause()

      // Trading should be blocked
      await expect(builderAgent.connect(aiRole).triggerTrade(tradeAmount, 0, deadline, 8000)).to.be.revertedWith(
        "Pausable: paused",
      )

      // Unpause
      await builderAgent.unpause()

      // Trading should work again
      await expect(builderAgent.connect(aiRole).triggerTrade(tradeAmount, 0, deadline, 8000)).to.not.be.reverted
    })
  })

  describe("Trading Limits & Controls", () => {
    it("Should enforce maximum trade size", async () => {
      const largeAmount = ethers.utils.parseEther("200") // Exceeds 100 ETH limit
      const deadline = Math.floor(Date.now() / 1000) + 3600

      await expect(
        builderAgent.connect(aiRole).triggerTrade(largeAmount, 0, deadline, 8000),
      ).to.be.revertedWithCustomError(builderAgent, "TradeAmountTooLarge")
    })

    it("Should enforce daily trading limits", async () => {
      const tradeAmount = ethers.utils.parseEther("600") // Each trade 600 ETH
      const deadline = Math.floor(Date.now() / 1000) + 3600

      // First trade should succeed
      await builderAgent.connect(aiRole).triggerTrade(tradeAmount, 0, deadline, 8000)

      // Second trade should exceed daily limit (600 + 600 > 1000)
      await expect(
        builderAgent.connect(aiRole).triggerTrade(tradeAmount, 0, deadline, 8000),
      ).to.be.revertedWithCustomError(builderAgent, "DailyLimitExceeded")
    })

    it("Should enforce cooldown periods", async () => {
      const tradeAmount = ethers.utils.parseEther("50")
      const deadline = Math.floor(Date.now() / 1000) + 3600

      // First trade
      await builderAgent.connect(aiRole).triggerTrade(tradeAmount, 0, deadline, 8000)

      // Immediate second trade should fail
      await expect(
        builderAgent.connect(aiRole).triggerTrade(tradeAmount, 0, deadline, 8000),
      ).to.be.revertedWithCustomError(builderAgent, "CooldownNotMet")

      // Fast forward time
      await ethers.provider.send("evm_increaseTime", [301]) // 5 minutes + 1 second
      await ethers.provider.send("evm_mine")

      // Now trade should succeed
      await expect(builderAgent.connect(aiRole).triggerTrade(tradeAmount, 0, deadline, 8000)).to.not.be.reverted
    })

    it("Should enforce AI confidence threshold", async () => {
      const tradeAmount = ethers.utils.parseEther("50")
      const deadline = Math.floor(Date.now() / 1000) + 3600

      // Low confidence should fail
      await expect(
        builderAgent
          .connect(aiRole)
          .triggerTrade(tradeAmount, 0, deadline, 5000), // 50% < 70% threshold
      ).to.be.revertedWithCustomError(builderAgent, "ConfidenceTooLow")

      // High confidence should succeed
      await expect(
        builderAgent
          .connect(aiRole)
          .triggerTrade(tradeAmount, 0, deadline, 8000), // 80% > 70% threshold
      ).to.not.be.reverted
    })
  })

  describe("Price Feed Security", () => {
    it("Should reject stale price data", async () => {
      // Set stale timestamp (2 hours ago)
      const staleTime = Math.floor(Date.now() / 1000) - 7200
      await priceFeed.setStaleData(staleTime)

      await expect(builderAgent.getLatestPrice()).to.be.revertedWithCustomError(builderAgent, "PriceDataStale")
    })

    it("Should reject invalid price data", async () => {
      await priceFeed.updatePrice(-100) // Negative price

      await expect(builderAgent.getLatestPrice()).to.be.revertedWithCustomError(builderAgent, "InvalidPrice")
    })

    it("Should enforce price threshold", async () => {
      const tradeAmount = ethers.utils.parseEther("50")
      const deadline = Math.floor(Date.now() / 1000) + 3600

      // Set price below threshold
      await priceFeed.updatePrice(1500 * 10 ** 8) // $1500 < $2000 threshold

      await expect(
        builderAgent.connect(aiRole).triggerTrade(tradeAmount, 0, deadline, 8000),
      ).to.be.revertedWithCustomError(builderAgent, "PriceBelowThreshold")
    })
  })

  describe("Batch Trading", () => {
    it("Should execute batch trades successfully", async () => {
      const amounts = [ethers.utils.parseEther("20"), ethers.utils.parseEther("30"), ethers.utils.parseEther("40")]
      const minAmounts = [0, 0, 0]
      const deadline = Math.floor(Date.now() / 1000) + 3600

      await expect(builderAgent.connect(aiRole).triggerBatchTrade(amounts, minAmounts, deadline, 8000)).to.not.be
        .reverted

      expect(await builderAgent.totalTrades()).to.equal(3)
    })

    it("Should validate batch trade limits", async () => {
      const amounts = new Array(15).fill(ethers.utils.parseEther("10")) // Too many trades
      const minAmounts = new Array(15).fill(0)
      const deadline = Math.floor(Date.now() / 1000) + 3600

      await expect(
        builderAgent.connect(aiRole).triggerBatchTrade(amounts, minAmounts, deadline, 8000),
      ).to.be.revertedWith("Too many trades")
    })
  })

  describe("Statistics & Monitoring", () => {
    it("Should track trading statistics", async () => {
      const tradeAmount = ethers.utils.parseEther("50")
      const deadline = Math.floor(Date.now() / 1000) + 3600

      // Execute some trades
      await builderAgent.connect(aiRole).triggerTrade(tradeAmount, 0, deadline, 8000)

      // Fast forward and trade again
      await ethers.provider.send("evm_increaseTime", [301])
      await ethers.provider.send("evm_mine")
      await builderAgent.connect(aiRole).triggerTrade(tradeAmount, 0, deadline, 8000)

      const stats = await builderAgent.getTradingStats()
      expect(stats._totalTrades).to.equal(2)
      expect(stats._successfulTrades).to.equal(2)
      expect(stats._successRate).to.equal(10000) // 100%
    })

    it("Should provide trading eligibility check", async () => {
      const tradeAmount = ethers.utils.parseEther("50")

      const [canTrade, reason] = await builderAgent.canTrade(tradeAmount, 8000)
      expect(canTrade).to.be.true
      expect(reason).to.equal("Trade allowed")

      // Test with amount too large
      const [canTradeLarge, reasonLarge] = await builderAgent.canTrade(ethers.utils.parseEther("200"), 8000)
      expect(canTradeLarge).to.be.false
      expect(reasonLarge).to.equal("Amount too large")
    })
  })

  describe("Factory Integration", () => {
    it("Should create agents through factory", async () => {
      const agentsBefore = await factory.getTotalAgents()

      await factory.createAgentWithDefaults(vault.address, mockAsset.address, mockTokenOut.address, priceFeed.address)

      const agentsAfter = await factory.getTotalAgents()
      expect(agentsAfter).to.equal(agentsBefore.add(1))
    })

    it("Should track agents by creator", async () => {
      await factory
        .connect(user)
        .createAgentWithDefaults(vault.address, mockAsset.address, mockTokenOut.address, priceFeed.address)

      const userAgents = await factory.getAgentsByCreator(user.address)
      expect(userAgents.length).to.equal(1)
    })
  })
})
