// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {IPurgeGame} from "./interfaces/IPurgeGame.sol";
import {IPurgeGameTrophies} from "./PurgeGameTrophies.sol";

interface IPurgeCoinAffiliate {
    function balanceOf(address account) external view returns (uint256);
    function presaleDistribute(address buyer, uint256 amountBase) external;
    function affiliateAddFlip(address player, uint256 amount) external;
    function affiliateAddFlipBatch(address[3] calldata players, uint256[3] calldata amounts) external;
    function affiliateQuestReward(address player, uint256 amount) external returns (uint256);
}

contract PurgeAffiliate {
    // ---------------------------------------------------------------------
    // Events
    // ---------------------------------------------------------------------
    event Affiliate(uint256 amount, bytes32 indexed code, address sender);

    // ---------------------------------------------------------------------
    // Errors
    // ---------------------------------------------------------------------
    error OnlyCreator();
    error OnlyAuthorized();
    error Zero();
    error Insufficient();
    error InvalidRakeback();
    error ZeroAddress();
    error PresaleExceedsRemaining();
    error PresalePerTxLimit();

    // ---------------------------------------------------------------------
    // Types
    // ---------------------------------------------------------------------
    struct PlayerScore {
        address player;
        uint96 score;
    }

    struct AffiliateCodeInfo {
        address owner;
        uint8 rakeback;
    }

    // ---------------------------------------------------------------------
    // Constants
    // ---------------------------------------------------------------------
    uint256 private constant MILLION = 1e6; // token has 6 decimals
    bytes32 private constant REF_CODE_LOCKED = bytes32(uint256(1));
    uint256 private constant PRESALE_SUPPLY_TOKENS = 4_000_000;
    uint256 private constant PRESALE_START_PRICE = 0.000012 ether;
    uint256 private constant PRESALE_END_PRICE = 0.000018 ether;
    uint256 private constant PRESALE_PRICE_SLOPE = (PRESALE_END_PRICE - PRESALE_START_PRICE) / PRESALE_SUPPLY_TOKENS;
    uint256 private constant PRESALE_MAX_ETH_PER_TX = 0.25 ether;

    // ---------------------------------------------------------------------
    // Immutable / wiring
    // ---------------------------------------------------------------------
    address private immutable creator;

    IPurgeCoinAffiliate private coin;
    IPurgeGame private purgeGame;
    IPurgeGameTrophies private trophies;
    address public payer;

    // ---------------------------------------------------------------------
    // Affiliate state
    // ---------------------------------------------------------------------
    mapping(bytes32 => AffiliateCodeInfo) public affiliateCode;
    mapping(uint24 => mapping(address => uint256)) public affiliateCoinEarned;
    mapping(address => bytes32) private playerReferralCode;
    mapping(address => uint256) public presaleCoinEarned;
    uint96 public totalPresaleSold;
    mapping(uint24 => PlayerScore) private affiliateTopByLevel;

    // ---------------------------------------------------------------------
    // Constructor
    // ---------------------------------------------------------------------
    constructor(address creator_) {
        if (creator_ == address(0)) revert ZeroAddress();
        creator = creator_;
    }

    // ---------------------------------------------------------------------
    // Wiring
    // ---------------------------------------------------------------------
    function wire(address coin_, address game_, address trophies_) external {
        address coinAddr = address(coin);
        if (coinAddr == address(0)) {
            if (coin_ == address(0)) revert ZeroAddress();
            if (msg.sender != creator && msg.sender != coin_) revert OnlyCreator();
            coin = IPurgeCoinAffiliate(coin_);
            coinAddr = coin_;
        } else {
            if (msg.sender != creator && msg.sender != coinAddr) revert OnlyCreator();
            if (coin_ != address(0) && coin_ != coinAddr) revert OnlyCreator();
        }

        if (game_ != address(0)) {
            purgeGame = IPurgeGame(game_);
        }
        if (trophies_ != address(0)) {
            trophies = IPurgeGameTrophies(trophies_);
        }
    }

    /// @notice Set the contract permitted to invoke `payAffiliate` directly (alongside the coin).
    function setPayer(address payer_) external {
        address coinAddr = address(coin);
        if (msg.sender != creator && msg.sender != coinAddr) revert OnlyAuthorized();
        if (payer_ == address(0)) revert ZeroAddress();
        payer = payer_;
    }

    // ---------------------------------------------------------------------
    // External player entrypoints
    // ---------------------------------------------------------------------
    /// @notice Create a new affiliate code mapping to the caller.
    /// @dev Reverts if `code_` is zero, reserved, or already taken.
    function createAffiliateCode(bytes32 code_, uint8 rakebackPct) external {
        if (code_ == bytes32(0) || code_ == REF_CODE_LOCKED) revert Zero();
        if (rakebackPct > 25) revert InvalidRakeback();
        AffiliateCodeInfo storage info = affiliateCode[code_];
        if (info.owner != address(0)) revert Insufficient();
        affiliateCode[code_] = AffiliateCodeInfo({owner: msg.sender, rakeback: rakebackPct});
        emit Affiliate(1, code_, msg.sender); // 1 = code created
    }

    /// @notice Set the caller's referrer once using a valid affiliate code.
    /// @dev Reverts if code is unknown, self-referral, or caller already has a referrer.
    function referPlayer(bytes32 code_) external {
        AffiliateCodeInfo storage info = affiliateCode[code_];
        address referrer = info.owner;
        if (referrer == address(0) || referrer == msg.sender) revert Insufficient();
        bytes32 existing = playerReferralCode[msg.sender];
        if (existing != bytes32(0)) revert Insufficient();
        playerReferralCode[msg.sender] = code_;
        emit Affiliate(0, code_, msg.sender); // 0 = player referred
    }

    /// @notice Return the recorded referrer for `player` (zero address if none).
    function getReferrer(address player) external view returns (address) {
        return _referrerAddress(player);
    }

    /// @notice Presale purchase flow (ETH -> PURGE) with linear price ramp and deferred bonuses.
    function presale() external payable returns (uint256 amountBase) {
        address coinAddr = address(coin);
        if (coinAddr == address(0)) revert ZeroAddress();
        uint256 ethIn = msg.value;
        if (ethIn < 0.001 ether) revert Insufficient();
        if (ethIn > PRESALE_MAX_ETH_PER_TX) revert PresalePerTxLimit();

        uint256 inventoryTokens = coin.balanceOf(coinAddr) / MILLION;
        if (inventoryTokens == 0) revert PresaleExceedsRemaining();

        uint256 tokensSold = PRESALE_SUPPLY_TOKENS - inventoryTokens;
        uint256 price = PRESALE_START_PRICE + PRESALE_PRICE_SLOPE * tokensSold;
        if (price > PRESALE_END_PRICE) price = PRESALE_END_PRICE;
        if (price == 0 || price > ethIn) revert Insufficient();

        uint256 tokensOut = ethIn / price;
        if (tokensOut == 0) revert Insufficient();
        if (tokensOut > inventoryTokens) {
            tokensOut = inventoryTokens;
        }

        uint256 costWei = tokensOut * price;
        uint256 refund = ethIn - costWei;

        amountBase = tokensOut * MILLION;
        totalPresaleSold = uint96(uint256(totalPresaleSold) + amountBase);

        address payable buyer = payable(msg.sender);
        coin.presaleDistribute(buyer, amountBase);

        address gameAddr = address(purgeGame);
        uint256 gameCut;
        if (gameAddr != address(0)) {
            gameCut = (costWei * 80) / 100;
            (bool gameOk, ) = gameAddr.call{value: gameCut}("");
            if (!gameOk) revert Insufficient();
        }

        if (refund != 0) {
            (bool refundOk, ) = buyer.call{value: refund}("");
            if (!refundOk) revert Insufficient();
        }

        uint256 creatorCut = costWei - gameCut;
        (bool ok, ) = payable(creator).call{value: creatorCut}("");
        if (!ok) revert Insufficient();

        address affiliateAddr = _referrerAddress(buyer);
        if (affiliateAddr != address(0) && affiliateAddr != buyer) {
            uint256 affiliateBonus = (amountBase * 5) / 100;
            uint256 buyerBonus = (amountBase * 2) / 100;
            if (affiliateBonus != 0) {
                presaleCoinEarned[affiliateAddr] += affiliateBonus;
            }
            if (buyerBonus != 0) {
                presaleCoinEarned[buyer] += buyerBonus;
            }
        }
    }

    // ---------------------------------------------------------------------
    // Gameplay entrypoints (coin only)
    // ---------------------------------------------------------------------
    /// @notice Credit affiliate rewards for a purchase (invoked by trusted gameplay contracts).
    /// @dev Core payout logic used by gameplay modules; callable only by the coin contract or the configured payer.
    function payAffiliate(
        uint256 amount,
        bytes32 code,
        address sender,
        uint24 lvl
    ) external returns (uint256 playerRakeback) {
        address caller = msg.sender;
        address coinAddr = address(coin);
        if (caller != coinAddr && caller != payer) revert OnlyAuthorized();

        bool coinActive = coinAddr != address(0);
        bytes32 storedCode = playerReferralCode[sender];
        if (storedCode == REF_CODE_LOCKED) return 0;

        AffiliateCodeInfo storage info;
        if (storedCode == bytes32(0)) {
            AffiliateCodeInfo storage candidate = affiliateCode[code];
            if (candidate.owner == address(0) || candidate.owner == sender) {
                playerReferralCode[sender] = REF_CODE_LOCKED;
                return 0;
            }
            playerReferralCode[sender] = code;
            info = candidate;
            storedCode = code;
        } else {
            info = affiliateCode[storedCode];
            if (info.owner == address(0)) {
                playerReferralCode[sender] = REF_CODE_LOCKED;
                return 0;
            }
        }

        address affiliateAddr = info.owner;
        if (affiliateAddr == address(0) || affiliateAddr == sender) {
            playerReferralCode[sender] = REF_CODE_LOCKED;
            return 0;
        }
        uint8 rakebackPct = info.rakeback;

        uint256 baseAmount = amount;

        mapping(address => uint256) storage earned = affiliateCoinEarned[lvl];
        IPurgeGameTrophies trophies_ = trophies;

        address[3] memory players;
        uint256[3] memory amounts;
        uint256 cursor;

        // Pay direct affiliate
        uint256 payout = baseAmount;
        uint8 stakeBonus = address(trophies_) != address(0) ? trophies_.affiliateStakeBonus(affiliateAddr) : 0;
        if (stakeBonus != 0) {
            payout += (payout * stakeBonus) / 100;
        }

        uint256 rakebackShare = (payout * uint256(rakebackPct)) / 100;
        uint256 affiliateShare = payout - rakebackShare;

        uint256 newTotal = earned[affiliateAddr] + affiliateShare;
        earned[affiliateAddr] = newTotal;

        uint256 questReward = coinActive ? coin.affiliateQuestReward(affiliateAddr, affiliateShare) : 0;

        uint256 totalFlipAward = affiliateShare + questReward;
        if (totalFlipAward != 0 && coinActive) {
            players[cursor] = affiliateAddr;
            amounts[cursor] = totalFlipAward;
            unchecked {
                ++cursor;
            }
        } else if (totalFlipAward != 0) {
            presaleCoinEarned[affiliateAddr] += totalFlipAward;
        }

        _updateTopAffiliate(affiliateAddr, newTotal, lvl);

        playerRakeback = rakebackShare;

        // Upline bonus (20%)
        address upline = _referrerAddress(affiliateAddr);
        if (upline != address(0) && upline != sender) {
            uint256 bonus = baseAmount / 5;
            uint8 stakeBonusUpline = address(trophies_) != address(0) ? trophies_.affiliateStakeBonus(upline) : 0;
            if (stakeBonusUpline != 0) {
                bonus += (bonus * stakeBonusUpline) / 100;
            }
            uint256 questRewardUpline = coinActive ? coin.affiliateQuestReward(upline, bonus) : 0;
            uint256 uplineTotal = earned[upline] + bonus;
            earned[upline] = uplineTotal;
            uint256 totalUpline = bonus + questRewardUpline;
            if (totalUpline != 0) {
                if (coinActive && cursor < 3) {
                    players[cursor] = upline;
                    amounts[cursor] = totalUpline;
                    unchecked {
                        ++cursor;
                    }
                } else if (!coinActive) {
                    presaleCoinEarned[upline] += totalUpline;
                }
            }

            // Second upline bonus (20%)
            address upline2 = _referrerAddress(upline);
            if (upline2 != address(0)) {
                uint256 bonus2 = bonus / 5;
                uint8 stakeBonusUpline2 = address(trophies_) != address(0) ? trophies_.affiliateStakeBonus(upline2) : 0;
                if (stakeBonusUpline2 != 0) {
                    bonus2 += (bonus2 * stakeBonusUpline2) / 100;
                }
                uint256 questReward2 = coinActive ? coin.affiliateQuestReward(upline2, bonus2) : 0;
                uint256 upline2Total = earned[upline2] + bonus2;
                earned[upline2] = upline2Total;
                uint256 totalUpline2 = bonus2 + questReward2;
                if (totalUpline2 != 0) {
                    if (coinActive && cursor < 3) {
                        players[cursor] = upline2;
                        amounts[cursor] = totalUpline2;
                    } else if (!coinActive) {
                        presaleCoinEarned[upline2] += totalUpline2;
                    }
                }
            }
        }

        if (players[0] != address(0) || players[1] != address(0) || players[2] != address(0)) {
            coin.affiliateAddFlipBatch(players, amounts);
        } else if (!coinActive && playerRakeback != 0) {
            presaleCoinEarned[sender] += playerRakeback;
        }

        emit Affiliate(amount, storedCode, sender);
        return playerRakeback;
    }

    /// @notice Consume and return the caller’s accrued presale/early affiliate coin for minting.
    /// @dev Access: coin only.
    function consumePresaleCoin(address player) external returns (uint256 amount) {
        if (msg.sender != address(coin)) revert OnlyAuthorized();
        amount = presaleCoinEarned[player];
        if (amount != 0) {
            presaleCoinEarned[player] = 0;
        }
    }

    // ---------------------------------------------------------------------
    // Views
    // ---------------------------------------------------------------------
    function getTopAffiliate(uint24 lvl) external view returns (address) {
        (address player, ) = affiliateTop(lvl);
        return player;
    }

    /// @notice Return the recorded top affiliate for a given level.
    function affiliateTop(uint24 lvl) public view returns (address player, uint96 score) {
        PlayerScore memory stored = affiliateTopByLevel[lvl];
        return (stored.player, stored.score);
    }

    // ---------------------------------------------------------------------
    // Internal helpers
    // ---------------------------------------------------------------------
    function _referralCode(address player) private view returns (bytes32 code) {
        code = playerReferralCode[player];
        if (code == bytes32(0) || code == REF_CODE_LOCKED) return bytes32(0);
        if (affiliateCode[code].owner == address(0)) return bytes32(0);
        return code;
    }

    function _referrerAddress(address player) private view returns (address) {
        bytes32 code = _referralCode(player);
        if (code == bytes32(0)) return address(0);
        return affiliateCode[code].owner;
    }

    function _score96(uint256 s) private pure returns (uint96) {
        uint256 wholeTokens = s / MILLION;
        if (wholeTokens > type(uint96).max) {
            wholeTokens = type(uint96).max;
        }
        return uint96(wholeTokens);
    }

    function _updateTopAffiliate(address player, uint256 total, uint24 lvl) private {
        uint96 score = _score96(total);
        PlayerScore memory current = affiliateTopByLevel[lvl];
        if (score > current.score) {
            affiliateTopByLevel[lvl] = PlayerScore({player: player, score: score});
        }
    }

}
