// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "@openzeppelin/contracts/access/Ownable.sol";
import "./CuttlefishVault.sol";
import "@chainlink/contracts/src/v0.8/interfaces/AggregatorV3Interface.sol";

contract BuilderAgent is Ownable {
    CuttlefishVault public vault;
    address public vaultAsset; // e.g., mWETH
    address public targetToken; // e.g., mUSDC
    AggregatorV3Interface public priceFeed; // Chainlink price feed (e.g., ETH/USD)

    // Mock AI parameters (in reality, these could come from an off-chain AI model)
    uint256 public priceThreshold; // Minimum price to trigger trade (in USD, scaled by feed decimals)

    event TradeTriggered(uint256 amountIn, uint256 amountOutMin, address[] path, uint256 currentPrice);
    event PriceChecked(uint256 price, uint256 timestamp);

    constructor(
        address _vault,
        address _vaultAsset,
        address _targetToken,
        address _priceFeed,
        uint256 _priceThreshold
    ) Ownable(msg.sender) {
        vault = CuttlefishVault(_vault);
        vaultAsset = _vaultAsset;
        targetToken = _targetToken;
        priceFeed = AggregatorV3Interface(_priceFeed);
        priceThreshold = _priceThreshold; // e.g., 2000 * 10^8 for ETH/USD at $2000
    }

    // Check latest price from Chainlink feed
    function getLatestPrice() public view returns (uint256, uint256) {
        (, int256 price, , uint256 updatedAt, ) = priceFeed.latestRoundData();
        require(price > 0, "Invalid price data");
        require(updatedAt > block.timestamp - 1 hours, "Price data stale");
        return (uint256(price), updatedAt);
    }

    // AI-like trade logic: Trigger trade if price meets threshold
    function triggerTrade(
        uint256 amountIn,
        uint256 amountOutMin,
        uint256 deadline
    ) external onlyOwner {
        // Check price
        (uint256 price, uint256 updatedAt) = getLatestPrice();
        emit PriceChecked(price, updatedAt);

        // Mock AI decision: Trade only if price is above threshold
        require(price >= priceThreshold, "Price below threshold");

        address[] memory path = new address[](2);
        path[0] = vaultAsset;
        path[1] = targetToken;

        // Call vault's trade function
        vault.executeTradeOnUniswap(amountIn, amountOutMin, path, deadline);

        emit TradeTriggered(amountIn, amountOutMin, path, price);
    }

    // Update target token (admin only)
    function setTargetToken(address newTargetToken) external onlyOwner {
        targetToken = newTargetToken;
    }

    // Update price threshold (admin only)
    function setPriceThreshold(uint256 newThreshold) external onlyOwner {
        priceThreshold = newThreshold;
    }

    // Update price feed (admin only, for flexibility)
    function setPriceFeed(address newPriceFeed) external onlyOwner {
        priceFeed = AggregatorV3Interface(newPriceFeed);
    }
}
