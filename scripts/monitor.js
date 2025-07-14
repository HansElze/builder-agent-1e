const { ethers } = require("hardhat")
const fs = require("fs")

async function main() {
  const deploymentInfo = JSON.parse(fs.readFileSync("deployment-info.json", "utf8"))
  const vault = await ethers.getContractAt("CuttlefishVault", deploymentInfo.contracts.vaultProxy)

  console.log("🔍 Monitoring Cuttlefish Vault...")
  console.log("Vault Address:", deploymentInfo.contracts.vaultProxy)

  // Set up event listeners
  vault.on("Deposit", (user, assets, shares, event) => {
    console.log(`💰 Deposit: ${ethers.utils.formatEther(assets)} WETH from ${user}`)
  })

  vault.on("Withdraw", (user, assets, shares, event) => {
    console.log(`💸 Withdrawal: ${ethers.utils.formatEther(assets)} WETH to ${user}`)
  })

  vault.on("TradeExecuted", (tokenIn, tokenOut, amountIn, amountOut, event) => {
    console.log(
      `🔄 Trade: ${ethers.utils.formatEther(amountIn)} ${tokenIn} → ${ethers.utils.formatEther(amountOut)} ${tokenOut}`,
    )
  })

  vault.on("FeesExtracted", (amount, event) => {
    console.log(`💼 Fees Extracted: ${ethers.utils.formatEther(amount)} WETH`)
  })

  // Keep monitoring
  console.log("Monitoring events... Press Ctrl+C to stop")

  // Periodic status updates
  setInterval(async () => {
    try {
      const vaultInfo = await vault.getVaultInfo()
      console.log(
        `📊 Status - Assets: ${ethers.utils.formatEther(vaultInfo._totalAssets)} WETH, Shares: ${ethers.utils.formatEther(vaultInfo._totalShares)}`,
      )
    } catch (error) {
      console.error("Error fetching vault info:", error.message)
    }
  }, 30000) // Every 30 seconds
}

main().catch(console.error)
