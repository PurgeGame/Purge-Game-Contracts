// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

struct VRFRandomWordsRequest {
    bytes32 keyHash;
    uint256 subId;
    uint16 requestConfirmations;
    uint32 callbackGasLimit;
    uint32 numWords;
    bytes extraArgs;
}

interface IVRFConsumer {
    function rawFulfillRandomWords(uint256 requestId, uint256[] calldata randomWords) external;
}

contract MockVRFCoordinator {
    uint256 public lastRequestId;

    function requestRandomWords(VRFRandomWordsRequest calldata) external returns (uint256) {
        lastRequestId += 1;
        return lastRequestId;
    }

    function fulfill(address consumer, uint256 requestId, uint256 randomWord) external {
        uint256[] memory words = new uint256[](1);
        words[0] = randomWord;
        IVRFConsumer(consumer).rawFulfillRandomWords(requestId, words);
    }

    function getSubscription(
        uint256
    )
        external
        pure
        returns (uint96 balance, uint96 premium, uint64 reqCount, address owner, address[] memory consumers)
    {
        balance = 0;
        premium = 0;
        reqCount = 0;
        owner = address(0);
        consumers = new address[](0);
    }
}
