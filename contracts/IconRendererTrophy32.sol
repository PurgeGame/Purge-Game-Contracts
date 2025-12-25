// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import "@openzeppelin/contracts/utils/Base64.sol";
import "@openzeppelin/contracts/utils/Strings.sol";
import "./interfaces/IconRendererTypes.sol";
import {IIconRendererTrophy32Svg} from "./IconRendererTrophy32Svg.sol";

/**
 * @title IconRendererTrophy32
 * @notice Dedicated renderer for Degenerus trophy metadata and SVG generation.
 */
contract IconRendererTrophy32 {
    using Strings for uint256;

    uint256 private constant AFFILIATE_TROPHY_FLAG = uint256(1) << 201;
    uint256 private constant BAF_TROPHY_FLAG = uint256(1) << 203;
    uint256 private constant TROPHY_FLAG_INVERT = uint256(1) << 229;
    uint16 private constant BAF_TRAIT_SENTINEL = 0xFFFA;
    IIcons32 private immutable icons;
    IColorRegistry private immutable registry;
    address public immutable admin;
    IIconRendererTrophy32Svg private immutable svgRenderer;

    IERC721Lite private nft;

    error E();

    constructor(address icons_, address registry_, address svgRenderer_, address admin_) {
        icons = IIcons32(icons_);
        registry = IColorRegistry(registry_);
        if (svgRenderer_ == address(0)) revert E();
        svgRenderer = IIconRendererTrophy32Svg(svgRenderer_);
        if (admin_ == address(0)) revert E();
        admin = admin_;
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

    modifier onlyAdmin() {
        if (msg.sender != admin) revert E();
        _;
    }

    /// @notice Wire NFT contract in a single call; callable only by the coin admin, set-once.
    function wire(address[] calldata addresses) external onlyAdmin {
        _setNft(addresses.length > 0 ? addresses[0] : address(0));
    }

    function _setNft(address nftAddr) private {
        if (nftAddr == address(0)) return;
        address current = address(nft);
        if (current == address(0)) {
            nft = IERC721Lite(nftAddr);
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
        // [203:201]=trophy type flags, [229]=invert flag.
        // `extras` carries affiliate score in extras[0..2] when relevant.
        return _tokenURI(tokenId, data, extras);
    }

    function _tokenURI(
        uint256 tokenId,
        uint256 data,
        uint32[4] memory extras
    ) private view returns (string memory) {
        if ((data >> 128) == 0) revert("renderer:notTrophy");

        uint24 lvl = uint24((data >> 128) & 0xFFFFFF);
        uint16 exTr = _readExterminatedTrait(data);
        bool isAffiliate = (data & AFFILIATE_TROPHY_FLAG) != 0;
        bool isBaf = (data & BAF_TROPHY_FLAG) != 0;
        bool isExtermination = !isAffiliate && !isBaf;
        uint96 affiliateScore;
        if (isAffiliate) {
            affiliateScore =
                uint96(extras[0]) |
                (uint96(extras[1]) << 32) |
                (uint96(extras[2]) << 64);
        }
        bool invertFlag = (data & TROPHY_FLAG_INVERT) != 0;

        string memory lvlStr = (lvl == 0) ? "TBD" : uint256(lvl).toString();
        string memory trophyType;
        string memory trophyLabel;
        if (isAffiliate) {
            trophyType = "Affiliate";
            trophyLabel = "Affiliate Trophy";
        } else if (isBaf) {
            trophyType = "BAF";
            trophyLabel = "BAF Trophy";
        } else {
            trophyType = "Exterminator";
            trophyLabel = "Exterminator Trophy";
        }

        string memory desc = _buildDescription(
            exTr,
            lvl,
            lvlStr,
            trophyLabel,
            isAffiliate,
            isBaf,
            affiliateScore
        );

        bool includeTraitAttr;
        string memory traitType;
        string memory traitValue;
        if (exTr < 256 && isExtermination) {
            uint8 quadrant = uint8(exTr >> 6);
            uint8 raw = uint8(exTr & 0x3F);
            uint8 colorIdx = raw >> 3;
            uint8 symIdx = raw & 0x07;
            traitType = _quadrantTitle(quadrant);
            traitValue = _traitLabel(quadrant, colorIdx, symIdx);
            includeTraitAttr = true;
        }

        string memory attrs = _buildAttributes(
            lvlStr,
            trophyType,
            isAffiliate,
            affiliateScore,
            includeTraitAttr,
            traitType,
            traitValue
        );
        IIconRendererTrophy32Svg.SvgParams memory svgParams = IIconRendererTrophy32Svg.SvgParams({
            tokenId: tokenId,
            exterminatedTrait: exTr,
            isAffiliate: isAffiliate,
            isBaf: isBaf,
            lvl: lvl,
            invertFlag: invertFlag
        });
        string memory img = svgRenderer.trophySvg(svgParams);
        return _pack(img, lvl, desc, trophyType, attrs);
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

    function _pack(
        string memory svg,
        uint256 level,
        string memory desc,
        string memory trophyType,
        string memory attrs
    ) private pure returns (string memory) {
        string memory lvlStr = (level == 0) ? "TBD" : level.toString();
        string memory nm = string.concat("Degenerus Level ", lvlStr, " ", trophyType, " Trophy");

        string memory imgData = string.concat(
            "data:image/svg+xml;base64,",
            Base64.encode(bytes(svg))
        );

        string memory j = string.concat('{"name":"', nm);
        j = string.concat(j, '","description":"', desc);
        j = string.concat(j, '","image":"', imgData, '","attributes":');
        j = string.concat(j, attrs, "}");

        return string.concat("data:application/json;base64,", Base64.encode(bytes(j)));
    }

    function _buildDescription(
        uint16 exTr,
        uint24 lvl,
        string memory lvlStr,
        string memory trophyLabel,
        bool isAffiliate,
        bool isBaf,
        uint96 affiliateScore
    ) private pure returns (string memory desc) {
        if (exTr == 0xFFFF) {
            if (lvl == 0) {
                desc = string.concat("Reserved Degenerus ", trophyLabel, ".");
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
                lvlStr
            );
            if (affiliateScore != 0) {
                desc = string.concat(
                    desc,
                    " with an affiliate score of ",
                    _formatCoinAmount(affiliateScore),
                    "."
                );
            } else {
                desc = string.concat(desc, ".");
            }
        } else if (isBaf && exTr == BAF_TRAIT_SENTINEL) {
            desc = string.concat(
                "Awarded to the biggest coinflipper in the level ",
                lvlStr,
                " BAF."
            );
        } else {
            desc = string.concat("Awarded for level ", lvlStr);
            desc = string.concat(desc, " Extermination victory.");
        }
    }

    function _buildAttributes(
        string memory lvlStr,
        string memory trophyType,
        bool isAffiliate,
        uint96 affiliateScore,
        bool includeTraitAttr,
        string memory traitType,
        string memory traitValue
    ) private pure returns (string memory attrs) {
        attrs = string(
            abi.encodePacked(
                '[{"trait_type":"Level","value":"',
                lvlStr,
                '"},{"trait_type":"Trophy","value":"',
                trophyType,
                '"}'
            )
        );
        if (isAffiliate && affiliateScore != 0) {
            attrs = string(
                abi.encodePacked(
                    attrs,
                    ',{"trait_type":"Affiliate Score","value":"',
                    _formatCoinAmount(affiliateScore),
                    '"}'
                )
            );
        }
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
        attrs = string(abi.encodePacked(attrs, "]"));
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

        return string.concat(whole.toString(), ".", string(fracStr), " BURNIE");
    }

}
