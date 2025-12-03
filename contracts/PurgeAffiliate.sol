// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {IPurgeGame} from "./interfaces/IPurgeGame.sol";
import {IPurgeGameTrophies} from "./PurgeGameTrophies.sol";

interface IPurgeCoinAffiliate {
    function balanceOf(address account) external view returns (uint256);
    function presaleDistribute(address buyer, uint256 amountBase) external;
    function creditFlip(address player, uint256 amount) external;
    function creditFlipBatch(address[3] calldata players, uint256[3] calldata amounts) external;
    function affiliateQuestReward(address player, uint256 amount) external returns (uint256);
    function affiliatePrimePresale() external;
}

interface IPurgeBondsPresale {
    function ingestPresaleEth() external payable;
}

interface IPurgeBondsAffiliateMint {
    function mintAffiliateReward(
        address to,
        uint256 quantity,
        uint256 basePerBondWei,
        bool stake
    ) external returns (uint256 startTokenId);
}

contract PurgeAffiliate {
    // ---------------------------------------------------------------------
    // Events
    // ---------------------------------------------------------------------
    event Affiliate(uint256 amount, bytes32 indexed code, address sender);
    event AffiliateBondClaimed(address indexed player, uint24 indexed lvl, uint8 indexed tier, uint8 bondsMinted);
    event AffiliateBondRewardsUpdated(uint256 count);
    event SyntheticMapPlayerCreated(address indexed synthetic, address indexed affiliate, bytes32 code);

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
    error PresaleExceedsRemaining();
    error PresalePerTxLimit();
    error PresaleClosed();
    error ClaimTierInvalid();
    error ClaimAlreadyClaimed();
    error ClaimScoreTooLow();
    error ClaimConfigTooLarge();
    error InvalidClaimConfig();

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

    struct AffiliateBondReward {
        uint96 scoreRequired; // affiliate score needed (base units, 6 decimals)
        uint96 baseWeiPerBond; // base value per bond for win odds (>= min base, capped to 0.5 ETH when minting)
        uint8 bonds; // number of bonds minted for this tier
        bool stake; // whether the reward bonds are staked (soulbound)
    }

    // ---------------------------------------------------------------------
    // Constants
    // ---------------------------------------------------------------------
    uint256 private constant MILLION = 1e6; // token has 6 decimals
    bytes32 private constant REF_CODE_LOCKED = bytes32(uint256(1));
    uint256 private constant PRESALE_SUPPLY_TOKENS = 10_000_000;
    uint256 private constant PRESALE_DECAY_CUTOFF_TOKENS = 3_000_000;
    uint256 private constant PRESALE_PRICE_START_1000 = 0.01 ether; // price per 1,000 tokens
    uint256 private constant PRESALE_PRICE_INC_PER_ETH_1000 = 0.0005 ether; // bump per 1 ETH sold (per 1,000 tokens)
    uint256 private constant PRESALE_PRICE_DECAY_1000 = 0.0005 ether; // daily decay (per 1,000 tokens)
    uint256 private constant PRESALE_PRICE_DIVISOR = 1000; // pricePer1000 / 1000 = price per token
    uint256 private constant PRESALE_PRICE_FLOOR_1000 = 0.0075 ether; // minimum price per 1,000 tokens
    uint256 private constant PRESALE_MAX_ETH_PER_TX = 1 ether;
    uint256 private constant AFFILIATE_BOND_MIN_BASE = 0.02 ether;
    uint256 private constant AFFILIATE_BOND_MAX_BASE = 0.5 ether;
    uint256 private constant AFFILIATE_BOND_MAX_TIERS = 256;

    // ---------------------------------------------------------------------
    // Immutable / wiring
    // ---------------------------------------------------------------------
    address public immutable bonds;

    IPurgeCoinAffiliate private coin;
    IPurgeGame private purgeGame;
    IPurgeGameTrophies private trophies;

    // ---------------------------------------------------------------------
    // Affiliate state
    // ---------------------------------------------------------------------
    mapping(bytes32 => AffiliateCodeInfo) public affiliateCode;
    mapping(uint24 => mapping(address => uint256)) public affiliateCoinEarned;
    mapping(address => bytes32) private playerReferralCode;
    mapping(address => address) public syntheticMapOwner; // synthetic player -> affiliate owner
    mapping(address => bytes32) private syntheticMapCode; // synthetic player -> locked affiliate code
    mapping(address => uint256) public presaleCoinEarned;
    uint256 public presaleClaimableTotal;
    mapping(address => uint256) public presalePrincipal; // principal bought while coin is unwired
    uint96 public totalPresaleSold;
    mapping(uint24 => PlayerScore) private affiliateTopByLevel;
    uint256 private presaleInventoryBase = PRESALE_SUPPLY_TOKENS * MILLION; // used before coin is wired
    bool private preCoinActive = true;
    uint256 private rewardSeedEth; // legacy accumulator (unused while presale forwards directly to bonds)
    bool private presaleShutdown; // permanently stops new presale purchases once coin is wired
    uint256 private presalePricePer1000 = PRESALE_PRICE_START_1000;
    uint48 private presaleLastDay;
    bool private presaleIncreasedToday;
    bool private referralLocksActive;
    AffiliateBondReward[] private affiliateBondRewards;
    mapping(uint24 => mapping(address => uint256)) public affiliateBondClaimed; // bitmask of claimed tiers per level

    function _applyPresaleDecay() private returns (uint256 pricePer1000) {
        uint48 day = uint48(block.timestamp / 1 days);
        uint48 last = presaleLastDay;
        // Stop decay entirely after the cutoff supply is sold.
        if (uint256(totalPresaleSold) / MILLION >= PRESALE_DECAY_CUTOFF_TOKENS) {
            presaleLastDay = day;
            presaleIncreasedToday = false;
            return presalePricePer1000;
        }
        if (last == 0) {
            presaleLastDay = day;
            return presalePricePer1000;
        }
        if (day > last) {
            uint256 daysElapsed = uint256(day) - uint256(last);
            if (presaleIncreasedToday && daysElapsed != 0) {
                unchecked {
                    --daysElapsed; // skip one day of decay if price increased last day
                }
            }
            if (daysElapsed != 0) {
                uint256 decay = daysElapsed * PRESALE_PRICE_DECAY_1000;
                uint256 p = presalePricePer1000;
                if (decay >= p || p - decay < PRESALE_PRICE_FLOOR_1000) {
                    presalePricePer1000 = PRESALE_PRICE_FLOOR_1000;
                } else {
                    presalePricePer1000 = p - decay;
                }
            }
            presaleLastDay = day;
            presaleIncreasedToday = false;
        }
        return presalePricePer1000;
    }

    function _bumpPresalePrice(uint256 ethPaid) private {
        if (ethPaid == 0) return;
        uint256 bump = (ethPaid * PRESALE_PRICE_INC_PER_ETH_1000) / 1 ether;
        if (bump == 0) return;
        presalePricePer1000 += bump;
        presaleIncreasedToday = true;
    }

    // ---------------------------------------------------------------------
    // Constructor
    // ---------------------------------------------------------------------
    constructor(address bonds_) {
        if (bonds_ == address(0)) revert ZeroAddress();
        bonds = bonds_;
    }

    // ---------------------------------------------------------------------
    // Wiring
    // ---------------------------------------------------------------------
    /// @notice Wire coin, game, and trophies via an address array ([coin, game, trophies]).
    /// @dev Each address can be set once; non-zero updates must match the existing value.
    function wire(address[] calldata addresses) external {
        if (msg.sender != bonds) revert OnlyBonds();
        _setCoin(addresses.length > 0 ? addresses[0] : address(0));
        _setGame(addresses.length > 1 ? addresses[1] : address(0));
        _setTrophies(addresses.length > 2 ? addresses[2] : address(0));
    }

    function _setCoin(address coinAddr) private {
        if (coinAddr == address(0)) {
            if (address(coin) == address(0)) revert ZeroAddress();
            return;
        }
        address current = address(coin);
        if (current == address(0)) {
            coin = IPurgeCoinAffiliate(coinAddr);
            presaleShutdown = true; // stop presale once coin is wired
            preCoinActive = false;
            coin.affiliatePrimePresale();
        } else if (coinAddr != current) {
            revert AlreadyConfigured();
        }
    }

    function _setGame(address gameAddr) private {
        if (gameAddr == address(0)) return;
        address current = address(purgeGame);
        if (current == address(0)) {
            purgeGame = IPurgeGame(gameAddr);
            uint256 seed = rewardSeedEth;
            if (seed != 0) {
                rewardSeedEth = 0;
                (bool ok, ) = payable(gameAddr).call{value: seed}("");
                if (!ok) revert Insufficient();
            }
            referralLocksActive = true; // allow locking of referral codes only once the game is wired
        } else if (gameAddr != current) {
            revert AlreadyConfigured();
        }
    }

    function _setTrophies(address trophiesAddr) private {
        if (trophiesAddr == address(0)) return;
        address current = address(trophies);
        if (current == address(0)) {
            trophies = IPurgeGameTrophies(trophiesAddr);
        } else if (trophiesAddr != current) {
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
        emit Affiliate(0, code_, msg.sender); // 0 = player referred
    }

    /// @notice Create a synthetic MAP-only player controlled by the caller (affiliate).
    /// @dev Locks referral code to caller-owned `code_` and tags the synthetic address as map-only.
    function createSyntheticMapPlayer(address synthetic, bytes32 code_) external {
        if (synthetic == address(0)) revert ZeroAddress();
        AffiliateCodeInfo storage info = affiliateCode[code_];
        if (info.owner != msg.sender) revert OnlyAuthorized();
        if (syntheticMapOwner[synthetic] != address(0)) revert Insufficient();
        if (playerReferralCode[synthetic] != bytes32(0)) revert Insufficient();
        syntheticMapOwner[synthetic] = msg.sender;
        syntheticMapCode[synthetic] = code_;
        playerReferralCode[synthetic] = code_;
        emit SyntheticMapPlayerCreated(synthetic, msg.sender, code_);
    }

    /// @notice Return the recorded referrer for `player` (zero address if none).
    function getReferrer(address player) external view returns (address) {
        return _referrerAddress(player);
    }

    /// @notice Allow the bonds contract to permanently close presale sales.
    function shutdownPresale() external {
        if (msg.sender != bonds) revert OnlyBonds();
        presaleShutdown = true;
    }

    /// @notice Withdraw admin funds (excludes prize-pool-reserved ETH).
    function withdrawAdmin(address payable to, uint256 amount) external {
        if (msg.sender != bonds) revert OnlyBonds();
        if (to == address(0)) revert Zero();
        uint256 reserved = rewardSeedEth;
        uint256 bal = address(this).balance;
        uint256 available = bal > reserved ? bal - reserved : 0;
        if (amount == 0) amount = available;
        if (amount == 0 || amount > available) revert Insufficient();
        (bool ok, ) = to.call{value: amount}("");
        if (!ok) revert Insufficient();
    }

    /// @notice Presale purchase flow (ETH -> PURGE) with linear price ramp and deferred bonuses.
    function presale() external payable returns (uint256 amountBase) {
        if (presaleShutdown) revert PresaleClosed();
        uint256 ethIn = msg.value;
        if (ethIn < 0.001 ether) revert Insufficient();
        if (ethIn > PRESALE_MAX_ETH_PER_TX) revert PresalePerTxLimit();

        if (!preCoinActive) revert PresaleExceedsRemaining();
        uint256 pricePer1000 = _applyPresaleDecay();
        uint256 inventoryTokens = presaleInventoryBase / MILLION;
        if (inventoryTokens == 0) revert PresaleExceedsRemaining();

        // price per token = pricePer1000 / 1000
        uint256 tokensOut = (ethIn * PRESALE_PRICE_DIVISOR) / pricePer1000;
        if (tokensOut == 0) revert Insufficient();
        if (tokensOut > inventoryTokens) {
            tokensOut = inventoryTokens;
        }

        uint256 costWei = (tokensOut * pricePer1000) / PRESALE_PRICE_DIVISOR;
        uint256 refund = ethIn - costWei;

        amountBase = tokensOut * MILLION;
        totalPresaleSold = uint96(uint256(totalPresaleSold) + amountBase);
        presaleClaimableTotal += amountBase;

        address payable buyer = payable(msg.sender);
        presaleInventoryBase -= amountBase;
        presalePrincipal[buyer] += amountBase;
        presaleCoinEarned[buyer] += amountBase;

        IPurgeBondsPresale(bonds).ingestPresaleEth{value: costWei}(); // bonds routes 90% to prize pool

        if (refund != 0) {
            (bool refundOk, ) = buyer.call{value: refund}("");
            if (!refundOk) revert Insufficient();
        }

        _bumpPresalePrice(costWei);

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
    /// @dev Core payout logic used by gameplay modules; callable only by the coin contract or bonds.
    function payAffiliate(
        uint256 amount,
        bytes32 code,
        address sender,
        uint24 lvl
    ) external returns (uint256 playerRakeback) {
        address caller = msg.sender;
        address coinAddr = address(coin);
        if (caller != coinAddr && caller != bonds) revert OnlyAuthorized();

        bool coinActive = coinAddr != address(0);
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

        uint256 baseAmount = amount;
        mapping(address => uint256) storage earned = affiliateCoinEarned[lvl];
        IPurgeGameTrophies trophies_ = trophies;

        address[3] memory players;
        uint256[3] memory amounts;
        uint256 cursor;

        // Pay direct affiliate
        // Direct affiliate: rakeback and score are based on the base amount; stake bonus only boosts the payout.
        uint256 rakebackShare = (baseAmount * uint256(rakebackPct)) / 100;
        uint256 affiliateShareBase = baseAmount - rakebackShare;
        uint8 stakeBonus = address(trophies_) != address(0) ? trophies_.affiliateStakeBonus(affiliateAddr) : 0;
        uint256 affiliatePayout = affiliateShareBase;
        if (stakeBonus != 0) {
            affiliatePayout += (affiliateShareBase * stakeBonus) / 100;
        }

        uint256 newTotal = earned[affiliateAddr] + affiliateShareBase; // score ignores stake bonus
        earned[affiliateAddr] = newTotal;

        uint256 questReward = coinActive ? coin.affiliateQuestReward(affiliateAddr, affiliatePayout) : 0;

        uint256 totalFlipAward = affiliatePayout + questReward;
        if (totalFlipAward != 0 && coinActive) {
            players[cursor] = affiliateAddr;
            amounts[cursor] = totalFlipAward;
            unchecked {
                ++cursor;
            }
        } else if (totalFlipAward != 0) {
            presaleCoinEarned[affiliateAddr] += totalFlipAward;
            presaleClaimableTotal += totalFlipAward;
        }

        _updateTopAffiliate(affiliateAddr, newTotal, lvl);

        playerRakeback = rakebackShare;

        // Upline bonus (20% of base amount); no stake bonus applied to uplines.
        address upline = _referrerAddress(affiliateAddr);
        if (upline != address(0) && upline != sender) {
            uint256 bonus = baseAmount / 5;
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
                    presaleClaimableTotal += totalUpline;
                }
            }

            // Second upline bonus (20%)
            address upline2 = _referrerAddress(upline);
            if (upline2 != address(0)) {
                uint256 bonus2 = bonus / 5;
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
                        presaleClaimableTotal += totalUpline2;
                    }
                }
            }
        }

        if (players[0] != address(0) || players[1] != address(0) || players[2] != address(0)) {
            coin.creditFlipBatch(players, amounts);
        } else if (!coinActive && playerRakeback != 0) {
            presaleCoinEarned[sender] += playerRakeback;
            presaleClaimableTotal += playerRakeback;
        }

        emit Affiliate(amount, storedCode, sender);
        return playerRakeback;
    }

    // ---------------------------------------------------------------------
    // Affiliate bond claims (reward mints)
    // ---------------------------------------------------------------------
    /// @notice Configure claim tiers that award free bonds to affiliates once they reach a score threshold for a level.
    /// @dev Access: bonds only. Up to 256 tiers supported (bit-packed claimed flags).
    function setAffiliateBondRewards(AffiliateBondReward[] calldata rewards) external {
        if (msg.sender != bonds) revert OnlyBonds();
        uint256 len = rewards.length;
        if (len > AFFILIATE_BOND_MAX_TIERS) revert ClaimConfigTooLarge();
        delete affiliateBondRewards;
        for (uint256 i; i < len; ) {
            AffiliateBondReward calldata reward = rewards[i];
            if (
                reward.scoreRequired == 0 ||
                reward.bonds == 0 ||
                reward.baseWeiPerBond < AFFILIATE_BOND_MIN_BASE ||
                reward.baseWeiPerBond > AFFILIATE_BOND_MAX_BASE
            ) {
                revert InvalidClaimConfig();
            }
            affiliateBondRewards.push(reward);
            unchecked {
                ++i;
            }
        }
        emit AffiliateBondRewardsUpdated(len);
    }

    /// @notice Claim a bond reward tier for the caller for a given level.
    /// @param lvl Level whose affiliate score is evaluated.
    /// @param tierIdx Reward tier index (0-based).
    function claimAffiliateBond(uint24 lvl, uint8 tierIdx) external {
        AffiliateBondReward memory reward = _affiliateBondReward(tierIdx);

        uint256 claimedMask = affiliateBondClaimed[lvl][msg.sender];
        uint256 mask = uint256(1) << tierIdx;
        if ((claimedMask & mask) != 0) revert ClaimAlreadyClaimed();

        uint256 score = affiliateCoinEarned[lvl][msg.sender];
        if (score < reward.scoreRequired) revert ClaimScoreTooLow();

        affiliateBondClaimed[lvl][msg.sender] = claimedMask | mask;

        IPurgeBondsAffiliateMint(bonds).mintAffiliateReward(
            msg.sender,
            reward.bonds,
            reward.baseWeiPerBond,
            reward.stake
        );

        emit AffiliateBondClaimed(msg.sender, lvl, tierIdx, reward.bonds);
    }

    /// @notice Return the number of claimable tiers and the claimed bitmask for a player/level pair.
    function claimableAffiliateBondTiers(
        address player,
        uint24 lvl
    ) external view returns (uint16 claimable, uint256 claimedMask) {
        claimedMask = affiliateBondClaimed[lvl][player];
        uint256 len = affiliateBondRewards.length;
        if (len == 0) return (0, claimedMask);

        uint256 score = affiliateCoinEarned[lvl][player];
        for (uint256 i; i < len; ) {
            AffiliateBondReward memory reward = affiliateBondRewards[i];
            if ((claimedMask & (uint256(1) << i)) == 0 && score >= reward.scoreRequired) {
                unchecked {
                    ++claimable;
                }
            }
            unchecked {
                ++i;
            }
        }
    }

    /// @notice Number of configured affiliate bond reward tiers.
    function affiliateBondRewardsLength() external view returns (uint256) {
        return affiliateBondRewards.length;
    }

    /// @notice Return a configured affiliate bond reward tier.
    function affiliateBondReward(uint256 idx) external view returns (AffiliateBondReward memory) {
        return affiliateBondRewards[idx];
    }

    function _affiliateBondReward(uint8 idx) private view returns (AffiliateBondReward memory reward) {
        if (idx >= affiliateBondRewards.length) revert ClaimTierInvalid();
        reward = affiliateBondRewards[idx];
    }

    /// @notice Consume and return the caller’s accrued presale/early affiliate coin for minting.
    /// @dev Access: coin only.
    function consumePresaleCoin(address player) external returns (uint256 amount) {
        if (msg.sender != address(coin)) revert OnlyAuthorized();
        amount = presaleCoinEarned[player] + presalePrincipal[player];
        if (amount != 0) {
            presaleCoinEarned[player] = 0;
            presalePrincipal[player] = 0;
            if (amount <= presaleClaimableTotal) {
                presaleClaimableTotal -= amount;
            } else {
                presaleClaimableTotal = 0;
            }
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

    /// @notice Return synthetic map info (affiliate owner and locked code) for a synthetic player.
    function syntheticMapInfo(address synthetic) external view returns (address owner, bytes32 code) {
        owner = syntheticMapOwner[synthetic];
        code = syntheticMapCode[synthetic];
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
