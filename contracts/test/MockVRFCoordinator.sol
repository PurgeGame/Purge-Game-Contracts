// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

contract MockVRFCoordinator {
    uint256 public nextRequestId = 1;
    mapping(uint256 => address) public requests;

    function requestRandomWords(
        bytes32,
        uint256,
        uint16,
        uint32,
        uint32
    ) external returns (uint256 requestId) {
        requestId = nextRequestId++;
        requests[requestId] = msg.sender;
    }

    receive() external payable {}
}