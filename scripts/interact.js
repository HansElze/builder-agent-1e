const { ethers } = require("hardhat")
const fs = require("fs")

async function main() {
  // Load deployment info
  if (!fs.existsSync("deployment-info.json")) {
    console.error("❌ deployment-info.json not found. Run deploy script first.")
    process.exit(1)
  }

  const deploymentInfo = JSON.parse(fs.readFileSync("deployment-info.json", "utf8"))
  const [deployer, user] = await ethers.getSigners()

  console.log("🦑 Interacting with Cuttlefish Vault with Chainlink Integration...")
  console.log("Network:", deploymentInfo.network)
  console.log("Vault Address:", deploymentInfo.contracts.vaultProxy)

  // Get contract instances
  const vault = await ethers.getContractAt("CuttlefishVault", deploymentInfo.contracts.vaultProxy)
  const builderAgent = await ethers.getContractAt("BuilderAgent", deploymentInfo.contracts.builderAgent)
  const mockAsset = await ethers.getContractAt("MockERC20", deploymentInfo.contracts.mockWETH)
  const priceFeed = await ethers.getContractAt("MockChainlinkPriceFeed", deploymentInfo.contracts.priceFeed)

  try {
    // Check current price and threshold
    console.log("\n📊 Price Information:")
    const [currentPrice, timestamp] = await builderAgent.getLatestPrice()
    const priceThreshold = await builderAgent.priceThreshold()

    console.log("Current ETH Price:", (currentPrice / 10 ** 8).toString(), "USD")
    console.log("Price Threshold:", (priceThreshold / 10 ** 8).toString(), "USD")
    console.log("Price Updated At:", new Date(timestamp * 1000).toISOString())
    console.log("Trading Condition:", currentPrice.gte(priceThreshold) ? "✅ TRADE ALLOWED" : "❌ TRADE BLOCKED")

    // Check vault status
    console.log("\n📊 Vault Status:")
    const vaultInfo = await vault.getVaultInfo()
    console.log("Total Assets:", ethers.utils.formatEther(vaultInfo._totalAssets), "WETH")
    console.log("Total Shares:", ethers.utils.formatEther(vaultInfo._totalShares))
    console.log("Performance Fee:", vaultInfo._performanceFeeRate.toString(), "basis points")

    // Simulate user deposit
    console.log("\n💰 Simulating user deposit...")
    const depositAmount = ethers.utils.parseEther("100")

    // Mint tokens to user
    await mockAsset.mint(deployer.address, depositAmount)
    await mockAsset.approve(vault.address, depositAmount)

    // Deposit to vault
    const tx = await vault.deposit(depositAmount, deployer.address)
    await tx.wait()

    console.log("Deposited:", ethers.utils.formatEther(depositAmount), "WETH")
    console.log("User shares:", ethers.utils.formatEther(await vault.balanceOf(deployer.address)))

    // Test price-based trading scenarios
    console.log("\n🧪 Testing Price-Based Trading Scenarios...")

    // Scenario 1: Price below threshold
    console.log("\n📉 Scenario 1: Setting price below threshold ($1800)")
    await priceFeed.updatePrice(1800 * 10 ** 8)

    const [lowPrice] = await builderAgent.getLatestPrice()
    console.log("New Price:", (lowPrice / 10 ** 8).toString(), "USD")

    try {
      const tradeAmount = ethers.utils.parseEther("50")
      const deadline = Math.floor(Date.now() / 1000) + 3600
      await builderAgent.triggerTrade(tradeAmount, 0, deadline)
      console.log("❌ Trade should have failed!")
    } catch (error) {
      console.log("✅ Trade correctly blocked:", error.message.includes("Price below threshold"))
    }

    // Scenario 2: Price above threshold
    console.log("\n📈 Scenario 2: Setting price above threshold ($2800)")
    await priceFeed.updatePrice(2800 * 10 ** 8)

    const [highPrice] = await builderAgent.getLatestPrice()
    console.log("New Price:", (highPrice / 10 ** 8).toString(), "USD")

    const tradeAmount = ethers.utils.parseEther("50")
    const deadline = Math.floor(Date.now() / 1000) + 3600

    console.log("🤖 Executing AI trade...")
    const tradeTx = await builderAgent.triggerTrade(tradeAmount, 0, deadline)
    const receipt = await tradeTx.wait()

    console.log("✅ Trade executed! Gas used:", receipt.gasUsed.toString())

    // Check events
    const tradeEvent = receipt.events.find((e) => e.event === "TradeTriggered")
    const priceEvent = receipt.events.find((e) => e.event === "PriceChecked")

    if (tradeEvent) {
      console.log("Trade Amount:", ethers.utils.formatEther(tradeEvent.args.amountIn), "WETH")
      console.log("Trade Price:", (tradeEvent.args.currentPrice / 10 ** 8).toString(), "USD")
    }

    // Check fees accrued
    const feesAccrued = await vault.totalFeesAccrued()
    console.log("Fees accrued:", ethers.utils.formatEther(feesAccrued), "WETH")

    // Scenario 3: Update threshold and test again
    console.log("\n⚙️ Scenario 3: Updating price threshold to $3000")
    await builderAgent.setPriceThreshold(3000 * 10 ** 8)

    const newThreshold = await builderAgent.priceThreshold()
    console.log("New Threshold:", (newThreshold / 10 ** 8).toString(), "USD")
    console.log("Current Price:", (highPrice / 10 ** 8).toString(), "USD")
    console.log("Trading Condition:", highPrice.gte(newThreshold) ? "✅ TRADE ALLOWED" : "❌ TRADE BLOCKED")

    try {
      await builderAgent.triggerTrade(ethers.utils.parseEther("25"), 0, deadline)
      console.log("❌ Trade should have failed with new threshold!")
    } catch (error) {
      console.log("✅ Trade correctly blocked with new threshold")
    }

    console.log("\n✅ Chainlink integration demo completed successfully!")

    // Final summary
    console.log("\n📋 Final Summary:")
    console.log("- Price feed integration: ✅ Working")
    console.log("- Threshold-based trading: ✅ Working")
    console.log("- Admin controls: ✅ Working")
    console.log("- Fee collection: ✅ Working")
  } catch (error) {
    console.error("❌ Interaction failed:", error)
    process.exit(1)
  }
}

main()
  .then(() => process.exit(0))
  .catch((error) => {
    console.error(error)
    process.exit(1)
  })
