// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

/*
╔═══════════════════════════════════════════════════════════════════════════════════════════════════════╗
║                                      IconRendererTrophy32                                             ║
║                       ERC721 Metadata Renderer for Degenerus Trophy Tokens                            ║
╠═══════════════════════════════════════════════════════════════════════════════════════════════════════╣
║                                                                                                       ║
║  ARCHITECTURE OVERVIEW                                                                                ║
║  ─────────────────────                                                                                ║
║  IconRendererTrophy32 generates complete ERC721 metadata (JSON + base64 SVG) for trophy tokens.       ║
║  It orchestrates the rendering pipeline by delegating SVG generation to IconRendererTrophy32Svg.      ║
║                                                                                                       ║
║  ┌──────────────────────────────────────────────────────────────────────────────────────────────────┐ ║
║  │                              METADATA GENERATION FLOW                                            │ ║
║  │                                                                                                  │ ║
║  │   DegenerusTrophies.tokenURI(tokenId)                                                           │  ║
║  │          │                                                                                       │ ║
║  │          ├─► Read _trophyData[tokenId] ─── Packed trophy data (level, trait, flags)             │  ║
║  │          │                                                                                       │ ║
║  │          ▼                                                                                       │ ║
║  │   IconRendererTrophy32.tokenURI(tokenId, data, extras)  ◄─── THIS CONTRACT                      │  ║
║  │          │                                                                                       │ ║
║  │          ├─► Parse trophy type (Exterminator/Affiliate/BAF)                                     │  ║
║  │          ├─► Build description string                                                            │ ║
║  │          ├─► Build attributes JSON array                                                         │ ║
║  │          ├─► Call svgRenderer.trophySvg() for image                                             │  ║
║  │          │                                                                                       │ ║
║  │          ▼                                                                                       │ ║
║  │   Return: data:application/json;base64,{...}                                                    │  ║
║  │          │                                                                                       │ ║
║  │          └─► "image": "data:image/svg+xml;base64,..."                                           │  ║
║  └──────────────────────────────────────────────────────────────────────────────────────────────────┘ ║
║                                                                                                       ║
║  ┌──────────────────────────────────────────────────────────────────────────────────────────────────┐ ║
║  │                              TROPHY DATA BIT LAYOUT (from DegenerusTrophies)                    │  ║
║  │                                                                                                  │ ║
║  │   bits [0-95]:    Affiliate score or exterminator winnings (uint96, wei)                         │ ║
║  │   bits [128-151]: Level (uint24)                                                                │  ║
║  │   bits [152-167]: Exterminated trait (uint16) or sentinel                                       │  ║
║  │   bit 201:        AFFILIATE_TROPHY_FLAG                                                         │  ║
║  │   bit 203:        BAF_TROPHY_FLAG                                                               │  ║
║  │   bit 229:        TROPHY_FLAG_INVERT (visual inversion)                                         │  ║
║  │                                                                                                  │ ║
║  │   Sentinel Values:                                                                               │ ║
║  │   • 0xFFFE - Top affiliate trophy                                                               │  ║
║  │   • 0xFFFA - BAF trophy                                                                         │  ║
║  └──────────────────────────────────────────────────────────────────────────────────────────────────┘ ║
║                                                                                                       ║
║  ┌──────────────────────────────────────────────────────────────────────────────────────────────────┐ ║
║  │                              OUTPUT FORMAT                                                       │ ║
║  │                                                                                                  │ ║
║  │   {                                                                                              │ ║
║  │     "name": "Degenerus Level 42 Exterminator Trophy",                                           │  ║
║  │     "description": "Awarded for level 42 Extermination victory.",                               │  ║
║  │     "image": "data:image/svg+xml;base64,...",                                                   │  ║
║  │     "attributes": [                                                                              │ ║
║  │       {"trait_type": "Level", "value": "42"},                                                   │  ║
║  │       {"trait_type": "Trophy", "value": "Exterminator"},                                        │  ║
║  │       {"trait_type": "Extermination Winnings", "value": "1.2 ETH"},                            │   ║
║  │       {"trait_type": "Crypto", "value": "Pink Bitcoin"}  // if applicable                       │  ║
║  │     ]                                                                                            │ ║
║  │   }                                                                                              │ ║
║  └──────────────────────────────────────────────────────────────────────────────────────────────────┘ ║
║                                                                                                       ║
╠═══════════════════════════════════════════════════════════════════════════════════════════════════════╣
║  SECURITY CONSIDERATIONS                                                                              ║
║  ───────────────────────                                                                              ║
║                                                                                                       ║
║  1. VIEW-ONLY                                                                                         ║
║     • tokenURI() is a view function - no state changes                                                ║
║     • Safe to call externally for metadata generation                                                 ║
║                                                                                                       ║
║  2. ACCESS CONTROL                                                                                    ║
║     • Constructor wiring via DeployConstants (no admin setters)                                       ║
║     • Color customization proxied to registry with msg.sender verification                            ║
║                                                                                                       ║
║  3. INPUT VALIDATION                                                                                  ║
║     • Reverts if data indicates non-trophy (bits 128+ must be set)                                    ║
║     • Handles all sentinel values explicitly                                                          ║
║                                                                                                       ║
╠═══════════════════════════════════════════════════════════════════════════════════════════════════════╣
║  TRUST ASSUMPTIONS                                                                                    ║
║  ─────────────────                                                                                    ║
║                                                                                                       ║
║  1. DegenerusTrophies provides valid packed trophy data                                               ║
║  2. IconRendererTrophy32Svg generates safe SVG content                                                ║
║  3. IconColorRegistry validates hex colors correctly                                                  ║
║  4. Icons32Data provides valid symbol names                                                           ║
║                                                                                                       ║
╚═══════════════════════════════════════════════════════════════════════════════════════════════════════╝*/

