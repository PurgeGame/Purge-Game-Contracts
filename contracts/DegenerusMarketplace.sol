// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

/// @notice Minimal ERC20 view used for BURNIE transfers.
interface IERC20Like {
    function transferFrom(address from, address to, uint256 amount) external returns (bool);
    function burnFrom(address from, uint256 amount) external;
    function balanceOf(address account) external view returns (uint256);
}

/// @notice Minimal ERC721 view used for NFT transfers/approvals.
interface IERC721Like {
    function ownerOf(uint256 tokenId) external view returns (address);
    function transferFrom(address from, address to, uint256 tokenId) external;
    function safeTransferFrom(address from, address to, uint256 tokenId) external;
}

/// @title BurnieNonCustodialOffers
    /// @notice Lightweight on-chain P2P fills for BURNIE-denominated asks and bids.
    ///         - Sellers post on-chain asks; buyers call `buy`.
    ///         - Buyers post on-chain offers with a flat fee; sellers call `acceptOffer`.
    ///         - Best-offer view/accept scan active bidders and skip expired/underfunded offers.
    ///         - No funds are escrowed. Single NFT collection is assumed (gamepiece).
contract BurnieNonCustodialOffers {
    // ---------------------------------------------------------------------
    // Errors
    // ---------------------------------------------------------------------
    error Expired();
    error Unauthorized();
    error PriceZero();
    error PaymentFailed();
    error ZeroAddress();

    // ---------------------------------------------------------------------
    // Types
    // ---------------------------------------------------------------------
    struct Ask {
        address seller;  // 160 bits
        uint40 expiry;   // 40 bits (valid until ~36,812 AD)
        // 56 bits gap
        uint256 price;   // 256 bits (denominated in BURNIE, 6 decimals)
    }

    struct Offer {
        uint216 amount;  // 216 bits (denominated in BURNIE, 6 decimals)
        uint40 expiry;   // 40 bits
    }

    struct BestOffer {
        address bidder;
        uint216 amount;
        uint40 expiry;
    }

    // ---------------------------------------------------------------------
    // Events
    // ---------------------------------------------------------------------
    event AskPlaced(address indexed seller, uint256 indexed tokenId, uint256 price, uint256 expiry);
    event AskCanceled(address indexed seller, uint256 indexed tokenId);
    event AskFilled(address indexed buyer, address indexed seller, uint256 tokenId, uint256 price);
    event OfferPlaced(address indexed bidder, uint256 indexed tokenId, uint256 amount, uint256 expiry);
    event OfferCanceled(address indexed bidder, uint256 indexed tokenId);
    event OfferFilled(address indexed seller, address indexed buyer, uint256 tokenId, uint256 amount);

    // ---------------------------------------------------------------------
    // Immutables
    // ---------------------------------------------------------------------
    IERC20Like public immutable burnie;
    IERC721Like public immutable gamepiece;

    uint256 private constant OFFER_FEE = 10 * 1e6; // 10 BURNIE, token has 6 decimals
    uint256 private constant ASK_FEE = 10 * 1e6; // 10 BURNIE
    uint256 private constant BURN_BPS = 200; // 2%
    uint256 private constant BPS_DENOMINATOR = 10_000;

    // ---------------------------------------------------------------------
    // Storage
    // ---------------------------------------------------------------------
    mapping(uint256 => Ask) public asks; // tokenId => ask
    mapping(uint256 => mapping(address => Offer)) public offers; // tokenId => bidder => offer
    mapping(uint256 => address[]) private offerBidders; // tokenId => bidders that have ever placed an offer
    mapping(uint256 => mapping(address => bool)) private offerSeen; // tokenId => bidder seen flag

    // ---------------------------------------------------------------------
    // Constructor
    // ---------------------------------------------------------------------
    constructor(address burnie_, address gamepiece_) {
        if (burnie_ == address(0) || gamepiece_ == address(0)) revert ZeroAddress();
        burnie = IERC20Like(burnie_);
        gamepiece = IERC721Like(gamepiece_);
    }

    // ---------------------------------------------------------------------
    // External entrypoints
    // ---------------------------------------------------------------------

    /// @notice Place an on-chain ask (listing) for a tokenId.
    function placeAsk(uint256 tokenId, uint256 price, uint40 expiry) external {
        if (price == 0) revert PriceZero();
        if (expiry < block.timestamp) revert Expired();
        address seller = msg.sender;
        if (gamepiece.ownerOf(tokenId) != seller) revert Unauthorized();
        burnie.burnFrom(seller, ASK_FEE);
        asks[tokenId] = Ask({seller: seller, expiry: expiry, price: price});
        emit AskPlaced(seller, tokenId, price, expiry);
    }

    /// @notice Cancel an active ask.
    function cancelAsk(uint256 tokenId) external {
        Ask storage ask = asks[tokenId];
        if (ask.seller != msg.sender) revert Unauthorized();
        delete asks[tokenId];
        emit AskCanceled(msg.sender, tokenId);
    }

    /// @notice Buy an active on-chain ask.
    /// @param tokenId Token being purchased.
    function buy(uint256 tokenId) external {
        Ask memory ask = asks[tokenId];
        if (ask.seller == address(0)) revert Unauthorized(); // Seller 0 means ask doesn't exist
        if (ask.price == 0) revert PriceZero();
        if (ask.expiry < block.timestamp) revert Expired();
        
        // Effects
        delete asks[tokenId];

        address buyer = msg.sender;
        address seller = ask.seller;
        
        // Interactions
        _collectPayment(buyer, seller, ask.price);
        gamepiece.transferFrom(seller, buyer, tokenId);

        emit AskFilled(buyer, seller, tokenId, ask.price);
    }

    /// @notice Place an on-chain offer for a tokenId; burns the flat posting fee.
    function placeOffer(uint256 tokenId, uint216 amount, uint40 expiry) external {
        if (amount == 0) revert PriceZero();
        if (expiry < block.timestamp) revert Expired();

        burnie.burnFrom(msg.sender, OFFER_FEE);
        offers[tokenId][msg.sender] = Offer({amount: amount, expiry: expiry});
        if (!offerSeen[tokenId][msg.sender]) {
            offerSeen[tokenId][msg.sender] = true;
            offerBidders[tokenId].push(msg.sender);
        }
        
        emit OfferPlaced(msg.sender, tokenId, amount, expiry);
    }

    /// @notice Cancel an active on-chain offer for a tokenId (no refund).
    function cancelOffer(uint256 tokenId) external {
        Offer storage offer = offers[tokenId][msg.sender];
        if (offer.amount == 0) revert Unauthorized(); // No active offer
        delete offers[tokenId][msg.sender];
        emit OfferCanceled(msg.sender, tokenId);
    }

    /// @notice Fill the highest active offer (funded + unexpired) for a token. Reverts if none.
    function acceptBestOffer(uint256 tokenId) external {
        address[] memory bidders = offerBidders[tokenId];
        uint256 len = bidders.length;
        BestOffer memory best;
        for (uint256 i = 0; i < len; i++) {
            address bidder = bidders[i];
            Offer memory offer = offers[tokenId][bidder];
            if (offer.amount == 0) continue;
            if (offer.expiry < block.timestamp) continue;
            if (burnie.balanceOf(bidder) < offer.amount) continue;
            if (offer.amount > best.amount) {
                best = BestOffer({bidder: bidder, amount: offer.amount, expiry: offer.expiry});
            }
        }
        if (best.bidder == address(0)) revert Unauthorized(); // no valid offers

        address seller = msg.sender;
        delete offers[tokenId][best.bidder];

        _collectPayment(best.bidder, seller, best.amount);
        gamepiece.transferFrom(seller, best.bidder, tokenId);

        emit OfferFilled(seller, best.bidder, tokenId, best.amount);
    }

    // ---------------------------------------------------------------------
    // Internals
    // ---------------------------------------------------------------------

    /// @notice Return the highest active offer (funded + unexpired) for a token, if any.
    function bestOffer(uint256 tokenId) external view returns (BestOffer memory best) {
        address[] memory bidders = offerBidders[tokenId];
        uint256 len = bidders.length;
        for (uint256 i = 0; i < len; i++) {
            address bidder = bidders[i];
            Offer memory offer = offers[tokenId][bidder];
            if (offer.amount == 0) continue;
            if (offer.expiry < block.timestamp) continue;
            if (burnie.balanceOf(bidder) < offer.amount) continue;
            if (offer.amount > best.amount) {
                best = BestOffer({bidder: bidder, amount: offer.amount, expiry: offer.expiry});
            }
        }
    }

    function _collectPayment(address payer, address seller, uint256 amount) private {
        uint256 burnCut = (amount * BURN_BPS) / BPS_DENOMINATOR;
        uint256 payout = amount - burnCut;
        if (burnCut != 0) {
            burnie.burnFrom(payer, burnCut);
        }
        if (!burnie.transferFrom(payer, seller, payout)) revert PaymentFailed();
    }
}
