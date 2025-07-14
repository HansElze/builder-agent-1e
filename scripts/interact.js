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

  console.log("🦑 Interacting with Cuttlefish Vault...")
  console.log("Network:", deploymentInfo.network)
  console.log("Vault Address:", deploymentInfo.contracts.vaultProxy)

  // Get contract instances
  const vault = await ethers.getContractAt("CuttlefishVault", deploymentInfo.contracts.vaultProxy)
  const builderAgent = await ethers.getContractAt("BuilderAgent", deploymentInfo.contracts.builderAgent)
  const mockAsset = await ethers.getContractAt("MockERC20", deploymentInfo.contracts.mockWETH)

  try {
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

    // Simulate AI trade
    console.log("\n🤖 Simulating AI trade...")
    const tradeAmount = ethers.utils.parseEther("50")
    const deadline = Math.floor(Date.now() / 1000) + 3600 // 1 hour from now

    const tradeTx = await builderAgent.triggerTrade(tradeAmount, 0, deadline)
    const receipt = await tradeTx.wait()

    console.log("Trade executed! Gas used:", receipt.gasUsed.toString())

    // Check fees accrued
    const feesAccrued = await vault.totalFeesAccrued()
    console.log("Fees accrued:", ethers.utils.formatEther(feesAccrued), "WETH")

    console.log("\n✅ Interaction completed successfully!")
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