import "@openzeppelin/contracts/utils/Base64.sol";
import "@openzeppelin/contracts/utils/Strings.sol";
import {DeployConstants} from "./DeployConstants.sol";
import "./interfaces/IconRendererTypes.sol";
import {IIconRendererTrophy32Svg} from "./IconRendererTrophy32Svg.sol";
import {RendererLibrary} from "./libraries/RendererLibrary.sol";

/// @title IconRendererTrophy32
/// @notice ERC721 metadata renderer for Degenerus trophy tokens
/// @dev Generates JSON metadata with base64-encoded SVG images for trophy NFTs
contract IconRendererTrophy32 {
    using Strings for uint256;

    // ─────────────────────────────────────────────────────────────────────
    // CONSTANTS
    // ─────────────────────────────────────────────────────────────────────

    /// @dev Flag identifying affiliate trophy type (bit 201 in packed data)
    uint256 private constant AFFILIATE_TROPHY_FLAG = uint256(1) << 201;

    /// @dev Flag identifying BAF trophy type (bit 203 in packed data)
    uint256 private constant BAF_TROPHY_FLAG = uint256(1) << 203;

    /// @dev Flag for visual inversion effect (bit 229 in packed data)
    uint256 private constant TROPHY_FLAG_INVERT = uint256(1) << 229;

    /// @dev Sentinel value in trait field indicating BAF trophy
    uint16 private constant BAF_TRAIT_SENTINEL = 0xFFFA;

    // ─────────────────────────────────────────────────────────────────────
    // CONSTANTS & WIRING
    // ─────────────────────────────────────────────────────────────────────

    /// @dev Icon data source for symbol names
    IIcons32 private constant icons = IIcons32(DeployConstants.ICONS_32);

    /// @dev Color customization registry
    IColorRegistry private constant registry = IColorRegistry(DeployConstants.ICON_COLOR_REGISTRY);

    /// @dev SVG generation engine
    IIconRendererTrophy32Svg private constant svgRenderer =
        IIconRendererTrophy32Svg(DeployConstants.RENDERER_TROPHY_SVG);

    /// @dev Trophy NFT contract
    IERC721Lite private constant nft = IERC721Lite(DeployConstants.TROPHIES);

    // ─────────────────────────────────────────────────────────────────────
    // ERRORS
    // ─────────────────────────────────────────────────────────────────────

    /// @dev Generic error for unauthorized access or invalid state
    error E();

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

    function tokenURI(
        uint256 tokenId,
        uint256 data,
        uint32[4] calldata extras
    ) external view returns (string memory) {
        // `data` carries the packed trophy word emitted by the game:
        // bits [167:152]=exterminated trait (0..255 or sentinel 0xFFFE/0xFFFA), [151:128]=level,
        // [203:201]=trophy type flags, [229]=invert flag.
        // `extras` carries affiliate score or exterminator winnings in extras[0..2] when relevant.
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
        uint96 extraValue =
            uint96(extras[0]) |
            (uint96(extras[1]) << 32) |
            (uint96(extras[2]) << 64);
        uint96 affiliateScore = isAffiliate ? extraValue : 0;
        uint96 exterminationWinnings = isExtermination ? extraValue : 0;
        bool invertFlag = (data & TROPHY_FLAG_INVERT) != 0;

        string memory lvlStr = (lvl == 0) ? "TBD" : uint256(lvl).toString();
        string memory trophyType;
        if (isAffiliate) {
            trophyType = "Affiliate";
        } else if (isBaf) {
            trophyType = "BAF";
        } else {
            trophyType = "Exterminator";
        }

        string memory desc = _buildDescription(
            exTr,
            lvlStr,
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
            traitType = RendererLibrary.quadrantTitle(quadrant);
            traitValue = _traitLabel(quadrant, colorIdx, symIdx);
            includeTraitAttr = true;
        }

        string memory attrs = _buildAttributes(
            lvlStr,
            trophyType,
            isAffiliate,
            affiliateScore,
            isExtermination,
            exterminationWinnings,
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
        if (ex16 == 0xFFFE || ex16 == BAF_TRAIT_SENTINEL) return ex16;
        return uint16(uint8(ex16));
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

        return (uint256(symbolIdx) + 1).toString();
    }

    function _traitLabel(
        uint8 quadrant,
        uint8 colorIdx,
        uint8 symbolIdx
    ) private view returns (string memory) {
        return
            string.concat(
                RendererLibrary.colorTitle(colorIdx),
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
        string memory lvlStr,
        bool isAffiliate,
        bool isBaf,
        uint96 affiliateScore
    ) private pure returns (string memory desc) {
        if (isAffiliate && exTr == 0xFFFE) {
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
        bool isExtermination,
        uint96 exterminationWinnings,
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
        if (isExtermination && exterminationWinnings != 0) {
            attrs = string(
                abi.encodePacked(
                    attrs,
                    ',{"trait_type":"Extermination Winnings","value":"',
                    _formatEthAmount(exterminationWinnings),
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

    function _formatEthAmount(uint256 amount) private pure returns (string memory) {
        uint256 scaled = amount / 1e17;
        uint256 whole = scaled / 10;
        uint8 frac = uint8(scaled - (whole * 10));
        return string(abi.encodePacked(whole.toString(), ".", bytes1(uint8(48 + frac)), " ETH"));
    }

}
