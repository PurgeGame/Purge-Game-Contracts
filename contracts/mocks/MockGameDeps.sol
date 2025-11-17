// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

interface IPurgeGameRngConsumer {
    function rawFulfillRandomWords(uint256 requestId, uint256[] calldata randomWords) external;
}

struct VRFRandomWordsRequest {
    bytes32 keyHash;
    uint256 subId;
    uint16 requestConfirmations;
    uint32 callbackGasLimit;
    uint32 numWords;
    bytes extraArgs;
}

contract MockRenderer {
    uint32[256] private lastSeed;

    function wireContracts(address, address) external {}

    function setStartingTraitRemaining(uint32[256] calldata values) external {
        lastSeed = values;
    }

    function tokenURI(
        uint256,
        uint256,
        uint32[4] calldata
    ) external pure returns (string memory) {
        return "";
    }

    function getLastSeed() external view returns (uint32[256] memory) {
        return lastSeed;
    }
}

contract MockLinkToken {
    mapping(address => uint256) public balanceOf;

    event Transfer(address indexed from, address indexed to, uint256 value);

    function drip(address to, uint256 amount) external {
        balanceOf[to] += amount;
        emit Transfer(address(0), to, amount);
    }

    function transferAndCall(address to, uint256 value, bytes calldata data) external returns (bool) {
        address from = msg.sender;
        uint256 bal = balanceOf[from];
        require(bal >= value, "insufficient LINK");
        unchecked {
            balanceOf[from] = bal - value;
            balanceOf[to] += value;
        }
        emit Transfer(from, to, value);
        (bool ok, ) = to.call(abi.encodeWithSignature("onTokenTransfer(address,uint256,bytes)", from, value, data));
        require(ok, "transferAndCall failed");
        return true;
    }
}

contract MockVRFCoordinator {
    uint64 private nextId = 1;
    uint96 private immutable subscriptionBalance;
    uint256 public lastRequestId;
    mapping(uint256 => address) private pendingConsumer;
    mapping(uint256 => uint32) private pendingWordCounts;

    constructor(uint96 initialBalance) {
        subscriptionBalance = initialBalance;
    }

    function requestRandomWords(VRFRandomWordsRequest calldata req) external returns (uint256 requestId) {
        requestId = nextId++;
        pendingConsumer[requestId] = msg.sender;
        pendingWordCounts[requestId] = req.numWords == 0 ? 1 : req.numWords;
        lastRequestId = requestId;
    }

    function fulfill(address consumer, uint256 requestId, uint256 randomWord) external {
        address target = pendingConsumer[requestId];
        if (target != consumer || target == address(0)) revert("invalid request");
        delete pendingConsumer[requestId];
        uint32 count = pendingWordCounts[requestId];
        if (count == 0) {
            count = 1;
        }
        delete pendingWordCounts[requestId];
        uint256[] memory words = new uint256[](count);
        for (uint32 i; i < count; ) {
            uint256 seed = randomWord == 0
                ? uint256(keccak256(abi.encodePacked(block.timestamp, requestId, i, consumer)))
                : randomWord;
            words[i] = seed;
            unchecked {
                ++i;
            }
        }
        IPurgeGameRngConsumer(consumer).rawFulfillRandomWords(requestId, words);
    }

    function getSubscription(
        uint256
    ) external view returns (uint96 balance, uint96 premium, uint64 reqCount, address owner, address[] memory consumers) {
        balance = subscriptionBalance;
        premium = 0;
        reqCount = uint64(nextId - 1);
        owner = address(this);
        consumers = new address[](0);
    }

    function onTokenTransfer(address, uint256, bytes calldata) external pure returns (bool) {
        return true;
    }
}
