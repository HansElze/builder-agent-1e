// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "@openzeppelin/contracts/access/AccessControl.sol";
import "@chainlink/contracts/src/v0.8/interfaces/AggregatorV3Interface.sol";

/**
 * @title ComplianceEngine
 * @dev 2025 regulatory compliance engine for DeFAI applications
 */
contract ComplianceEngine is AccessControl {
    bytes32 public constant COMPLIANCE_OFFICER_ROLE = keccak256("COMPLIANCE_OFFICER_ROLE");
    bytes32 public constant REGULATOR_ROLE = keccak256("REGULATOR_ROLE");

    struct ComplianceRule {
        uint256 minPrice;
        uint256 maxPrice;
        uint256 maxVolatility; // basis points
        bool requiresKYC;
        bool isActive;
    }

    struct TraderProfile {
        bool isKYCVerified;
        uint256 riskScore; // 0-10000
        uint256 maxTradeSize;
        bool isBlacklisted;
        uint256 lastComplianceCheck;
    }

    mapping(address => ComplianceRule) public assetRules;
    mapping(address => TraderProfile) public traderProfiles;
    mapping(bytes32 => bool) public approvedPredictions;
    
    // Regulatory feeds
    AggregatorV3Interface public volatilityFeed;
    AggregatorV3Interface public regulatoryFeed;

    event ComplianceRuleUpdated(address indexed asset, ComplianceRule rule);
    event TraderProfileUpdated(address indexed trader, TraderProfile profile);
    event PredictionValidated(bytes32 indexed requestId, bool approved, string reason);
    event RegulatoryAlert(address indexed asset, string alertType, uint256 value);

    constructor() {
        _grantRole(DEFAULT_ADMIN_ROLE, msg.sender);
        _grantRole(COMPLIANCE_OFFICER_ROLE, msg.sender);
    }

    /**
     * @dev Validate AI prediction for compliance
     */
    function validatePrediction(bytes32 requestId, uint256 predictedPrice) 
        external 
        view 
        returns (bool) 
    {
        // Check if prediction is within acceptable bounds
        if (predictedPrice == 0) return false;
        
        // Check volatility constraints
        if (address(volatilityFeed) != address(0)) {
            try volatilityFeed.latestRoundData() returns (
                uint80, int256 volatility, uint256, uint256, uint80
            ) {
                if (volatility > 2000) return false; // Max 20% volatility
            } catch {
                return false; // Fail-safe
            }
        }

        // Check regulatory status
        if (address(regulatoryFeed) != address(0)) {
            try regulatoryFeed.latestRoundData() returns (
                uint80, int256 status, uint256, uint256, uint80
            ) {
                if (status == 0) return false; // Regulatory halt
            } catch {
                return false;
            }
        }

        return true;
    }

    /**
     * @dev Validate trader eligibility
     */
    function validateTrader(address trader) external view returns (bool) {
        TraderProfile memory profile = traderProfiles[trader];
        
        if (profile.isBlacklisted) return false;
        if (profile.riskScore > 8000) return false; // Max 80% risk score
        
        return true;
    }

    /**
     * @dev Get compliance score for asset
     */
    function getComplianceScore(address asset) external view returns (uint256) {
        ComplianceRule memory rule = assetRules[asset];
        if (!rule.isActive) return 0;
        
        // Calculate composite compliance score
        uint256 score = 10000; // Start with perfect score
        
        // Reduce score based on volatility
        if (address(volatilityFeed) != address(0)) {
            try volatilityFeed.latestRoundData() returns (
                uint80, int256 volatility, uint256, uint256, uint80
            ) {
                if (volatility > 1000) { // > 10% volatility
                    score = score * (2000 - uint256(volatility)) / 1000;
                }
            } catch {
                score = score / 2; // Penalize for data unavailability
            }
        }
        
        return score;
    }

    /**
     * @dev Update compliance rule for asset
     */
    function updateAssetRule(address asset, ComplianceRule memory rule) 
        external 
        onlyRole(COMPLIANCE_OFFICER_ROLE) 
    {
        assetRules[asset] = rule;
        emit ComplianceRuleUpdated(asset, rule);
    }

    /**
     * @dev Update trader profile
     */
    function updateTraderProfile(address trader, TraderProfile memory profile) 
        external 
        onlyRole(COMPLIANCE_OFFICER_ROLE) 
    {
        traderProfiles[trader] = profile;
        emit TraderProfileUpdated(trader, profile);
    }

    /**
     * @dev Emergency blacklist trader
     */
    function blacklistTrader(address trader, string calldata reason) 
        external 
        onlyRole(REGULATOR_ROLE) 
    {
        traderProfiles[trader].isBlacklisted = true;
        emit RegulatoryAlert(trader, "BLACKLISTED", block.timestamp);
    }

    /**
     * @dev Set regulatory feeds
     */
    function setFeeds(address _volatilityFeed, address _regulatoryFeed) 
        external 
        onlyRole(DEFAULT_ADMIN_ROLE) 
    {
        volatilityFeed = AggregatorV3Interface(_volatilityFeed);
        regulatoryFeed = AggregatorV3Interface(_regulatoryFeed);
    }
}
