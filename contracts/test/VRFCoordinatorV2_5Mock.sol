// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

/**
 * @title VRFCoordinatorV2_5Mock
 * @notice Minimal VRF Coordinator mock for testing
 * @dev Simplified version that just tracks requests and allows manual fulfillment
 */
contract VRFCoordinatorV2_5Mock {
    uint256 public s_nextRequestId = 1;
    uint256 public s_nextSubId = 1;

    struct Subscription {
        uint96 balance;
        address[] consumers;
        address owner;
        bool exists;
    }

    struct Request {
        uint256 subId;
        address requester;
        uint32 callbackGasLimit;
        uint32 numWords;
        bool fulfilled;
    }

    mapping(uint256 => Subscription) public s_subscriptions;
    mapping(uint256 => Request) public s_requests;
    mapping(address => uint256[]) public s_consumerSubscriptions;

    event SubscriptionCreated(uint256 indexed subId, address owner);
    event SubscriptionFunded(uint256 indexed subId, uint256 oldBalance, uint256 newBalance);
    event ConsumerAdded(uint256 indexed subId, address consumer);
    event RandomWordsRequested(
        bytes32 indexed keyHash,
        uint256 requestId,
        uint256 preSeed,
        uint256 indexed subId,
        uint16 minimumRequestConfirmations,
        uint32 callbackGasLimit,
        uint32 numWords,
        bytes extraArgs,
        address indexed sender
    );
    event RandomWordsFulfilled(uint256 indexed requestId, uint256 outputSeed, uint256 indexed subId, uint96 payment, bool success);

    error InvalidConsumer();
    error InvalidSubscription();
    error AlreadyFulfilled();
    error InvalidCancel();

    // Struct matching the game's VRFRandomWordsRequest (no extraArgs)
    struct VRFRandomWordsRequest {
        bytes32 keyHash;
        uint256 subId;
        uint16 requestConfirmations;
        uint32 callbackGasLimit;
        uint32 numWords;
    }

    constructor(uint96, uint96, int256) {
        // Ignore constructor params for simplicity
    }

    function createSubscription() external returns (uint256) {
        uint256 subId = s_nextSubId;
        s_nextSubId++;
        s_subscriptions[subId] = Subscription({
            balance: 0,
            consumers: new address[](0),
            owner: msg.sender,
            exists: true
        });
        emit SubscriptionCreated(subId, msg.sender);
        return subId;
    }

    function getSubscription(uint256 subId)
        external
        view
        returns (uint96 balance, uint96 nativeBalance, uint64 reqCount, address owner, address[] memory consumers)
    {
        if (!s_subscriptions[subId].exists) revert InvalidSubscription();
        Subscription storage sub = s_subscriptions[subId];
        return (sub.balance, 0, 0, sub.owner, sub.consumers);
    }

    function fundSubscription(uint256 subId, uint96 amount) public {
        if (!s_subscriptions[subId].exists) revert InvalidSubscription();
        Subscription storage sub = s_subscriptions[subId];
        uint256 oldBalance = sub.balance;
        sub.balance += amount;
        emit SubscriptionFunded(subId, oldBalance, sub.balance);
    }

    function addConsumer(uint256 subId, address consumer) external {
        if (!s_subscriptions[subId].exists) revert InvalidSubscription();
        s_subscriptions[subId].consumers.push(consumer);
        s_consumerSubscriptions[consumer].push(subId);
        emit ConsumerAdded(subId, consumer);
    }

    function requestRandomWords(VRFRandomWordsRequest calldata req) external returns (uint256) {
        if (!s_subscriptions[req.subId].exists) revert InvalidSubscription();

        uint256 requestId = s_nextRequestId++;
        s_requests[requestId] = Request({
            subId: req.subId,
            requester: msg.sender,
            callbackGasLimit: req.callbackGasLimit,
            numWords: req.numWords,
            fulfilled: false
        });

        emit RandomWordsRequested(
            req.keyHash,
            requestId,
            0, // preSeed
            req.subId,
            req.requestConfirmations,
            req.callbackGasLimit,
            req.numWords,
            "", // extraArgs (empty)
            msg.sender
        );

        return requestId;
    }

    function fulfillRandomWords(uint256 requestId, address consumer, uint256[] memory randomWords) external {
        Request storage request = s_requests[requestId];
        if (request.fulfilled) revert AlreadyFulfilled();

        request.fulfilled = true;

        // Call the consumer's rawFulfillRandomWords
        (bool success,) = consumer.call(
            abi.encodeWithSignature("rawFulfillRandomWords(uint256,uint256[])", requestId, randomWords)
        );

        emit RandomWordsFulfilled(requestId, randomWords[0], request.subId, 0, success);
    }

    function cancelSubscription(uint256 subId, address to) external {
        if (!s_subscriptions[subId].exists) revert InvalidSubscription();
        Subscription storage sub = s_subscriptions[subId];

        // Transfer balance to recipient (simplified - real coordinator would send LINK)
        uint96 balance = sub.balance;
        delete s_subscriptions[subId];

        // In a real implementation, this would transfer LINK tokens
        // For testing, we just emit an event
    }

    // For compatibility with LINK token funding
    function onTokenTransfer(address, uint256 amount, bytes calldata data) external {
        uint256 subId = abi.decode(data, (uint256));
        fundSubscription(subId, uint96(amount));
    }
}
