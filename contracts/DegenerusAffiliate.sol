// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {IDegenerusGame} from "./interfaces/IDegenerusGame.sol";

interface IDegenerusCoinAffiliate {
    function creditFlip(address player, uint256 amount) external;
    function creditFlipBatch(address[3] calldata players, uint256[3] calldata amounts) external;
    function affiliateQuestReward(address player, uint256 amount) external returns (uint256);
    function affiliatePrimePresale() external;
}

interface IDegenerusGamepiecesAffiliate {
    function purchaseMapForAffiliate(address buyer, uint256 quantity) external;
}

contract DegenerusAffiliate {
    // ---------------------------------------------------------------------
    // Events
    // ---------------------------------------------------------------------
    event Affiliate(uint256 amount, bytes32 indexed code, address sender);

    // ---------------------------------------------------------------------
    // Errors
    // ---------------------------------------------------------------------
    error OnlyBonds();
    error OnlyAuthorized();
    error AlreadyConfigured();
    error Zero();
    error Insufficient();
    error InvalidRakeback();
    error ZeroAddress();

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
    uint256 private constant AFFILIATE_BONUS_MAX = 25;
    uint256 private constant AFFILIATE_BONUS_SCALE = AFFILIATE_BONUS_MAX * 5; // 20% of top earns max
    uint256 private constant PRICE_COIN_UNIT = 1_000_000_000;
    bytes32 private constant REF_CODE_LOCKED = bytes32(uint256(1));

    // ---------------------------------------------------------------------
    // Immutable / wiring
    // ---------------------------------------------------------------------
    address public immutable bonds;
    address public immutable bondsAdmin;

    IDegenerusCoinAffiliate private coin;
    IDegenerusGame private degenerusGame;
    IDegenerusGamepiecesAffiliate private degenerusGamepieces;

    // ---------------------------------------------------------------------
    // Affiliate state
    // ---------------------------------------------------------------------
    mapping(bytes32 => AffiliateCodeInfo) public affiliateCode;
    mapping(uint24 => mapping(address => uint256)) public affiliateCoinEarned;
    mapping(address => bytes32) private playerReferralCode;
    mapping(address => uint24) public referralJoinLevel; // level recorded when a referral code is set
    mapping(address => uint256) public presaleCoinEarned;
    mapping(uint24 => PlayerScore) private affiliateTopByLevel;
    uint256 public presaleClaimableTotal;
    bool private presaleShutdown; // permanently stops presale-era flows once manually closed
    bool private referralLocksActive;

    // ---------------------------------------------------------------------
    // Constructor
    // ---------------------------------------------------------------------
    constructor(address bonds_, address bondsAdmin_) {
        if (bonds_ == address(0) || bondsAdmin_ == address(0)) revert ZeroAddress();
        bonds = bonds_;
        bondsAdmin = bondsAdmin_;
    }

    // ---------------------------------------------------------------------
    // Wiring
    // ---------------------------------------------------------------------
    /// @notice Wire coin, game, and gamepieces via an address array ([coin, game, gamepieces]).
    /// @dev Each address can be set once; non-zero updates must match the existing value.
    function wire(address[] calldata addresses) external {
        address admin = bondsAdmin;
        if (msg.sender != bonds && msg.sender != admin) revert OnlyBonds();
        _setCoin(addresses.length > 0 ? addresses[0] : address(0));
        _setGame(addresses.length > 1 ? addresses[1] : address(0));
        _setGamepieces(addresses.length > 2 ? addresses[2] : address(0));
    }

    function _setCoin(address coinAddr) private {
        if (coinAddr == address(0)) {
            if (address(coin) == address(0)) revert ZeroAddress();
            return;
        }
        address current = address(coin);
        if (current == address(0)) {
            coin = IDegenerusCoinAffiliate(coinAddr);
            coin.affiliatePrimePresale();
        } else if (coinAddr != current) {
            revert AlreadyConfigured();
        }
    }

    function _setGame(address gameAddr) private {
        if (gameAddr == address(0)) return;
        address current = address(degenerusGame);
        if (current == address(0)) {
            degenerusGame = IDegenerusGame(gameAddr);
            referralLocksActive = true; // allow locking of referral codes only once the game is wired
        } else if (gameAddr != current) {
            revert AlreadyConfigured();
        }
    }

    function _setGamepieces(address gamepiecesAddr) private {
        if (gamepiecesAddr == address(0)) return;
        address current = address(degenerusGamepieces);
        if (current == address(0)) {
            degenerusGamepieces = IDegenerusGamepiecesAffiliate(gamepiecesAddr);
        } else if (gamepiecesAddr != current) {
            revert AlreadyConfigured();
        }
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
        address gameAddr = address(degenerusGame);
        if (gameAddr != address(0)) {
            _recordReferralJoinLevel(msg.sender, degenerusGame.level());
        }
        emit Affiliate(0, code_, msg.sender); // 0 = player referred
    }

    /// @notice Return the recorded referrer for `player` (zero address if none).
    function getReferrer(address player) external view returns (address) {
        return _referrerAddress(player);
    }

    /// @notice True while presale is open (can remain open after coin wiring).
    function presaleActive() external view returns (bool) {
        return !presaleShutdown;
    }

    /// @notice Allow the bonds contract to permanently close presale sales.
    function shutdownPresale() external {
        if (msg.sender != bonds) revert OnlyBonds();
        presaleShutdown = true;
    }

    // ---------------------------------------------------------------------
    // Gameplay entrypoints (coin only)
    // ---------------------------------------------------------------------
    /// @notice Credit affiliate rewards for a purchase (invoked by trusted gameplay contracts).
    /// @dev Core payout logic used by gameplay modules; callable only by the coin contract or bonds.
    function payAffiliate(
        uint256 amount,
        bytes32 code,
        address sender,
        uint24 lvl,
        uint8 gameState,
        bool rngLocked
    ) external returns (uint256 playerRakeback) {
        address caller = msg.sender;
        address coinAddr = address(coin);
        address gamepiecesAddr = address(degenerusGamepieces);
        if (caller != coinAddr && caller != bonds && caller != gamepiecesAddr) revert OnlyAuthorized();

        bool presaleOpen = !presaleShutdown;
        if (presaleOpen) {
            // During presale, only bond purchases should accrue presale-claimable coin.
            // This keeps presale coin distribution anchored to bond purchases (not other gameplay calls).
            if (caller != bonds) return 0;
        } else {
            // After presale closes, coin must be wired to distribute rewards.
            if (coinAddr == address(0)) return 0;
        }

        bytes32 storedCode = playerReferralCode[sender];
        if (storedCode == REF_CODE_LOCKED) return 0;

        AffiliateCodeInfo storage info;
        if (storedCode == bytes32(0)) {
            AffiliateCodeInfo storage candidate = affiliateCode[code];
            if (candidate.owner == address(0) || candidate.owner == sender) {
                if (referralLocksActive) {
                    playerReferralCode[sender] = REF_CODE_LOCKED;
                }
                return 0;
            }
            playerReferralCode[sender] = code;
            info = candidate;
            storedCode = code;
            _recordReferralJoinLevel(sender, lvl);
        } else {
            info = affiliateCode[storedCode];
            if (info.owner == address(0)) {
                playerReferralCode[sender] = referralLocksActive ? REF_CODE_LOCKED : bytes32(0);
                return 0;
            }
        }

        address affiliateAddr = info.owner;
        if (affiliateAddr == address(0) || affiliateAddr == sender) {
            playerReferralCode[sender] = referralLocksActive ? REF_CODE_LOCKED : bytes32(0);
            return 0;
        }
        uint8 rakebackPct = info.rakeback;

        mapping(address => uint256) storage earned = affiliateCoinEarned[lvl];
        uint256 rewardScaleBps = _referralRewardScaleBps(sender, lvl);
        uint256 scaledAmount = rewardScaleBps == 10_000 ? amount : (amount * rewardScaleBps) / 10_000;

        // Pay direct affiliate (score based on base amount).
        uint256 rakebackShare = (scaledAmount * uint256(rakebackPct)) / 100;
        uint256 affiliateShareBase = scaledAmount - rakebackShare;
        uint256 newTotal = earned[affiliateAddr] + affiliateShareBase; // score ignores stake bonus
        earned[affiliateAddr] = newTotal;

        _updateTopAffiliate(affiliateAddr, newTotal, lvl);
        playerRakeback = rakebackShare;

        if (!presaleOpen) {
            address[3] memory players;
            uint256[3] memory amounts;
            uint256 cursor;

            uint256 questReward = coin.affiliateQuestReward(affiliateAddr, affiliateShareBase);
            uint256 totalFlipAward = affiliateShareBase + questReward;
            if (gameState != 3 && !rngLocked) {
                IDegenerusGamepiecesAffiliate gp = degenerusGamepieces;
                if (address(gp) != address(0)) {
                    uint256 mapCost = PRICE_COIN_UNIT / 4;
                    if (totalFlipAward >= mapCost * 2) {
                        uint256 mapBudget = totalFlipAward / 2;
                        uint256 potentialMaps = mapBudget / mapCost;
                        uint32 mapQty = uint32(potentialMaps);
                        uint256 mapSpend = mapCost * uint256(mapQty);
                        totalFlipAward -= mapSpend;
                        gp.purchaseMapForAffiliate(affiliateAddr, mapQty);
                    }
                }
            }
            players[cursor] = affiliateAddr;
            amounts[cursor] = totalFlipAward;
            unchecked {
                ++cursor;
            }

            // Upline bonus (20% of base amount); no stake bonus applied to uplines.
            address upline = _referrerAddress(affiliateAddr);
            if (upline != address(0) && upline != sender) {
                uint256 baseBonus = scaledAmount / 5;
                uint256 questRewardUpline = coin.affiliateQuestReward(upline, baseBonus);
                uint256 totalUpline = baseBonus + questRewardUpline;
                earned[upline] = earned[upline] + baseBonus;

                players[cursor] = upline;
                amounts[cursor] = totalUpline;
                unchecked {
                    ++cursor;
                }

                // Second upline bonus (20% of first upline share)
                address upline2 = _referrerAddress(upline);
                if (upline2 != address(0)) {
                    uint256 bonus2 = baseBonus / 5;
                    uint256 questReward2 = coin.affiliateQuestReward(upline2, bonus2);
                    uint256 totalUpline2 = bonus2 + questReward2;
                    earned[upline2] = earned[upline2] + bonus2;

                    players[cursor] = upline2;
                    amounts[cursor] = totalUpline2;
                    unchecked {
                        ++cursor;
                    }
                }
            }

            if (cursor != 0) {
                if (cursor == 1) {
                    coin.creditFlip(players[0], amounts[0]);
                } else {
                    coin.creditFlipBatch(players, amounts);
                }
            }
        } else {
            uint256 presaleTotalIncrease = affiliateShareBase;
            presaleCoinEarned[affiliateAddr] += affiliateShareBase;

            // Upline bonus (20% of base amount); no stake bonus applied to uplines.
            address uplinePre = _referrerAddress(affiliateAddr);
            if (uplinePre != address(0) && uplinePre != sender) {
                uint256 baseBonusPre = scaledAmount / 5;
                earned[uplinePre] = earned[uplinePre] + baseBonusPre;
                presaleCoinEarned[uplinePre] += baseBonusPre;
                presaleTotalIncrease += baseBonusPre;

                // Second upline bonus (20% of first upline share)
                address upline2Pre = _referrerAddress(uplinePre);
                if (upline2Pre != address(0)) {
                    uint256 bonus2Pre = baseBonusPre / 5;
                    earned[upline2Pre] = earned[upline2Pre] + bonus2Pre;
                    presaleCoinEarned[upline2Pre] += bonus2Pre;
                    presaleTotalIncrease += bonus2Pre;
                }
            }

            if (playerRakeback != 0) {
                presaleCoinEarned[sender] += playerRakeback;
                presaleTotalIncrease += playerRakeback;
            }

            if (presaleTotalIncrease != 0) {
                presaleClaimableTotal += presaleTotalIncrease;
            }
        }

        emit Affiliate(amount, storedCode, sender);
        return playerRakeback;
    }

    /// @notice Consume and return the caller’s accrued presale/early affiliate coin for minting.
    /// @dev Access: coin only.
    function consumePresaleCoin(address player) external returns (uint256 amount) {
        if (msg.sender != address(coin)) revert OnlyAuthorized();
        if (!presaleShutdown) return 0;
        amount = presaleCoinEarned[player];
        if (amount != 0) {
            presaleCoinEarned[player] = 0;
            if (amount <= presaleClaimableTotal) {
                presaleClaimableTotal -= amount;
            } else {
                presaleClaimableTotal = 0;
            }
        }
    }

    /// @notice Credit presale coin from external sources; callable by coin/bonds/bonds admin.
    function addPresaleCoinCredit(address player, uint256 amount) external {
        address caller = msg.sender;
        if (caller != address(coin) && caller != bonds && caller != bondsAdmin) revert OnlyAuthorized();
        if (player == address(0) || amount == 0) return;
        presaleCoinEarned[player] += amount;
        presaleClaimableTotal += amount;
    }

    /// @notice Reject unsolicited ETH by immediately forwarding to the bonds contract.
    receive() external payable {
        (bool ok, ) = payable(bonds).call{value: msg.value}("");
        if (!ok) revert Insufficient();
    }

    // ---------------------------------------------------------------------
    // Views
    // ---------------------------------------------------------------------
    /// @notice Return the recorded top affiliate for a given level.
    function affiliateTop(uint24 lvl) public view returns (address player, uint96 score) {
        PlayerScore memory stored = affiliateTopByLevel[lvl];
        return (stored.player, stored.score);
    }

    /// @notice Return the top score and the player's score (whole tokens) for a level.
    function affiliateBonusInfo(uint24 lvl, address player) external view returns (uint96 topScore, uint256 playerScore) {
        topScore = affiliateTopByLevel[lvl].score;
        if (topScore == 0 || player == address(0)) return (topScore, 0);
        uint256 earned = affiliateCoinEarned[lvl][player];
        if (earned == 0) return (topScore, 0);
        playerScore = earned / MILLION;
    }

    /// @notice Return the best affiliate bonus points from currLevel-1 or currLevel-2.
    function affiliateBonusPointsBest(uint24 currLevel, address player) external view returns (uint256 points) {
        if (player == address(0) || currLevel == 0) return 0;
        unchecked {
            uint24 prevLevel = currLevel - 1;
            uint256 best = _affiliateBonusPointsAt(prevLevel, player);
            if (best == AFFILIATE_BONUS_MAX || currLevel == 1) return best;
            uint256 alt = _affiliateBonusPointsAt(prevLevel - 1, player);
            return alt > best ? alt : best;
        }
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

    /// @notice Return the caller's stored referral code if valid (zero otherwise).
    function referralCodeOf(address player) external view returns (bytes32 code) {
        return _referralCode(player);
    }

    function _referrerAddress(address player) private view returns (address) {
        bytes32 code = _referralCode(player);
        if (code == bytes32(0)) return address(0);
        return affiliateCode[code].owner;
    }

    function _recordReferralJoinLevel(address player, uint24 lvl) private {
        if (player == address(0) || lvl == 0) return;
        if (referralJoinLevel[player] == 0) {
            referralJoinLevel[player] = lvl;
        }
    }

    function _referralRewardScaleBps(address player, uint24 currentLevel) private view returns (uint256 scaleBps) {
        uint24 joinLevel = referralJoinLevel[player];
        if (joinLevel == 0 || currentLevel <= joinLevel) return 10_000;

        uint256 delta = uint256(currentLevel - joinLevel);
        if (delta <= 50) return 10_000;
        if (delta >= 150) return 2_500;

        uint256 decayLevels = delta - 50; // 0 -> start of decay window
        uint256 reduction = decayLevels * 75; // 0.75% per level (100% → 25% over 100 levels)
        scaleBps = 10_000 - reduction;
        if (scaleBps < 2_500) {
            scaleBps = 2_500;
        }
    }

    function _score96(uint256 s) private pure returns (uint96) {
        uint256 wholeTokens = s / MILLION;
        if (wholeTokens > type(uint96).max) {
            wholeTokens = type(uint96).max;
        }
        return uint96(wholeTokens);
    }

    function _affiliateBonusPointsAt(uint24 lvl, address player) private view returns (uint256 points) {
        uint96 topScore = affiliateTopByLevel[lvl].score;
        if (topScore == 0) return 0;
        uint256 earned = affiliateCoinEarned[lvl][player];
        if (earned == 0) return 0;
        uint256 playerScore = earned / MILLION;
        if (playerScore == 0) return 0;
        unchecked {
            uint256 scaled = (playerScore * AFFILIATE_BONUS_SCALE) / uint256(topScore);
            return scaled > AFFILIATE_BONUS_MAX ? AFFILIATE_BONUS_MAX : scaled;
        }
    }

    function _updateTopAffiliate(address player, uint256 total, uint24 lvl) private {
        uint96 score = _score96(total);
        PlayerScore memory current = affiliateTopByLevel[lvl];
        if (score > current.score) {
            affiliateTopByLevel[lvl] = PlayerScore({player: player, score: score});
        }
    }
}
