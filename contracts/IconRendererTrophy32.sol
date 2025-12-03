// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import "@openzeppelin/contracts/utils/Base64.sol";
import "@openzeppelin/contracts/utils/Strings.sol";
import "./interfaces/IconRendererTypes.sol";
import {IIconRendererTrophy32Svg} from "./IconRendererTrophy32Svg.sol";

/**
 * @title IconRendererTrophy32
 * @notice Dedicated renderer for Purge Game trophy metadata and SVG generation.
 */
contract IconRendererTrophy32 {
    using Strings for uint256;

    uint256 private constant MAP_TROPHY_FLAG = uint256(1) << 200;
    uint256 private constant AFFILIATE_TROPHY_FLAG = uint256(1) << 201;
    uint256 private constant STAKE_TROPHY_FLAG = uint256(1) << 202;
    uint256 private constant BAF_TROPHY_FLAG = uint256(1) << 203;
    uint256 private constant DECIMATOR_TROPHY_FLAG = uint256(1) << 204;
    uint256 private constant TROPHY_FLAG_INVERT = uint256(1) << 229;
    uint256 private constant TROPHY_STAKE_LEVEL_SHIFT = 205;
    uint256 private constant TROPHY_STAKE_LEVEL_MASK =
        uint256(0xFFFFFF) << TROPHY_STAKE_LEVEL_SHIFT;
    uint256 private constant TROPHY_OWED_MASK = (uint256(1) << 128) - 1;
    uint16 private constant BAF_TRAIT_SENTINEL = 0xFFFA;
    uint16 private constant DECIMATOR_TRAIT_SENTINEL = 0xFFFB;
    IPurgedRead private immutable coin;
    IIcons32 private immutable icons;
    IColorRegistry private immutable registry;
    address public immutable bonds;
    IIconRendererTrophy32Svg private immutable svgRenderer;

    IERC721Lite private nft;

    error E();

    constructor(
        address coin_,
        address icons_,
        address registry_,
        address svgRenderer_,
        address bonds_
    ) {
        coin = IPurgedRead(coin_);
        icons = IIcons32(icons_);
        registry = IColorRegistry(registry_);
        if (svgRenderer_ == address(0) || bonds_ == address(0)) revert E();
        svgRenderer = IIconRendererTrophy32Svg(svgRenderer_);
        bonds = bonds_;
    }

    function setMyColors(
        string calldata outlineHex,
        string calldata flameHex,
        string calldata diamondHex,
        string calldata squareHex
    ) external returns (bool) {
        return
            registry.setMyColors(
                msg.sender,
                outlineHex,
                flameHex,
                diamondHex,
                squareHex
            );
    }

    function setCustomColorsForMany(
        uint256[] calldata tokenIds,
        string calldata outlineHex,
        string calldata flameHex,
        string calldata diamondHex,
        string calldata squareHex,
        uint32 trophyOuterPct1e6
    ) external returns (bool) {
        return
            registry.setCustomColorsForMany(
                msg.sender,
                address(nft),
                tokenIds,
                outlineHex,
                flameHex,
                diamondHex,
                squareHex,
                trophyOuterPct1e6
            );
    }

    function setTopAffiliateColor(
        uint256 tokenId,
        string calldata trophyHex
    ) external returns (bool) {
        return registry.setTopAffiliateColor(msg.sender, address(nft), tokenId, trophyHex);
    }

    modifier onlyBonds() {
        if (msg.sender != bonds) revert E();
        _;
    }

    /// @notice Wire NFT contract in a single call; callable only by bonds, set-once.
    function wire(address[] calldata addresses) external onlyBonds {
        _setNft(addresses.length > 0 ? addresses[0] : address(0));
    }

    function _setNft(address nftAddr) private {
        if (nftAddr == address(0)) return;
        address current = address(nft);
        if (current == address(0)) {
            nft = IERC721Lite(nftAddr);
            svgRenderer.setNft(nftAddr);
        } else if (current != nftAddr) {
            revert E();
        }
    }

    function tokenURI(
        uint256 tokenId,
        uint256 data,
        uint32[4] calldata extras
    ) external view returns (string memory) {
        // `data` carries the packed trophy word emitted by the game:
        // bits [167:152]=exterminated trait (0xFFFF placeholder), [151:128]=level,
        // [204:200]=trophy type flags, [228:205]=staked level, [127:0]=owed ETH.
        // `extras` is a small status bundle set by the caller: extras[0] status bits
        // (bit31=bond render, bit0=staked, bit1=matured), extras[1]=bond created distance,
        // extras[2]=bond current distance, extras[3]=chance bps | (bit31=staked).
        return _tokenURI(tokenId, data, extras, 0);
    }

    /// @notice Render PurgeBond NFTs as exterminator trophy placeholders.
    function bondTokenURI(
        uint256 tokenId,
        uint32 createdDistance,
        uint32 currentDistance,
        uint16 chanceBps,
        bool staked_,
        uint256 sellCoinValue
    ) external view returns (string memory) {
        uint32[4] memory extras;
        // High bit in extras[0] marks bond rendering for attribute injection.
        extras[0] = (uint32(1) << 31) | (staked_ ? 1 : 0) | (currentDistance == 0 ? 2 : 0);
        extras[1] = createdDistance;
        extras[2] = currentDistance;
        extras[3] = uint32(chanceBps) | (staked_ ? (uint32(1) << 31) : 0);

        uint256 placeholderData = uint256(0xFFFF) << 152;
        return _tokenURI(tokenId, placeholderData, extras, sellCoinValue);
    }

    function _tokenURI(
        uint256 tokenId,
        uint256 data,
        uint32[4] memory extras,
        uint256 bondSellCoin
    ) private view returns (string memory) {
        if ((data >> 128) == 0) revert("renderer:notTrophy");

        uint24 lvl = uint24((data >> 128) & 0xFFFFFF);
        uint16 exTr = _readExterminatedTrait(data);
        bool isMap = (data & MAP_TROPHY_FLAG) != 0;
        bool isAffiliate = (data & AFFILIATE_TROPHY_FLAG) != 0;
        bool isStake = (data & STAKE_TROPHY_FLAG) != 0;
        bool isBaf = (data & BAF_TROPHY_FLAG) != 0;
        bool isDec = (data & DECIMATOR_TROPHY_FLAG) != 0;
        bool isExtermination = !isMap &&
            !isAffiliate &&
            !isStake &&
            !isBaf &&
            !isDec;
        bool forcePlaceholder = isExtermination &&
            (tokenId == 0 || ((extras[0] & (uint32(1) << 31)) != 0));
        if (forcePlaceholder) {
            exTr = 0xFFFF;
        }
        bool invertFlag = (data & TROPHY_FLAG_INVERT) != 0;
        uint32 statusFlags = extras[0];
        bool isBond = (statusFlags & (uint32(1) << 31)) != 0;
        uint32 bondCreated = extras[1];
        uint32 bondCurrent = extras[2];
        uint32 bondPack = extras[3];
        bool bondStaked = (bondPack & (uint32(1) << 31)) != 0;
        uint16 bondChance = uint16(bondPack);
        bool bondMatured = (statusFlags & 2) != 0 || bondCurrent == 0;
        if (bondStaked) statusFlags |= 1;
        if (bondMatured) statusFlags |= 2;
        uint256 ethAttachment = data & TROPHY_OWED_MASK;
        if ((statusFlags & 2) == 0 && ethAttachment != 0) {
            statusFlags |= 2;
        }
        if (forcePlaceholder) {
            statusFlags = 0; // keep placeholder extermination renders badge-free for token 0 and bonds
        }
        bool hasEthAttachment = ethAttachment != 0;
        uint24 stakedLevel = uint24(
            (data & TROPHY_STAKE_LEVEL_MASK) >> TROPHY_STAKE_LEVEL_SHIFT
        );
        bool hasStakedLevel = stakedLevel != 0;
        string memory stakedDurationStr;
        string memory stakeAttrValue = "No";
        if (hasStakedLevel) {
            uint256 duration = uint256(lvl) >= uint256(stakedLevel)
                ? uint256(lvl) - uint256(stakedLevel)
                : 0;
            stakedDurationStr = duration.toString();
            stakeAttrValue = string.concat(stakedDurationStr, " Levels");
        } else if (isBond) {
            stakeAttrValue = bondStaked ? "Yes" : "No";
        }

        string memory lvlStr = (lvl == 0) ? "TBD" : uint256(lvl).toString();
        string memory trophyType;
        string memory trophyLabel;
        if (isMap) {
            trophyType = "MAP";
            trophyLabel = "MAP Trophy";
        } else if (isAffiliate) {
            trophyType = "Affiliate";
            trophyLabel = "Affiliate Trophy";
        } else if (isStake) {
            trophyType = "Stake";
            trophyLabel = "Stake Trophy";
        } else if (isBaf) {
            trophyType = "BAF";
            trophyLabel = "BAF Trophy";
        } else if (isDec) {
            trophyType = "Decimator";
            trophyLabel = "Decimator Trophy";
        } else {
            trophyType = "Exterminator";
            trophyLabel = "Exterminator Trophy";
        }

        string memory desc;
        if (exTr == 0xFFFF) {
            if (lvl == 0) {
                desc = string.concat("Reserved Purge Game ", trophyLabel, ".");
            } else {
                desc = string.concat(
                    "Reserved for level ",
                    lvlStr,
                    " ",
                    trophyLabel,
                    "."
                );
            }
        } else if (isAffiliate && exTr == 0xFFFE) {
            desc = string.concat(
                "Awarded to the top affiliate for level ",
                lvlStr,
                "."
            );
        } else if (isStake && exTr == 0xFFFD) {
            desc = string.concat(
                "Awarded for level ",
                lvlStr,
                " largest stake maturation."
            );
        } else if (isBaf && exTr == BAF_TRAIT_SENTINEL) {
            desc = string.concat(
                "Awarded to the biggest coinflipper in the level ",
                lvlStr,
                " BAF."
            );
        } else if (isDec && exTr == DECIMATOR_TRAIT_SENTINEL) {
            desc = string.concat(
                "Awarded to the biggest winner in the level ",
                lvlStr,
                " Decimator."
            );
        } else {
            desc = string.concat("Awarded for level ", lvlStr);
            desc = string.concat(
                desc,
                isMap ? " MAP Jackpot." : " Extermination victory."
            );
        }

        if (hasEthAttachment) {
            desc = string.concat(
                desc,
                "\\n",
                _formatEthAmount(ethAttachment),
                " ETH claimable."
            );
        }
        if (hasStakedLevel) {
            desc = string.concat(
                desc,
                "\\nStaked for ",
                stakedDurationStr,
                " levels."
            );
        }

        bool includeTraitAttr;
        string memory traitType;
        string memory traitValue;
        if (exTr < 256 && (isMap || isExtermination)) {
            uint8 quadrant = uint8(exTr >> 6);
            uint8 raw = uint8(exTr & 0x3F);
            uint8 colorIdx = raw >> 3;
            uint8 symIdx = raw & 0x07;
            traitType = _quadrantTitle(quadrant);
            traitValue = _traitLabel(quadrant, colorIdx, symIdx);
            includeTraitAttr = true;
        }

        string memory attrs;
        if (!isBond) {
            attrs = string(
                abi.encodePacked(
                    '[{"trait_type":"Level","value":"',
                    lvlStr,
                    '"},{"trait_type":"Trophy","value":"',
                    trophyType,
                    '"},{"trait_type":"Eth","value":"',
                    hasEthAttachment ? "Yes" : "No",
                    '"}'
                )
            );
            if (includeTraitAttr) {
                attrs = string(
                    abi.encodePacked(
                        attrs,
                        ',{"trait_type":"',
                        traitType,
                        '","value":"',
                        traitValue,
                        '"}'
                    )
                );
            }
            attrs = string(
                abi.encodePacked(
                    attrs,
                    ',{"trait_type":"Staked","value":"',
                    stakeAttrValue,
                    '"}'
                )
            );
            attrs = string(abi.encodePacked(attrs, "]"));
        }

        uint32 bondProgress = isBond
            ? _bondElapsedPct1e6(bondCreated, bondCurrent, bondMatured)
            : 0;
        IIconRendererTrophy32Svg.SvgParams memory svgParams = IIconRendererTrophy32Svg.SvgParams({
            tokenId: tokenId,
            exterminatedTrait: exTr,
            isMap: isMap,
            isAffiliate: isAffiliate,
            isStake: isStake,
            isBaf: isBaf,
            isDec: isDec,
            statusFlags: statusFlags,
            lvl: lvl,
            invertFlag: invertFlag,
            isBond: isBond,
            bondChanceBps: bondChance,
            bondMatured: bondMatured,
            bondProgress1e6: bondProgress
        });
        string memory img = svgRenderer.trophySvg(svgParams);
        if (isBond) {
            string memory name_ = bondMatured
                ? string.concat("Matured PurgeBond #", tokenId.toString())
                : string.concat(
                    _formatBpsPercent(bondChance),
                    " PurgeBond #",
                    tokenId.toString()
                );
            string memory bondAttrs = _bondAttributes(
                bondMatured,
                bondStaked,
                bondCreated,
                bondCurrent,
                bondChance,
                bondSellCoin
            );
            return
                _packBond(
                    img,
                    name_,
                    "A sequential claim on the revenue derived from Purge Game.",
                    bondAttrs
                );
        }
        return _pack(tokenId, true, img, lvl, desc, trophyType, attrs);
    }

    // ---------------------------------------------------------------------
    // Internal helpers
    // ---------------------------------------------------------------------

    function _readExterminatedTrait(
        uint256 data
    ) private pure returns (uint16) {
        uint16 ex16 = uint16((data >> 152) & 0xFFFF);
        if (ex16 >= 0xFFFA) return ex16;
        return uint16(uint8(ex16));
    }


    function _bondElapsedPct1e6(
        uint32 created,
        uint32 current,
        bool matured
    ) private pure returns (uint32) {
        uint32 base = created == 0 ? 1 : created;
        uint32 usedCurrent = current;
        if (matured || current > created) {
            usedCurrent = 0;
        }
        uint256 elapsed = uint256(base) - uint256(usedCurrent);
        uint256 pct = (elapsed * 1_000_000) / uint256(base);
        if (pct > 1_000_000) return 1_000_000;
        return uint32(pct);
    }

    function _colorTitle(uint8 idx) private pure returns (string memory) {
        if (idx == 0) return "Pink";
        if (idx == 1) return "Purple";
        if (idx == 2) return "Green";
        if (idx == 3) return "Red";
        if (idx == 4) return "Blue";
        if (idx == 5) return "Orange";
        if (idx == 6) return "Silver";
        return "Gold";
    }

    function _quadrantTitle(uint8 idx) private pure returns (string memory) {
        if (idx == 0) return "Crypto";
        if (idx == 1) return "Zodiac";
        if (idx == 2) return "Gambling";
        return "Dice";
    }

    function _symbolTitle(
        uint8 quadrant,
        uint8 symbolIdx
    ) private view returns (string memory) {
        if (quadrant < 3) {
            string memory externalName = icons.symbol(quadrant, symbolIdx);
            if (bytes(externalName).length != 0) {
                return externalName;
            }
            return
                string.concat("Symbol ", (uint256(symbolIdx) + 1).toString());
        }

        return string.concat("Dice ", (uint256(symbolIdx) + 1).toString());
    }

    function _traitLabel(
        uint8 quadrant,
        uint8 colorIdx,
        uint8 symbolIdx
    ) private view returns (string memory) {
        return
            string.concat(
                _colorTitle(colorIdx),
                " ",
                _symbolTitle(quadrant, symbolIdx)
            );
    }

    function _packBond(
        string memory svg,
        string memory name_,
        string memory desc,
        string memory attrs
    ) private pure returns (string memory) {
        string memory imgData = string.concat(
            "data:image/svg+xml;base64,",
            Base64.encode(bytes(svg))
        );

        string memory j = string.concat('{"name":"', name_);
        j = string.concat(j, '","description":"', desc);
        j = string.concat(j, '","image":"', imgData, '","attributes":');
        j = string.concat(j, attrs, "}");

        return
            string.concat(
                "data:application/json;base64,",
                Base64.encode(bytes(j))
            );
    }

    function _pack(
        uint256 tokenId,
        bool isTrophy,
        string memory svg,
        uint256 level,
        string memory desc,
        string memory trophyType,
        string memory attrs
    ) private pure returns (string memory) {
        string memory lvlStr = (level == 0) ? "TBD" : level.toString();
        string memory nm = isTrophy
            ? string.concat(
                "Purge Game Level ",
                lvlStr,
                " ",
                trophyType,
                " Trophy"
            )
            : string.concat(
                "Purge Game Level ",
                lvlStr,
                " #",
                tokenId.toString()
            );

        string memory imgData = string.concat(
            "data:image/svg+xml;base64,",
            Base64.encode(bytes(svg))
        );

        string memory j = string.concat('{"name":"', nm);
        j = string.concat(j, '","description":"', desc);
        j = string.concat(j, '","image":"', imgData, '","attributes":');
        if (isTrophy) {
            j = string.concat(j, attrs, "}");
        } else {
            j = string.concat(j, "[]}");
        }

        return
            string.concat(
                "data:application/json;base64,",
            Base64.encode(bytes(j))
            );
    }

    function _bondAttributes(
        bool matured,
        bool staked,
        uint32 created,
        uint32 current,
        uint16 chanceBps,
        uint256 sellCoinValue
    ) private pure returns (string memory) {
        return
            string(
                abi.encodePacked(
                    '[{"trait_type":"Matured","value":"',
                    matured ? "Yes" : "No",
                    '"},{"trait_type":"Staked","value":"',
                    staked ? "Yes" : "No",
                    '"},{"trait_type":"Initial Distance","value":"',
                    uint256(created).toString(),
                    '"},{"trait_type":"Current Distance","value":"',
                    uint256(current).toString(),
                    '"},{"trait_type":"Odds","value":"',
                    _formatBpsPercent(chanceBps),
                    '"},{"trait_type":"Sellback (PURGE)","value":"',
                    _formatCoinAmount(sellCoinValue),
                    '"}]'
                )
            );
    }

    function _formatBpsPercent(uint16 bps) private pure returns (string memory) {
        uint256 pct = uint256(bps);
        uint256 whole = pct / 100;
        uint256 frac = pct % 100;
        if (frac == 0) {
            return string.concat(whole.toString(), "%");
        }
        if (frac % 10 == 0) {
            return
                string.concat(
                    whole.toString(),
                    ".",
                    (frac / 10).toString(),
                    "%"
                );
        }
        bytes memory two = new bytes(2);
        two[0] = bytes1(uint8(48 + (frac / 10)));
        two[1] = bytes1(uint8(48 + (frac % 10)));
        return string.concat(whole.toString(), ".", string(two), "%");
    }

    function _formatEthAmount(
        uint256 weiAmount
    ) private pure returns (string memory) {
        uint256 whole = weiAmount / 1 ether;
        uint256 frac = (weiAmount % 1 ether) / 1e14; // 4 decimals

        return
            string.concat(
                whole.toString(),
                ".",
            _pad4(uint16(frac)),
            " ETH"
        );
    }

    function _formatCoinAmount(uint256 amount) private pure returns (string memory) {
        uint256 whole = amount / 1e6;
        uint256 frac = amount % 1e6;
        bytes memory fracStr = new bytes(6);
        fracStr[0] = bytes1(uint8(48 + (frac / 100000) % 10));
        fracStr[1] = bytes1(uint8(48 + (frac / 10000) % 10));
        fracStr[2] = bytes1(uint8(48 + (frac / 1000) % 10));
        fracStr[3] = bytes1(uint8(48 + (frac / 100) % 10));
        fracStr[4] = bytes1(uint8(48 + (frac / 10) % 10));
        fracStr[5] = bytes1(uint8(48 + (frac % 10)));

        return string.concat(whole.toString(), ".", string(fracStr), " PURGE");
    }

    function _pad4(uint16 v) private pure returns (string memory) {
        bytes memory b = new bytes(4);
        b[0] = bytes1(uint8(48 + (v / 1000) % 10));
        b[1] = bytes1(uint8(48 + (v / 100) % 10));
        b[2] = bytes1(uint8(48 + (v / 10) % 10));
        b[3] = bytes1(uint8(48 + (v % 10)));
        return string(b);
    }

}
