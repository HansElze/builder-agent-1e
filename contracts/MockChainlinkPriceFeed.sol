// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "@chainlink/contracts/src/v0.8/interfaces/AggregatorV3Interface.sol";

contract MockChainlinkPriceFeed is AggregatorV3Interface {
    uint8 public override decimals;
    string public override description;
    uint256 public override version;

    struct RoundData {
        uint80 roundId;
        int256 answer;
        uint256 startedAt;
        uint256 updatedAt;
        uint80 answeredInRound;
    }

    RoundData private latestRound;
    mapping(uint80 => RoundData) private rounds;

    constructor(
        uint8 _decimals,
        string memory _description,
        uint256 _version,
        int256 _initialPrice
    ) {
        decimals = _decimals;
        description = _description;
        version = _version;
        
        // Set initial price data
        latestRound = RoundData({
            roundId: 1,
            answer: _initialPrice,
            startedAt: block.timestamp,
            updatedAt: block.timestamp,
            answeredInRound: 1
        });
        
        rounds[1] = latestRound;
    }

    function getRoundData(uint80 _roundId)
        external
        view
        override
        returns (
            uint80 roundId,
            int256 answer,
            uint256 startedAt,
            uint256 updatedAt,
            uint80 answeredInRound
        )
    {
        RoundData memory round = rounds[_roundId];
        return (
            round.roundId,
            round.answer,
            round.startedAt,
            round.updatedAt,
            round.answeredInRound
        );
    }

    function latestRoundData()
        external
        view
        override
        returns (
            uint80 roundId,
            int256 answer,
            uint256 startedAt,
            uint256 updatedAt,
            uint80 answeredInRound
        )
    {
        return (
            latestRound.roundId,
            latestRound.answer,
            latestRound.startedAt,
            latestRound.updatedAt,
            latestRound.answeredInRound
        );
    }

    // Admin function to update price for testing
    function updatePrice(int256 _price) external {
        latestRound.roundId++;
        latestRound.answer = _price;
        latestRound.startedAt = block.timestamp;
        latestRound.updatedAt = block.timestamp;
        latestRound.answeredInRound = latestRound.roundId;
        
        rounds[latestRound.roundId] = latestRound;
    }

    // Admin function to simulate stale data
    function setStaleData(uint256 _timestamp) external {
        latestRound.updatedAt = _timestamp;
        rounds[latestRound.roundId] = latestRound;
    }
}
