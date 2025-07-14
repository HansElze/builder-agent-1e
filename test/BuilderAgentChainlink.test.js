const { expect } = require("chai")
const { ethers, upgrades } = require("hardhat")

describe("BuilderAgent with Chainlink Integration", () => {
  let deployer, user, feeCollector
  let asset, vault, mockRouter, mockTokenOut, builderAgent, priceFeed
  let initialPrice, priceThreshold

  beforeEach(async () => {
    ;[deployer, user, feeCollector] = await ethers.getSigners()

    // Deploy mock asset
    const MockERC20 = await ethers.getContractFactory("MockERC20")
    asset = await MockERC20.deploy("Mock WETH", "mWETH", 18, ethers.utils.parseEther("1000000"))
    await asset.deployed()

    // Deploy mock output token
    mockTokenOut = await MockERC20.deploy("Mock USDC", "mUSDC", 6, ethers.utils.parseUnits("1000000", 6))
    await mockTokenOut.deployed()

    // Deploy mock Chainlink price feed
    const MockChainlinkPriceFeed = await ethers.getContractFactory("MockChainlinkPriceFeed")
    initialPrice = 2500 * 10 ** 8 // $2500 with 8 decimals
    priceFeed = await MockChainlinkPriceFeed.deploy(8, "ETH/USD", 1, initialPrice)
    await priceFeed.deployed()

    // Deploy mock router
    const MockUniswapRouter = await ethers.getContractFactory("MockUniswapRouter")
    mockRouter = await MockUniswapRouter.deploy()
    await mockRouter.deployed()
    await mockTokenOut.mint(mockRouter.address, ethers.utils.parseUnits("100000", 6))

    // Deploy vault
    const CuttlefishVault = await ethers.getContractFactory("CuttlefishVault")
    vault = await upgrades.deployProxy(CuttlefishVault, [
      asset.address,
      deployer.address,
      feeCollector.address,
      mockRouter.address,
    ])
    await vault.deployed()

    // Deploy builder agent with price feed
    const BuilderAgent = await ethers.getContractFactory("BuilderAgent")
    priceThreshold = 2000 * 10 ** 8 // $2000 threshold
    builderAgent = await BuilderAgent.deploy(
      vault.address,
      asset.address,
      mockTokenOut.address,
      priceFeed.address,
      priceThreshold,
    )
    await builderAgent.deployed()

    // Assign builder agent role
    await vault.addBuilderAgent(builderAgent.address)

    // Fund vault for trades
    await asset.mint(vault.address, ethers.utils.parseEther("10000"))
  })

  describe("Price Feed Integration", () => {
    it("Should read current price from Chainlink feed", async () => {
      const [price, timestamp] = await builderAgent.getLatestPrice()
      expect(price).to.equal(initialPrice)
      expect(timestamp).to.be.gt(0)
    })

    it("Should reject stale price data", async () => {
      // Set price data to be 2 hours old
      const staleTimestamp = Math.floor(Date.now() / 1000) - 7200
      await priceFeed.setStaleData(staleTimestamp)

      await expect(builderAgent.getLatestPrice()).to.be.revertedWith("Price data stale")
    })

    it("Should reject invalid price data", async () => {
      // Set negative price
      await priceFeed.updatePrice(-100)

      await expect(builderAgent.getLatestPrice()).to.be.revertedWith("Invalid price data")
    })
  })

  describe("AI Trading Logic", () => {
    it("Should trigger trade when price is above threshold", async () => {
      // Set price above threshold ($2500 > $2000)
      await priceFeed.updatePrice(2500 * 10 ** 8)

      const amountIn = ethers.utils.parseEther("100")
      const deadline = Math.floor(Date.now() / 1000) + 3600

      await expect(builderAgent.triggerTrade(amountIn, 0, deadline))
        .to.emit(builderAgent, "TradeTriggered")
        .to.emit(builderAgent, "PriceChecked")
        .to.emit(vault, "TradeExecuted")
    })

    it("Should reject trade when price is below threshold", async () => {
      // Set price below threshold ($1500 < $2000)
      await priceFeed.updatePrice(1500 * 10 ** 8)

      const amountIn = ethers.utils.parseEther("100")
      const deadline = Math.floor(Date.now() / 1000) + 3600

      await expect(builderAgent.triggerTrade(amountIn, 0, deadline)).to.be.revertedWith("Price below threshold")
    })

    it("Should emit price check event on every trade attempt", async () => {
      // Set price above threshold
      await priceFeed.updatePrice(2200 * 10 ** 8)

      const amountIn = ethers.utils.parseEther("50")
      const deadline = Math.floor(Date.now() / 1000) + 3600

      const tx = await builderAgent.triggerTrade(amountIn, 0, deadline)
      const receipt = await tx.wait()

      // Check for PriceChecked event
      const priceCheckedEvent = receipt.events.find((e) => e.event === "PriceChecked")
      expect(priceCheckedEvent).to.not.be.undefined
      expect(priceCheckedEvent.args.price).to.equal(2200 * 10 ** 8)
    })
  })

  describe("Admin Functions", () => {
    it("Should allow owner to update price threshold", async () => {
      const newThreshold = 3000 * 10 ** 8 // $3000
      await builderAgent.setPriceThreshold(newThreshold)

      expect(await builderAgent.priceThreshold()).to.equal(newThreshold)
    })

    it("Should allow owner to update price feed", async () => {
      // Deploy new price feed
      const MockChainlinkPriceFeed = await ethers.getContractFactory("MockChainlinkPriceFeed")
      const newPriceFeed = await MockChainlinkPriceFeed.deploy(8, "ETH/USD", 2, 3000 * 10 ** 8)
      await newPriceFeed.deployed()

      await builderAgent.setPriceFeed(newPriceFeed.address)

      expect(await builderAgent.priceFeed()).to.equal(newPriceFeed.address)
    })

    it("Should allow owner to update target token", async () => {
      const MockERC20 = await ethers.getContractFactory("MockERC20")
      const newToken = await MockERC20.deploy("New Token", "NEW", 18, ethers.utils.parseEther("1000000"))
      await newToken.deployed()

      await builderAgent.setTargetToken(newToken.address)

      expect(await builderAgent.targetToken()).to.equal(newToken.address)
    })

    it("Should reject non-owner admin calls", async () => {
      await expect(builderAgent.connect(user).setPriceThreshold(3000 * 10 ** 8)).to.be.revertedWith(
        "Ownable: caller is not the owner",
      )

      await expect(builderAgent.connect(user).setPriceFeed(priceFeed.address)).to.be.revertedWith(
        "Ownable: caller is not the owner",
      )
    })
  })

  describe("Integration Tests", () => {
    it("Should execute complete trading workflow with price conditions", async () => {
      // 1. Set price above threshold
      const tradingPrice = 2800 * 10 ** 8 // $2800
      await priceFeed.updatePrice(tradingPrice)

      // 2. Execute trade
      const amountIn = ethers.utils.parseEther("200")
      const deadline = Math.floor(Date.now() / 1000) + 3600

      const initialVaultAssets = await vault.totalAssets()

      await builderAgent.triggerTrade(amountIn, 0, deadline)

      // 3. Verify trade execution
      const finalVaultAssets = await vault.totalAssets()
      expect(finalVaultAssets).to.be.lt(initialVaultAssets)

      // 4. Verify fees accrued
      const feesAccrued = await vault.totalFeesAccrued()
      expect(feesAccrued).to.be.gt(0)
    })

    it("Should handle multiple price updates and trades", async () => {
      const trades = [
        { price: 2100 * 10 ** 8, amount: ethers.utils.parseEther("50"), shouldSucceed: true },
        { price: 1900 * 10 ** 8, amount: ethers.utils.parseEther("50"), shouldSucceed: false },
        { price: 2500 * 10 ** 8, amount: ethers.utils.parseEther("100"), shouldSucceed: true },
      ]

      for (const trade of trades) {
        await priceFeed.updatePrice(trade.price)
        const deadline = Math.floor(Date.now() / 1000) + 3600

        if (trade.shouldSucceed) {
          await expect(builderAgent.triggerTrade(trade.amount, 0, deadline)).to.emit(builderAgent, "TradeTriggered")
        } else {
          await expect(builderAgent.triggerTrade(trade.amount, 0, deadline)).to.be.revertedWith("Price below threshold")
        }
      }
    })
  })

  describe("Edge Cases", () => {
    it("Should handle price feed decimals correctly", async () => {
      // Test with different decimal precision
      const MockChainlinkPriceFeed = await ethers.getContractFactory("MockChainlinkPriceFeed")
      const priceFeed18 = await MockChainlinkPriceFeed.deploy(18, "ETH/USD", 1, ethers.utils.parseEther("2500"))
      await priceFeed18.deployed()

      const BuilderAgent = await ethers.getContractFactory("BuilderAgent")
      const builderAgent18 = await BuilderAgent.deploy(
        vault.address,
        asset.address,
        mockTokenOut.address,
        priceFeed18.address,
        ethers.utils.parseEther("2000"), // $2000 with 18 decimals
      )
      await builderAgent18.deployed()

      const [price] = await builderAgent18.getLatestPrice()
      expect(price).to.equal(ethers.utils.parseEther("2500"))
    })

    it("Should handle very large and very small prices", async () => {
      // Test with very large price
      const largePrice = ethers.BigNumber.from("999999999999999999") // Max safe integer
      await priceFeed.updatePrice(largePrice)

      const [price] = await builderAgent.getLatestPrice()
      expect(price).to.equal(largePrice)

      // Test with very small price
      const smallPrice = 1 // Minimum positive price
      await priceFeed.updatePrice(smallPrice)

      const [smallPriceResult] = await builderAgent.getLatestPrice()
      expect(smallPriceResult).to.equal(smallPrice)
    })
  })
})
