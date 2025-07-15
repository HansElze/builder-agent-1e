// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "@openzeppelin/contracts/access/AccessControl.sol";
import "@openzeppelin/contracts/security/ReentrancyGuard.sol";
import "@openzeppelin/contracts/security/Pausable.sol";
import "@openzeppelin/contracts/utils/math/Math.sol";
import "@openzeppelin/contracts/token/ERC721/ERC721.sol";
import "@openzeppelin/contracts/utils/Counters.sol";
import "./CuttlefishVault.sol";
import "@chainlink/contracts/src/v0.8/interfaces/AggregatorV3Interface.sol";
import "@chainlink/contracts/src/v0.8/interfaces/FunctionsClient.sol";
import "@chainlink/contracts/src/v0.8/interfaces/AutomationCompatibleInterface.sol";

/**
 * @title EnhancedBuilderAgent
 * @dev Next-gen AI trading agent with Chainlink Functions, Automation, and 2025 DeFAI features
 * @author Cuttlefish Labs
 */
contract EnhancedBuilderAgent is 
    AccessControl, 
    ReentrancyGuard, 
    Pausable, 
    FunctionsClient,
    AutomationCompatibleInterface,
    ERC721
{
    using Math for uint256;
    using Counters for Counters.Counter;

    // Role definitions
    bytes32 public constant OPERATOR_ROLE = keccak256("OPERATOR_ROLE");
    bytes32 public constant EMERGENCY_ROLE = keccak256("EMERGENCY_ROLE");
    bytes32 public constant AI_ROLE = keccak256("AI_ROLE");
    bytes32 public constant KEEPER_ROLE = keccak256("KEEPER_ROLE");

    // Core contracts
    CuttlefishVault public immutable vault;
    address public immutable vaultAsset;
    address public targetToken;
    AggregatorV3Interface public priceFeed;
    AggregatorV3Interface public ecoFeed; // Carbon/ESG oracle
    IComplianceEngine public complianceEngine;

    // Chainlink Functions & Automation
    uint64 public subscriptionId;
    bytes32 public donId;
    address public keeperRegistryAddress;
    uint32 public constant CALLBACK_GAS_LIMIT = 300000;
    
    // AI Prediction System
    struct PredictionRequest {
        bytes32 requestId;
        uint256 timestamp;
        uint256 currentPrice;
        bool fulfilled;
        uint256 predictedPrice;
        uint256 confidence;
        bool isAnomaly;
    }

    struct TradingConfig {
        uint256 priceThreshold;
        uint256 maxTradeSize;
        uint256 dailyTradeLimit;
        uint256 cooldownPeriod;
        uint256 maxSlippage;
        uint256 confidenceThreshold;
        uint256 deviationThreshold; // Max allowed price deviation (basis points)
        uint256 ecoThreshold; // Max eco-impact score
        uint256 predictionInterval; // Time between predictions
    }

    TradingConfig public config;
    
    // State tracking
    mapping(bytes32 => PredictionRequest) public predictions;
    mapping(uint256 => bytes32) public dayToPredictionId; // Daily prediction tracking
    Counters.Counter private _predictionTokenIds;
    
    uint256 public lastPredictionTime;
    uint256 public lastTradeTimestamp;
    uint256 public dailyTradeVolume;
    uint256 public lastDayReset;
    uint256 public totalTrades;
    uint256 public successfulTrades;
    uint256 public pendingRequestsCount;
    
    // Price validation
    uint256 public constant MAX_PRICE_AGE = 1 hours;
    uint256 public constant MIN_PRICE_DEVIATION = 500; // 5% circuit breaker
    uint256 public lastValidPrice;
    
    // Emergency controls
    bool public emergencyStop;
    uint256 public emergencyStopTimestamp;

    // JavaScript source for Chainlink Functions
    string public constant AI_PREDICTION_SOURCE = 
        "const apiUrl = args[0];"
        "const symbol = args[1];"
        "const timeframe = args[2];"
        "try {"
        "  const response = await Functions.makeHttpRequest({"
        "    url: `${apiUrl}/predict`,"
        "    method: 'POST',"
        "    headers: { 'Content-Type': 'application/json' },"
        "    data: { symbol, timeframe, features: ['price', 'volume', 'sentiment'] }"
        "  });"
        "  if (response.error) throw new Error(response.error);"
        "  const data = response.data;"
        "  if (!data.prediction || !data.confidence) throw new Error('Invalid response');"
        "  const prediction = Math.round(data.prediction * 100000000); // Scale to 8 decimals"
        "  const confidence = Math.round(data.confidence * 10000); // Scale to basis points"
        "  const anomaly = data.anomaly_score > 0.7 ? 1 : 0;"
        "  return Functions.encodeUint256(prediction) + Functions.encodeUint256(confidence) + Functions.encodeUint256(anomaly);"
        "} catch (error) {"
        "  throw new Error(`API Error: ${error.message}`);"
        "}";

    // Events
    event PredictionRequested(bytes32 indexed requestId, uint256 currentPrice, uint256 timestamp);
    event PredictionFulfilled(
        bytes32 indexed requestId, 
        uint256 predictedPrice, 
        uint256 confidence, 
        bool isAnomaly,
        uint256 tokenId
    );
    event TradeTriggered(
        uint256 indexed tradeId,
        bytes32 indexed predictionId,
        uint256 amountIn,
        uint256 currentPrice,
        uint256 predictedPrice,
        uint256 confidence
    );
    event ComplianceValidated(bytes32 indexed requestId, bool isCompliant);
    event EcoScoreChecked(uint256 score, uint256 threshold, bool passed);
    event EmergencyStopActivated(address indexed activator, string reason);
    event ConfigUpdated(TradingConfig oldConfig, TradingConfig newConfig);

    // Custom errors
    error InvalidPrediction();
    error PredictionNotReady();
    error ComplianceViolation();
    error EcoThresholdExceeded();
    error PendingRequestExists();
    error UnauthorizedKeeper();

    constructor(
        address _vault,
        address _vaultAsset,
        address _targetToken,
        address _priceFeed,
        address _ecoFeed,
        address _complianceEngine,
        address _functionsRouter,
        TradingConfig memory _config,
        uint64 _subscriptionId,
        bytes32 _donId
    ) 
        FunctionsClient(_functionsRouter)
        ERC721("CuttlefishPredictions", "CFPRED")
    {
        require(_vault != address(0), "Invalid vault");
        require(_vaultAsset != address(0), "Invalid vault asset");
        require(_targetToken != address(0), "Invalid target token");
        require(_priceFeed != address(0), "Invalid price feed");

        vault = CuttlefishVault(_vault);
        vaultAsset = _vaultAsset;
        targetToken = _targetToken;
        priceFeed = AggregatorV3Interface(_priceFeed);
        ecoFeed = AggregatorV3Interface(_ecoFeed);
        complianceEngine = IComplianceEngine(_complianceEngine);
        
        subscriptionId = _subscriptionId;
        donId = _donId;
        config = _config;
        
        lastDayReset = block.timestamp;

        // Set up roles
        _grantRole(DEFAULT_ADMIN_ROLE, msg.sender);
        _grantRole(OPERATOR_ROLE, msg.sender);
        _grantRole(EMERGENCY_ROLE, msg.sender);
        _grantRole(KEEPER_ROLE, msg.sender);

        // Initialize with current price
        try this.getLatestPrice() returns (uint256 price, uint256) {
            lastValidPrice = price;
        } catch {
            lastValidPrice = _config.priceThreshold;
        }
    }

    /**
     * @dev Enhanced price fetching with eco-score integration
     */
    function getLatestPrice() public view returns (uint256, uint256) {
        (, int256 price, , uint256 updatedAt, ) = priceFeed.latestRoundData();
        
        if (price <= 0) revert InvalidPrice();
        if (updatedAt <= block.timestamp - MAX_PRICE_AGE) revert PriceDataStale();

        return (uint256(price), updatedAt);
    }

    /**
     * @dev Get eco-impact score from carbon oracle
     */
    function getEcoScore() public view returns (uint256) {
        if (address(ecoFeed) == address(0)) return 0;
        
        try ecoFeed.latestRoundData() returns (
            uint80, int256 score, uint256, uint256 updatedAt, uint80
        ) {
            if (score < 0 || updatedAt <= block.timestamp - MAX_PRICE_AGE) return type(uint256).max;
            return uint256(score);
        } catch {
            return type(uint256).max; // Fail-safe: block trades if eco data unavailable
        }
    }

    /**
     * @dev Check if there are pending prediction requests
     */
    function hasPendingRequests() public view returns (bool) {
        return pendingRequestsCount > 0;
    }

    /**
     * @dev Chainlink Automation: Check if upkeep is needed
     */
    function checkUpkeep(bytes calldata) 
        external 
        view 
        override 
        returns (bool upkeepNeeded, bytes memory performData) 
    {
        upkeepNeeded = (
            !emergencyStop &&
            !paused() &&
            block.timestamp >= lastPredictionTime + config.predictionInterval &&
            !hasPendingRequests()
        );
        
        if (upkeepNeeded) {
            (uint256 currentPrice,) = getLatestPrice();
            performData = abi.encode(currentPrice, block.timestamp);
        }
    }

    /**
     * @dev Chainlink Automation: Perform upkeep (request prediction)
     */
    function performUpkeep(bytes calldata performData) external override {
        if (msg.sender != keeperRegistryAddress && !hasRole(KEEPER_ROLE, msg.sender)) {
            revert UnauthorizedKeeper();
        }

        (uint256 currentPrice, uint256 timestamp) = abi.decode(performData, (uint256, uint256));
        _requestPricePrediction(currentPrice, timestamp);
    }

    /**
     * @dev Request AI price prediction via Chainlink Functions
     */
    function requestPricePrediction() external onlyRole(OPERATOR_ROLE) {
        (uint256 currentPrice,) = getLatestPrice();
        _requestPricePrediction(currentPrice, block.timestamp);
    }

    function _requestPricePrediction(uint256 currentPrice, uint256 timestamp) internal {
        if (hasPendingRequests()) revert PendingRequestExists();

        string[] memory args = new string[](3);
        args[0] = "https://api.cuttlefishlabs.com"; // AI API endpoint
        args[1] = "ETH/USD";
        args[2] = "1h";

        // FIXED: Correct parameter order for _sendRequest
        bytes32 requestId = _sendRequest(
            bytes(AI_PREDICTION_SOURCE),
            new bytes[](0), // encryptedSecretsReferences
            args,           // FIXED: args comes third
            subscriptionId, // FIXED: subscriptionId comes fourth
            CALLBACK_GAS_LIMIT,
            donId
        );

        predictions[requestId] = PredictionRequest({
            requestId: requestId,
            timestamp: timestamp,
            currentPrice: currentPrice,
            fulfilled: false,
            predictedPrice: 0,
            confidence: 0,
            isAnomaly: false
        });

        pendingRequestsCount++;
        lastPredictionTime = timestamp;

        emit PredictionRequested(requestId, currentPrice, timestamp);
    }

    /**
     * @dev Chainlink Functions callback
     */
    function fulfillRequest(bytes32 requestId, bytes memory response, bytes memory err) 
        internal 
        override 
    {
        if (err.length > 0) {
            pendingRequestsCount--;
            return; // Handle error gracefully
        }

        PredictionRequest storage prediction = predictions[requestId];
        if (prediction.requestId == bytes32(0)) return;

        // Decode response: prediction (uint256) + confidence (uint256) + anomaly (uint256)
        require(response.length >= 96, "Invalid response length");
        
        uint256 predictedPrice = abi.decode(response[0:32], (uint256));
        uint256 confidence = abi.decode(response[32:64], (uint256));
        uint256 anomalyFlag = abi.decode(response[64:96], (uint256));

        // Validate prediction
        require(predictedPrice > 0 && confidence <= 10000, "Invalid prediction data");

        // Compliance check
        bool isCompliant = true;
        if (address(complianceEngine) != address(0)) {
            try complianceEngine.validatePrediction(requestId, predictedPrice) returns (bool compliant) {
                isCompliant = compliant;
            } catch {
                isCompliant = false;
            }
        }

        if (!isCompliant) {
            emit ComplianceValidated(requestId, false);
            pendingRequestsCount--;
            return;
        }

        // Update prediction
        prediction.predictedPrice = predictedPrice;
        prediction.confidence = confidence;
        prediction.isAnomaly = anomalyFlag == 1;
        prediction.fulfilled = true;
        pendingRequestsCount--;

        // Mint NFT for successful high-confidence predictions
        uint256 tokenId = 0;
        if (confidence >= 8000) { // 80%+ confidence
            _predictionTokenIds.increment();
            tokenId = _predictionTokenIds.current();
            _mint(address(this), tokenId); // Mint to contract, can be claimed later
        }

        emit PredictionFulfilled(requestId, predictedPrice, confidence, prediction.isAnomaly, tokenId);
        emit ComplianceValidated(requestId, true);

        // Auto-execute trade if conditions are met
        _evaluateAndExecuteTrade(requestId);
    }

    /**
     * @dev Evaluate prediction and execute trade if conditions are met
     */
    function _evaluateAndExecuteTrade(bytes32 requestId) internal {
        PredictionRequest memory prediction = predictions[requestId];
        
        // Skip if anomaly detected
        if (prediction.isAnomaly) return;
        
        // Skip if confidence too low
        if (prediction.confidence < config.confidenceThreshold) return;
        
        // Check eco-score
        uint256 ecoScore = getEcoScore();
        if (ecoScore > config.ecoThreshold) {
            emit EcoScoreChecked(ecoScore, config.ecoThreshold, false);
            return;
        }
        emit EcoScoreChecked(ecoScore, config.ecoThreshold, true);

        // Check if prediction suggests favorable trade
        if (prediction.predictedPrice >= config.priceThreshold) {
            // Calculate trade size based on confidence
            uint256 baseAmount = config.maxTradeSize / 4; // 25% of max as base
            uint256 confidenceMultiplier = (prediction.confidence * 3) / 10000; // 0-3x multiplier
            uint256 tradeAmount = baseAmount + (baseAmount * confidenceMultiplier / 1000);
            
            tradeAmount = Math.min(tradeAmount, config.maxTradeSize);
            
            // Execute trade
            _executePredictionTrade(requestId, tradeAmount);
        }
    }

    /**
     * @dev Execute trade based on prediction
     */
    function _executePredictionTrade(bytes32 requestId, uint256 amount) internal {
        if (emergencyStop || paused()) return;
        
        _resetDailyVolumeIfNeeded();
        
        // Check limits
        if (amount > config.maxTradeSize) return;
        if (dailyTradeVolume + amount > config.dailyTradeLimit) return;
        if (block.timestamp < lastTradeTimestamp + config.cooldownPeriod) return;

        PredictionRequest memory prediction = predictions[requestId];
        
        try vault.executeTradeOnUniswap(
            amount,
            0, // Let vault handle slippage
            _getPath(),
            block.timestamp + 300 // 5 minute deadline
        ) {
            // Update tracking
            lastTradeTimestamp = block.timestamp;
            dailyTradeVolume += amount;
            totalTrades++;
            successfulTrades++;

            emit TradeTriggered(
                totalTrades,
                requestId,
                amount,
                prediction.currentPrice,
                prediction.predictedPrice,
                prediction.confidence
            );
        } catch {
            // Trade failed, don't update counters
        }
    }

    /**
     * @dev Get trading path
     */
    function _getPath() internal view returns (address[] memory) {
        address[] memory path = new address[](2);
        path[0] = vaultAsset;
        path[1] = targetToken;
        return path;
    }

    /**
     * @dev Manual trade trigger with prediction validation
     */
    function triggerPredictionTrade(bytes32 requestId, uint256 amount) 
        external 
        onlyRole(AI_ROLE) 
        nonReentrant 
        whenNotPaused 
    {
        PredictionRequest memory prediction = predictions[requestId];
        require(prediction.fulfilled, "Prediction not fulfilled");
        require(!prediction.isAnomaly, "Anomaly detected");
        require(prediction.confidence >= config.confidenceThreshold, "Confidence too low");

        _executePredictionTrade(requestId, amount);
    }

    /**
     * @dev Claim prediction NFT (for high-confidence predictions)
     */
    function claimPredictionNFT(uint256 tokenId) external {
        require(_exists(tokenId), "Token does not exist");
        require(ownerOf(tokenId) == address(this), "Token already claimed");
        require(hasRole(AI_ROLE, msg.sender) || hasRole(DEFAULT_ADMIN_ROLE, msg.sender), "Unauthorized");
        
        _transfer(address(this), msg.sender, tokenId);
    }

    /**
     * @dev Emergency stop
     */
    function activateEmergencyStop(string calldata reason) external onlyRole(EMERGENCY_ROLE) {
        emergencyStop = true;
        emergencyStopTimestamp = block.timestamp;
        emit EmergencyStopActivated(msg.sender, reason);
    }

    /**
     * @dev Update configuration
     */
    function updateConfig(TradingConfig calldata newConfig) external onlyRole(DEFAULT_ADMIN_ROLE) {
        require(newConfig.priceThreshold > 0, "Invalid threshold");
        require(newConfig.maxTradeSize > 0, "Invalid trade size");
        require(newConfig.confidenceThreshold <= 10000, "Invalid confidence");
        require(newConfig.deviationThreshold <= 5000, "Deviation too high");

        TradingConfig memory oldConfig = config;
        config = newConfig;
        emit ConfigUpdated(oldConfig, newConfig);
    }

    /**
     * @dev Set keeper registry address
     */
    function setKeeperRegistry(address _keeperRegistry) external onlyRole(DEFAULT_ADMIN_ROLE) {
        keeperRegistryAddress = _keeperRegistry;
    }

    /**
     * @dev Update compliance engine
     */
    function setComplianceEngine(address _complianceEngine) external onlyRole(DEFAULT_ADMIN_ROLE) {
        complianceEngine = IComplianceEngine(_complianceEngine);
    }

    /**
     * @dev Update eco feed
     */
    function setEcoFeed(address _ecoFeed) external onlyRole(DEFAULT_ADMIN_ROLE) {
        ecoFeed = AggregatorV3Interface(_ecoFeed);
    }

    // Internal helper functions
    function _resetDailyVolumeIfNeeded() internal {
        if (block.timestamp >= lastDayReset + 1 days) {
            dailyTradeVolume = 0;
            lastDayReset = block.timestamp;
        }
    }

    /**
     * @dev Get comprehensive stats including predictions
     */
    function getAdvancedStats() external view returns (
        uint256 totalPredictions,
        uint256 successfulPredictions,
        uint256 averageConfidence,
        uint256 anomalyCount,
        uint256 nftsMinted
    ) {
        // Implementation would iterate through predictions mapping
        // For gas efficiency, consider using counters in production
        return (0, 0, 0, 0, _predictionTokenIds.current());
    }

    /**
     * @dev Prevent accidental ETH sends
     */
    receive() external payable {
        revert("Contract does not accept ETH");
    }
}

/**
 * @dev Compliance Engine Interface for 2025 regulatory features
 */
interface IComplianceEngine {
    function validatePrediction(bytes32 requestId, uint256 predictedPrice) external view returns (bool);
    function validateTrader(address trader) external view returns (bool);
    function getComplianceScore(address asset) external view returns (uint256);
}
