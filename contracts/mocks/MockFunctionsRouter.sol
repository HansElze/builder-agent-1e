// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

/**
 * @title MockFunctionsRouter
 * @dev Mock Chainlink Functions Router for testing
 */
contract MockFunctionsRouter {
    mapping(bytes32 => address) public requestToSender;
    uint256 private requestCounter;

    event RequestSent(bytes32 indexed requestId, address indexed sender);

    function sendRequest(
        uint64, // subscriptionId
        bytes calldata, // data
        uint16, // dataVersion
        uint32, // callbackGasLimit
        bytes32 // donId
    ) external returns (bytes32) {
        bytes32 requestId = keccak256(abi.encodePacked(block.timestamp, msg.sender, requestCounter++));
        requestToSender[requestId] = msg.sender;
        
        emit RequestSent(requestId, msg.sender);
        return requestId;
    }

    // Mock fulfillment function for testing
    function fulfillRequest(bytes32 requestId, bytes memory response) external {
        address sender = requestToSender[requestId];
        require(sender != address(0), "Invalid request");
        
        // Call the fulfillRequest function on the requesting contract
        (bool success,) = sender.call(
            abi.encodeWithSignature("fulfillRequest(bytes32,bytes,bytes)", requestId, response, "")
        );
        require(success, "Fulfillment failed");
    }
}
