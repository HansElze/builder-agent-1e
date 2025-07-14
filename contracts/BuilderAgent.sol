// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "@openzeppelin/contracts/access/AccessControl.sol";
import "@openzeppelin/contracts/security/ReentrancyGuard.sol";
import "@openzeppelin/contracts/security/Pausable.sol";
import "@openzeppelin/contracts/utils/math/Math.sol";
import "./CuttlefishVault.sol";
import "@chainlink/contracts/src/v0.8/interfaces/AggregatorV3Interface.sol";

/**
 * @title BuilderAgent
 * @dev Enhanced AI-powered trading agent with comprehensive security features
 * @author Cuttlefish Labs
 */
contract BuilderAgent is AccessControl, ReentrancyGuard, Pausable {
    using Math for uint256;

    // Role definitions
    bytes32 public constant OPERATOR_ROLE = keccak256("OPERATOR_ROLE");
    bytes32 public constant EMERGENCY_ROLE = keccak256("EMERGENCY_ROLE");
    bytes32 public constant AI_ROLE = keccak256("AI_ROLE");

    // Core contracts
    CuttlefishVault public immutable vault;
    address public immutable vaultAsset;
    address public targetToken;
    AggregatorV3Interface public priceFeed;

    // AI Trading Parameters
    struct TradingConfig {
        uint256 priceThreshold;        // Minimum price to trigger trade
        uint256 maxTradeSize;          // Maximum trade size per transaction
        uint256 dailyTradeLimit;       // Maximum daily trading volume
        uint256 cooldownPeriod;        // Minimum time between trades
        uint256 maxSlippage;           // Maximum allowed slippage (basis points)
        uint256 confidenceThreshold;   // Minimum AI confidence to trade (0-10000)
    }

    TradingConfig public config;

    // Security & Rate Limiting
    uint256 public lastTradeTimestamp;
    uint256 public dailyTradeVolume;
    uint256 public lastDayReset;
    uint256 public totalTrades;
    uint256 public successfulTrades;

    // Price feed validation
    uint256 public constant MAX_PRICE_AGE = 1 hours;
    uint256 public constant MIN_PRICE_DEVIATION = 500; // 5% in basis points
    uint256 public lastValidPrice;

    // Emergency controls
    bool public emergencyStop;
    uint256 public emergencyStopTimestamp;

    // Events
    event TradeTriggered(
        uint256 indexed tradeId,
        uint256 amountIn,
        uint256 amountOutMin,
        address[] path,
        uint256 currentPrice,
        uint256 confidence
    );
    
    event PriceChecked(uint256 price, uint256 timestamp, bool isValid);
    event TradingConfigUpdated(TradingConfig oldConfig, TradingConfig newConfig);
    event EmergencyStopActivated(address indexed activator, string reason);
    event EmergencyStopDeactivated(address indexed deactivator);
    event TargetTokenUpdated(address indexed oldToken, address indexed newToken);
    event PriceFeedUpdated(address indexed oldFeed, address indexed newFeed);

    // Custom errors
    error InvalidPrice();
    error PriceDataStale();
    error PriceBelowThreshold();
    error TradeAmountTooLarge();
    error DailyLimitExceeded();
    error CooldownNotMet();
    error ConfidenceTooLow();
    error EmergencyStopActive();
    error InvalidConfiguration();
    error UnauthorizedAccess();

    /**
     * @dev Constructor with comprehensive validation
     */
    constructor(
        address _vault,
        address _vaultAsset,
        address _targetToken,
        address _priceFeed,
        TradingConfig memory _config
    ) {
        require(_vault != address(0), "Invalid vault address");
        require(_vaultAsset != address(0), "Invalid vault asset");
        require(_targetToken != address(0), "Invalid target token");
        require(_priceFeed != address(0), "Invalid price feed");
        require(_config.priceThreshold > 0, "Invalid price threshold");
        require(_config.maxTradeSize > 0, "Invalid max trade size");
        require(_config.maxSlippage <= 1000, "Slippage too high"); // Max 10%

        vault = CuttlefishVault(_vault);
        vaultAsset = _vaultAsset;
        targetToken = _targetToken;
        priceFeed = AggregatorV3Interface(_priceFeed);
        config = _config;

        lastDayReset = block.timestamp;

        // Set up roles
        _grantRole(DEFAULT_ADMIN_ROLE, msg.sender);
        _grantRole(OPERATOR_ROLE, msg.sender);
        _grantRole(EMERGENCY_ROLE, msg.sender);

        // Initialize with current price
        try this.getLatestPrice() returns (uint256 price, uint256) {
            lastValidPrice = price;
        } catch {
            // If price feed fails during deployment, set a default
            lastValidPrice = _config.priceThreshold;
        }
    }

    /**
     * @dev Enhanced price fetching with validation and circuit breakers
     */
    function getLatestPrice() public view returns (uint256, uint256) {
        (, int256 price, , uint256 updatedAt, ) = priceFeed.latestRoundData();
        
        if (price <= 0) revert InvalidPrice();
        if (updatedAt <= block.timestamp - MAX_PRICE_AGE) revert PriceDataStale();

        uint256 currentPrice = uint256(price);
        
        // Check for extreme price movements (circuit breaker)
        if (lastValidPrice > 0) {
            uint256 priceChange = currentPrice > lastValidPrice 
                ? ((currentPrice - lastValidPrice) * 10000) / lastValidPrice
                : ((lastValidPrice - currentPrice) * 10000) / lastValidPrice;
                
            // If price moved more than MIN_PRICE_DEVIATION, require additional validation
            if (priceChange > MIN_PRICE_DEVIATION) {
                // In production, this could trigger additional price source checks
                emit PriceChecked(currentPrice, updatedAt, false);
            }
        }

        return (currentPrice, updatedAt);
    }

    /**
     * @dev Advanced AI trading logic with comprehensive safety checks
     */
    function triggerTrade(
        uint256 amountIn,
        uint256 amountOutMin,
        uint256 deadline,
        uint256 aiConfidence // AI confidence score (0-10000)
    ) external onlyRole(AI_ROLE) nonReentrant whenNotPaused {
        if (emergencyStop) revert EmergencyStopActive();
        
        // Reset daily volume if needed
        _resetDailyVolumeIfNeeded();
        
        // Validate trade parameters
        _validateTradeParameters(amountIn, aiConfidence);
        
        // Check price conditions
        (uint256 currentPrice, uint256 updatedAt) = getLatestPrice();
        emit PriceChecked(currentPrice, updatedAt, true);
        
        if (currentPrice < config.priceThreshold) revert PriceBelowThreshold();
        
        // Update tracking variables
        lastTradeTimestamp = block.timestamp;
        dailyTradeVolume += amountIn;
        totalTrades++;
        lastValidPrice = currentPrice;

        // Execute trade
        address[] memory path = new address[](2);
        path[0] = vaultAsset;
        path[1] = targetToken;

        try vault.executeTradeOnUniswap(amountIn, amountOutMin, path, deadline) {
            successfulTrades++;
            emit TradeTriggered(totalTrades, amountIn, amountOutMin, path, currentPrice, aiConfidence);
        } catch Error(string memory reason) {
            // Revert tracking changes on failure
            dailyTradeVolume -= amountIn;
            totalTrades--;
            revert(reason);
        }
    }

    /**
     * @dev Batch trade execution for multiple positions
     */
    function triggerBatchTrade(
        uint256[] calldata amountsIn,
        uint256[] calldata amountsOutMin,
        uint256 deadline,
        uint256 aiConfidence
    ) external onlyRole(AI_ROLE) nonReentrant whenNotPaused {
        require(amountsIn.length == amountsOutMin.length, "Array length mismatch");
        require(amountsIn.length <= 10, "Too many trades"); // Prevent gas issues

        uint256 totalAmount = 0;
        for (uint256 i = 0; i < amountsIn.length; i++) {
            totalAmount += amountsIn[i];
        }

        // Validate total batch size
        _validateTradeParameters(totalAmount, aiConfidence);

        for (uint256 i = 0; i < amountsIn.length; i++) {
            if (amountsIn[i] > 0) {
                this.triggerTrade(amountsIn[i], amountsOutMin[i], deadline, aiConfidence);
            }
        }
    }

    /**
     * @dev Emergency stop function
     */
    function activateEmergencyStop(string calldata reason) external onlyRole(EMERGENCY_ROLE) {
        emergencyStop = true;
        emergencyStopTimestamp = block.timestamp;
        emit EmergencyStopActivated(msg.sender, reason);
    }

    /**
     * @dev Deactivate emergency stop
     */
    function deactivateEmergencyStop() external onlyRole(DEFAULT_ADMIN_ROLE) {
        emergencyStop = false;
        emit EmergencyStopDeactivated(msg.sender);
    }

    /**
     * @dev Update trading configuration
     */
    function updateTradingConfig(TradingConfig calldata newConfig) external onlyRole(DEFAULT_ADMIN_ROLE) {
        require(newConfig.priceThreshold > 0, "Invalid price threshold");
        require(newConfig.maxTradeSize > 0, "Invalid max trade size");
        require(newConfig.maxSlippage <= 1000, "Slippage too high");
        require(newConfig.confidenceThreshold <= 10000, "Invalid confidence threshold");

        TradingConfig memory oldConfig = config;
        config = newConfig;
        
        emit TradingConfigUpdated(oldConfig, newConfig);
    }

    /**
     * @dev Update target token with validation
     */
    function setTargetToken(address newTargetToken) external onlyRole(OPERATOR_ROLE) {
        require(newTargetToken != address(0), "Invalid target token");
        require(newTargetToken != vaultAsset, "Cannot trade to same asset");
        
        address oldToken = targetToken;
        targetToken = newTargetToken;
        
        emit TargetTokenUpdated(oldToken, newTargetToken);
    }

    /**
     * @dev Update price feed with validation
     */
    function setPriceFeed(address newPriceFeed) external onlyRole(DEFAULT_ADMIN_ROLE) {
        require(newPriceFeed != address(0), "Invalid price feed");
        
        // Validate new price feed works
        AggregatorV3Interface newFeed = AggregatorV3Interface(newPriceFeed);
        (, int256 price, , uint256 updatedAt, ) = newFeed.latestRoundData();
        require(price > 0 && updatedAt > 0, "Invalid price feed");
        
        address oldFeed = address(priceFeed);
        priceFeed = newFeed;
        
        emit PriceFeedUpdated(oldFeed, newPriceFeed);
    }

    /**
     * @dev Pause contract (emergency function)
     */
    function pause() external onlyRole(EMERGENCY_ROLE) {
        _pause();
    }

    /**
     * @dev Unpause contract
     */
    function unpause() external onlyRole(DEFAULT_ADMIN_ROLE) {
        _unpause();
    }

    /**
     * @dev Get comprehensive trading statistics
     */
    function getTradingStats() external view returns (
        uint256 _totalTrades,
        uint256 _successfulTrades,
        uint256 _successRate,
        uint256 _dailyVolume,
        uint256 _lastTradeTime,
        bool _canTrade
    ) {
        _successRate = totalTrades > 0 ? (successfulTrades * 10000) / totalTrades : 0;
        _canTrade = _canTradeNow();
        
        return (
            totalTrades,
            successfulTrades,
            _successRate,
            dailyTradeVolume,
            lastTradeTimestamp,
            _canTrade
        );
    }

    /**
     * @dev Check if trading is currently allowed
     */
    function canTrade(uint256 amountIn, uint256 aiConfidence) external view returns (bool, string memory) {
        if (emergencyStop) return (false, "Emergency stop active");
        if (paused()) return (false, "Contract paused");
        if (block.timestamp < lastTradeTimestamp + config.cooldownPeriod) return (false, "Cooldown period");
        if (amountIn > config.maxTradeSize) return (false, "Amount too large");
        if (aiConfidence < config.confidenceThreshold) return (false, "Confidence too low");
        
        // Check daily limit
        uint256 currentDayVolume = _getCurrentDayVolume();
        if (currentDayVolume + amountIn > config.dailyTradeLimit) return (false, "Daily limit exceeded");
        
        try this.getLatestPrice() returns (uint256 price, uint256) {
            if (price < config.priceThreshold) return (false, "Price below threshold");
        } catch {
            return (false, "Price feed error");
        }
        
        return (true, "Trade allowed");
    }

    // Internal functions

    function _validateTradeParameters(uint256 amountIn, uint256 aiConfidence) internal view {
        if (amountIn > config.maxTradeSize) revert TradeAmountTooLarge();
        if (block.timestamp < lastTradeTimestamp + config.cooldownPeriod) revert CooldownNotMet();
        if (aiConfidence < config.confidenceThreshold) revert ConfidenceTooLow();
        
        uint256 currentDayVolume = _getCurrentDayVolume();
        if (currentDayVolume + amountIn > config.dailyTradeLimit) revert DailyLimitExceeded();
    }

    function _resetDailyVolumeIfNeeded() internal {
        if (block.timestamp >= lastDayReset + 1 days) {
            dailyTradeVolume = 0;
            lastDayReset = block.timestamp;
        }
    }

    function _getCurrentDayVolume() internal view returns (uint256) {
        if (block.timestamp >= lastDayReset + 1 days) {
            return 0;
        }
        return dailyTradeVolume;
    }

    function _canTradeNow() internal view returns (bool) {
        if (emergencyStop || paused()) return false;
        if (block.timestamp < lastTradeTimestamp + config.cooldownPeriod) return false;
        
        try this.getLatestPrice() returns (uint256 price, uint256) {
            return price >= config.priceThreshold;
        } catch {
            return false;
        }
    }

    /**
     * @dev Fallback function to prevent accidental ETH sends
     */
    receive() external payable {
        revert("Contract does not accept ETH");
    }
}
