// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {IDegenerusGame} from "./interfaces/IDegenerusGame.sol";

interface IDegenerusCoinAffiliate {
    function balanceOf(address account) external view returns (uint256);
    function presaleDistribute(address buyer, uint256 amountBase) external;
    function creditFlip(address player, uint256 amount) external;
    function creditFlipBatch(address[3] calldata players, uint256[3] calldata amounts) external;
    function affiliateQuestReward(address player, uint256 amount) external returns (uint256);
    function affiliatePrimePresale() external;
    function burnCoinAffiliate(address target, uint256 amount) external;
}

interface IDegenerusBondsPresale {
    function ingestPresaleEth() external payable;
}

contract DegenerusAffiliate {
    // ---------------------------------------------------------------------
    // Events
    // ---------------------------------------------------------------------
    event Affiliate(uint256 amount, bytes32 indexed code, address sender);
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
    error OnlyGame();
    error SyntheticCap();

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

    struct SyntheticCapInfo {
        uint32 minted; // number of synthetic players created
        uint32 cap; // total synthetic players allowed
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
    uint256 private constant SYNTH_BASE_COST = 1500 * MILLION; // base 10 slots after level > 3
    uint256 private constant SYNTH_TOPUP_COST = 2500 * MILLION; // per +10 slots
    uint32 private constant SYNTH_BATCH = 10;

    // ---------------------------------------------------------------------
    // Immutable / wiring
    // ---------------------------------------------------------------------
    address public immutable bonds;

    IDegenerusCoinAffiliate private coin;
    IDegenerusGame private degenerusGame;

    // ---------------------------------------------------------------------
    // Affiliate state
    // ---------------------------------------------------------------------
    mapping(bytes32 => AffiliateCodeInfo) public affiliateCode;
    mapping(uint24 => mapping(address => uint256)) public affiliateCoinEarned;
    mapping(address => bytes32) private playerReferralCode;
    mapping(address => address) public syntheticMapOwner; // synthetic player -> affiliate owner
    mapping(address => uint256) public presaleCoinEarned;
    mapping(address => uint256) public presalePrincipal; // principal bought while coin is unwired
    mapping(uint24 => PlayerScore) private affiliateTopByLevel;
    mapping(address => SyntheticCapInfo) private syntheticCap;
    uint256 public presaleClaimableTotal;
    uint256 private presaleInventoryBase = PRESALE_SUPPLY_TOKENS * MILLION; // used before coin is wired
    uint256 private presalePricePer1000 = PRESALE_PRICE_START_1000;
    uint96 public totalPresaleSold;
    uint64 private syntheticNonce;
    uint48 private presaleLastDay;
    bool private preCoinActive = true;
    bool private presaleShutdown; // permanently stops new presale purchases once coin is wired
    bool private presaleIncreasedToday;
    bool private referralLocksActive;

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
    /// @notice Wire coin and game via an address array ([coin, game]).
    /// @dev Each address can be set once; non-zero updates must match the existing value.
    function wire(address[] calldata addresses) external {
        if (msg.sender != bonds) revert OnlyBonds();
        _setCoin(addresses.length > 0 ? addresses[0] : address(0));
        _setGame(addresses.length > 1 ? addresses[1] : address(0));
    }

    function _setCoin(address coinAddr) private {
        if (coinAddr == address(0)) {
            if (address(coin) == address(0)) revert ZeroAddress();
            return;
        }
        address current = address(coin);
        if (current == address(0)) {
            coin = IDegenerusCoinAffiliate(coinAddr);
            presaleShutdown = true; // stop presale once coin is wired
            preCoinActive = false;
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

    /// @notice Create a synthetic MAP-only player; callable only by the affiliate that owns the code.
    /// @dev Synthetic addresses are auto-generated with the low 48 bits zeroed to make them identifiable.
    function createSyntheticMapPlayer(bytes32 code_) external returns (address synthetic) {
        address affiliateOwner = msg.sender;
        AffiliateCodeInfo storage info = affiliateCode[code_];
        if (info.owner != affiliateOwner) revert OnlyAuthorized();

        address gameAddr = address(degenerusGame);
        if (gameAddr == address(0)) revert OnlyGame();

        uint160 mask = uint160(~((uint160(1) << 48) - 1));
        uint64 nonce = syntheticNonce;
        do {
            unchecked {
                ++nonce;
            }
            synthetic = address(
                uint160(uint256(keccak256(abi.encode(affiliateOwner, code_, nonce, block.chainid)))) & mask
            );
        } while (synthetic == address(0) || syntheticMapOwner[synthetic] != address(0));
        syntheticNonce = nonce;

        if (playerReferralCode[synthetic] != bytes32(0)) revert Insufficient();
        SyntheticCapInfo storage capInfo = syntheticCap[affiliateOwner];
        uint32 cap = capInfo.cap;
        if (cap == 0) {
            // Grant the base 10 slots for free only through level 3; later requires a paid unlock.
            uint24 currentLevel = degenerusGame.level();
            if (currentLevel <= 3) {
                cap = SYNTH_BATCH;
                capInfo.cap = cap;
            } else {
                revert SyntheticCap();
            }
        }
        if (capInfo.minted >= cap) revert SyntheticCap();
        syntheticMapOwner[synthetic] = affiliateOwner;
        playerReferralCode[synthetic] = code_;
        unchecked {
            ++capInfo.minted;
        }
        emit SyntheticMapPlayerCreated(synthetic, affiliateOwner, code_);
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

    /// @notice Presale purchase flow (ETH -> BURNIE) with linear price ramp and deferred bonuses.
    function presale() external payable returns (uint256 amountBase) {
        if (presaleShutdown) revert PresaleClosed();
        uint256 ethIn = msg.value;
        if (ethIn < 0.001 ether) revert Insufficient();
        if (ethIn > PRESALE_MAX_ETH_PER_TX) revert PresalePerTxLimit();

        if (!preCoinActive) revert PresaleExceedsRemaining();
        uint256 pricePer1000 = _applyPresaleDecay();
        uint256 inventoryBase = presaleInventoryBase;
        uint256 inventoryTokens = inventoryBase / MILLION;
        if (inventoryTokens == 0) revert PresaleExceedsRemaining();

        // price per token = pricePer1000 / 1000
        uint256 tokensOut;
        unchecked {
            tokensOut = (ethIn * PRESALE_PRICE_DIVISOR) / pricePer1000;
        }
        if (tokensOut == 0) revert Insufficient();
        if (tokensOut > inventoryTokens) {
            tokensOut = inventoryTokens;
        }

        uint256 costWei;
        unchecked {
            costWei = (tokensOut * pricePer1000) / PRESALE_PRICE_DIVISOR;
        }
        uint256 refund = ethIn - costWei;

        amountBase = tokensOut * MILLION;
        totalPresaleSold = uint96(uint256(totalPresaleSold) + amountBase);

        address payable buyer = payable(msg.sender);
        presaleInventoryBase = inventoryBase - amountBase;
        presalePrincipal[buyer] += amountBase;
        uint256 buyerEarned = presaleCoinEarned[buyer] + amountBase;

        IDegenerusBondsPresale(bonds).ingestPresaleEth{value: costWei}(); // bonds routes 90% to prize pool

        if (refund != 0) {
            (bool refundOk, ) = buyer.call{value: refund}("");
            if (!refundOk) revert Insufficient();
        }

        _bumpPresalePrice(costWei);

        address affiliateAddr = _referrerAddress(buyer);
        uint256 claimableDelta = amountBase;
        if (affiliateAddr != address(0) && affiliateAddr != buyer) {
            uint256 affiliateBonus = (amountBase * 5) / 100;
            uint256 buyerBonus = (amountBase * 2) / 100;
            if (affiliateBonus != 0) {
                presaleCoinEarned[affiliateAddr] += affiliateBonus;
                claimableDelta += affiliateBonus;
            }
            if (buyerBonus != 0) {
                buyerEarned += buyerBonus;
                claimableDelta += buyerBonus;
            }
        }
        presaleCoinEarned[buyer] = buyerEarned;
        presaleClaimableTotal += claimableDelta;
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

        mapping(address => uint256) storage earned = affiliateCoinEarned[lvl];

        // Pay direct affiliate (score based on base amount).
        uint256 rakebackShare = (amount * uint256(rakebackPct)) / 100;
        uint256 affiliateShareBase = amount - rakebackShare;
        uint256 newTotal = earned[affiliateAddr] + affiliateShareBase; // score ignores stake bonus
        earned[affiliateAddr] = newTotal;

        _updateTopAffiliate(affiliateAddr, newTotal, lvl);
        playerRakeback = rakebackShare;

        if (coinActive) {
            address[3] memory players;
            uint256[3] memory amounts;
            uint256 cursor;

            uint256 questReward = coin.affiliateQuestReward(affiliateAddr, affiliateShareBase);
            uint256 totalFlipAward = affiliateShareBase + questReward;
            if (totalFlipAward != 0) {
                players[cursor] = affiliateAddr;
                amounts[cursor] = totalFlipAward;
                unchecked {
                    ++cursor;
                }
            }

            // Upline bonus (20% of base amount); no stake bonus applied to uplines.
            address upline = _referrerAddress(affiliateAddr);
            if (upline != address(0) && upline != sender) {
                uint256 bonus = amount / 5;
                uint256 questRewardUpline = coin.affiliateQuestReward(upline, bonus);
                uint256 totalUpline = bonus + questRewardUpline;
                earned[upline] = earned[upline] + bonus;

                if (totalUpline != 0 && cursor < 3) {
                    players[cursor] = upline;
                    amounts[cursor] = totalUpline;
                    unchecked {
                        ++cursor;
                    }
                }

                // Second upline bonus (20% of first upline share)
                address upline2 = _referrerAddress(upline);
                if (upline2 != address(0)) {
                    uint256 bonus2 = bonus / 5;
                    uint256 questReward2 = coin.affiliateQuestReward(upline2, bonus2);
                    uint256 totalUpline2 = bonus2 + questReward2;
                    earned[upline2] = earned[upline2] + bonus2;

                    if (totalUpline2 != 0 && cursor < 3) {
                        players[cursor] = upline2;
                        amounts[cursor] = totalUpline2;
                        unchecked {
                            ++cursor;
                        }
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
            uint256 totalFlipAwardPre = affiliateShareBase;
            if (totalFlipAwardPre != 0) {
                presaleCoinEarned[affiliateAddr] += totalFlipAwardPre;
                presaleClaimableTotal += totalFlipAwardPre;
            }

            // Upline bonus (20% of base amount); no stake bonus applied to uplines.
            address uplinePre = _referrerAddress(affiliateAddr);
            if (uplinePre != address(0) && uplinePre != sender) {
                uint256 bonusPre = amount / 5;
                uint256 uplineTotalPre = bonusPre;
                earned[uplinePre] = earned[uplinePre] + bonusPre;
                if (uplineTotalPre != 0) {
                    presaleCoinEarned[uplinePre] += uplineTotalPre;
                    presaleClaimableTotal += uplineTotalPre;
                }

                // Second upline bonus (20% of first upline share)
                address upline2Pre = _referrerAddress(uplinePre);
                if (upline2Pre != address(0)) {
                    uint256 bonus2Pre = bonusPre / 5;
                    earned[upline2Pre] = earned[upline2Pre] + bonus2Pre;
                    if (bonus2Pre != 0) {
                        presaleCoinEarned[upline2Pre] += bonus2Pre;
                        presaleClaimableTotal += bonus2Pre;
                    }
                }
            }

            if (playerRakeback != 0) {
                presaleCoinEarned[sender] += playerRakeback;
                presaleClaimableTotal += playerRakeback;
            }
        }

        emit Affiliate(amount, storedCode, sender);
        return playerRakeback;
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

    /// @notice Credit presale coin from LINK funding (VRF sub); callable by coin/bonds.
    function addPresaleLinkCredit(address player, uint256 amount) external {
        address caller = msg.sender;
        if (caller != address(coin) && caller != bonds) revert OnlyAuthorized();
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

    /// @notice Estimate the current priceCoin-equivalent rate for presale (coin units per 1 ETH) using decay rules.
    /// @dev Uses a read-only version of the decay logic; does not mutate price state.
    function presalePriceCoinEstimate() external view returns (uint256 priceCoinUnit) {
        uint256 pricePer1000 = _presalePricePer1000View();
        if (pricePer1000 == 0) return 0;
        uint256 tokensPerEth = (1 ether * PRESALE_PRICE_DIVISOR) / pricePer1000;
        return tokensPerEth * MILLION;
    }

    /// @notice View-only helper mirroring `_applyPresaleDecay` without modifying storage.
    function _presalePricePer1000View() private view returns (uint256 pricePer1000) {
        pricePer1000 = presalePricePer1000;
        if (uint256(totalPresaleSold) / MILLION >= PRESALE_DECAY_CUTOFF_TOKENS) {
            return pricePer1000;
        }

        uint48 day = uint48(block.timestamp / 1 days);
        uint48 last = presaleLastDay;
        if (last == 0) return pricePer1000;
        if (day > last) {
            uint256 daysElapsed = uint256(day) - uint256(last);
            if (presaleIncreasedToday && daysElapsed != 0) {
                unchecked {
                    --daysElapsed; // skip first decay day if price bumped today
                }
            }
            if (daysElapsed != 0) {
                uint256 decay = daysElapsed * PRESALE_PRICE_DECAY_1000;
                if (decay >= pricePer1000 || pricePer1000 - decay < PRESALE_PRICE_FLOOR_1000) {
                    pricePer1000 = PRESALE_PRICE_FLOOR_1000;
                } else {
                    pricePer1000 -= decay;
                }
            }
        }
    }

    /// @notice Return synthetic map info (affiliate owner and locked code) for a synthetic player.
    function syntheticMapInfo(address synthetic) external view returns (address owner, bytes32 code) {
        owner = syntheticMapOwner[synthetic];
        code = playerReferralCode[synthetic];
    }

    /// @notice View current synthetic cap and minted count for an affiliate owner.
    function syntheticCapView(address affiliateOwner) external view returns (uint32 minted, uint32 cap) {
        SyntheticCapInfo memory info = syntheticCap[affiliateOwner];
        return (info.minted, info.cap);
    }

    /// @notice Increase synthetic MAP player cap by 10-slot increments by burning BURNIE.
    /// @dev Base cap of 10 is free only through level 3; later requires paying the base cost.
    function increaseSyntheticCap(uint8 batches) external {
        address affiliateOwner = msg.sender;
        SyntheticCapInfo storage info = syntheticCap[affiliateOwner];
        uint32 newCap = info.cap;
        uint256 cost;
        if (newCap != 0 && batches == 0) revert Zero();

        if (newCap == 0) {
            address gameAddr = address(degenerusGame);
            if (gameAddr == address(0)) revert OnlyGame();
            if (degenerusGame.level() > 3) {
                cost = SYNTH_BASE_COST;
            }
            newCap = SYNTH_BATCH;
        }

        if (batches != 0) {
            uint32 addSlots = uint32(batches) * SYNTH_BATCH;
            newCap += addSlots;
            cost += uint256(batches) * SYNTH_TOPUP_COST;
        }

        info.cap = newCap;

        if (cost != 0) {
            if (address(coin) == address(0)) revert ZeroAddress();
            coin.burnCoinAffiliate(affiliateOwner, cost);
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
