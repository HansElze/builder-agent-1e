// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/security/ReentrancyGuard.sol";
import "./BuilderAgent.sol";

/**
 * @title BuilderAgentFactory
 * @dev Factory contract for deploying and managing BuilderAgent instances
 */
contract BuilderAgentFactory is Ownable, ReentrancyGuard {
    struct AgentInfo {
        address agent;
        address vault;
        address creator;
        uint256 createdAt;
        bool isActive;
    }

    mapping(address => AgentInfo) public agents;
    address[] public allAgents;
    
    // Default configurations
    BuilderAgent.TradingConfig public defaultConfig;
    
    event AgentCreated(
        address indexed agent,
        address indexed vault,
        address indexed creator,
        uint256 timestamp
    );
    
    event AgentDeactivated(address indexed agent, address indexed deactivator);
    event DefaultConfigUpdated(BuilderAgent.TradingConfig newConfig);

    constructor() Ownable(msg.sender) {
        // Set reasonable defaults
        defaultConfig = BuilderAgent.TradingConfig({
            priceThreshold: 2000 * 10**8,      // $2000
            maxTradeSize: 100 ether,           // 100 ETH max per trade
            dailyTradeLimit: 1000 ether,       // 1000 ETH daily limit
            cooldownPeriod: 5 minutes,         // 5 minute cooldown
            maxSlippage: 300,                  // 3% max slippage
            confidenceThreshold: 7000          // 70% minimum confidence
        });
    }

    /**
     * @dev Create a new BuilderAgent with custom configuration
     */
    function createAgent(
        address vault,
        address vaultAsset,
        address targetToken,
        address priceFeed,
        BuilderAgent.TradingConfig memory config
    ) external nonReentrant returns (address) {
        require(vault != address(0), "Invalid vault");
        require(vaultAsset != address(0), "Invalid vault asset");
        require(targetToken != address(0), "Invalid target token");
        require(priceFeed != address(0), "Invalid price feed");

        BuilderAgent agent = new BuilderAgent(
            vault,
            vaultAsset,
            targetToken,
            priceFeed,
            config
        );

        address agentAddress = address(agent);
        
        agents[agentAddress] = AgentInfo({
            agent: agentAddress,
            vault: vault,
            creator: msg.sender,
            createdAt: block.timestamp,
            isActive: true
        });
        
        allAgents.push(agentAddress);
        
        // Grant creator the necessary roles
        agent.grantRole(agent.OPERATOR_ROLE(), msg.sender);
        agent.grantRole(agent.AI_ROLE(), msg.sender);
        
        emit AgentCreated(agentAddress, vault, msg.sender, block.timestamp);
        
        return agentAddress;
    }

    /**
     * @dev Create agent with default configuration
     */
    function createAgentWithDefaults(
        address vault,
        address vaultAsset,
        address targetToken,
        address priceFeed
    ) external returns (address) {
        return createAgent(vault, vaultAsset, targetToken, priceFeed, defaultConfig);
    }

    /**
     * @dev Update default configuration
     */
    function updateDefaultConfig(BuilderAgent.TradingConfig memory newConfig) external onlyOwner {
        require(newConfig.priceThreshold > 0, "Invalid price threshold");
        require(newConfig.maxTradeSize > 0, "Invalid max trade size");
        require(newConfig.maxSlippage <= 1000, "Slippage too high");
        
        defaultConfig = newConfig;
        emit DefaultConfigUpdated(newConfig);
    }

    /**
     * @dev Deactivate an agent (emergency function)
     */
    function deactivateAgent(address agent) external onlyOwner {
        require(agents[agent].agent != address(0), "Agent not found");
        require(agents[agent].isActive, "Agent already deactivated");
        
        agents[agent].isActive = false;
        
        // Pause the agent
        BuilderAgent(agent).pause();
        
        emit AgentDeactivated(agent, msg.sender);
    }

    /**
     * @dev Get all agents created by a specific address
     */
    function getAgentsByCreator(address creator) external view returns (address[] memory) {
        uint256 count = 0;
        
        // Count agents by creator
        for (uint256 i = 0; i < allAgents.length; i++) {
            if (agents[allAgents[i]].creator == creator) {
                count++;
            }
        }
        
        // Create result array
        address[] memory result = new address[](count);
        uint256 index = 0;
        
        for (uint256 i = 0; i < allAgents.length; i++) {
            if (agents[allAgents[i]].creator == creator) {
                result[index] = allAgents[i];
                index++;
            }
        }
        
        return result;
    }

    /**
     * @dev Get total number of agents
     */
    function getTotalAgents() external view returns (uint256) {
        return allAgents.length;
    }

    /**
     * @dev Get active agents count
     */
    function getActiveAgentsCount() external view returns (uint256) {
        uint256 count = 0;
        for (uint256 i = 0; i < allAgents.length; i++) {
            if (agents[allAgents[i]].isActive) {
                count++;
            }
        }
        return count;
    }
}
