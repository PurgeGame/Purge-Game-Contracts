// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import "@openzeppelin/contracts/utils/Strings.sol";

/// @title RendererLibrary
/// @notice Shared utilities for Degenerus renderer contracts
/// @dev Pure functions for color conversion, math helpers, and string formatting
library RendererLibrary {
    using Strings for uint256;

    // ---------------------------------------------------------------------
    // CONSTANTS
    // ---------------------------------------------------------------------

    /// @dev Ratio constants for ring sizing (1e6 scale)
    uint32 internal constant RATIO_MID_1e6 = 780_000;
    uint32 internal constant RATIO_IN_1e6 = 620_000;
    uint16 internal constant ICON_VB = 512;

    // ---------------------------------------------------------------------
    // COLOR UTILITIES
    // ---------------------------------------------------------------------

    /// @notice Get palette color by index
    function paletteColorRGB(uint8 idx) internal pure returns (uint24) {
        if (idx == 0) return 0xf409cd; // Pink
        if (idx == 1) return 0x7c2bff; // Purple
        if (idx == 2) return 0x30d100; // Green
        if (idx == 3) return 0xed0e11; // Red
        if (idx == 4) return 0x1317f7; // Blue
        if (idx == 5) return 0xf7931a; // Orange
        if (idx == 6) return 0x5e5e5e; // Silver
        return 0xab8d3f; // Gold
    }

    /// @notice Get variant bias for palette color
    function variantBias(uint8 idx) internal pure returns (int16) {
        if (idx == 0) return -14;
        if (idx == 1) return -6;
        if (idx == 2) return 12;
        if (idx == 3) return -10;
        if (idx == 4) return 14;
        if (idx == 5) return 6;
        if (idx == 6) return -8;
        return 10;
    }

    /// @notice Human-readable color title
    function colorTitle(uint8 idx) internal pure returns (string memory) {
        if (idx == 0) return "Pink";
        if (idx == 1) return "Purple";
        if (idx == 2) return "Green";
        if (idx == 3) return "Red";
        if (idx == 4) return "Blue";
        if (idx == 5) return "Orange";
        if (idx == 6) return "Silver";
        return "Gold";
    }

    /// @notice Human-readable quadrant title
    function quadrantTitle(uint8 idx) internal pure returns (string memory) {
        if (idx == 0) return "Crypto";
        if (idx == 1) return "Zodiac";
        if (idx == 2) return "Cards";
        return "Dice";
    }

    /// @notice Convert RGB to hex string
    function rgbToHex(uint24 rgb) internal pure returns (string memory) {
        uint8 r = uint8(rgb >> 16);
        uint8 g = uint8(rgb >> 8);
        uint8 b = uint8(rgb);
        bytes memory buf = new bytes(7);
        buf[0] = "#";
        buf[1] = hexChar(r >> 4);
        buf[2] = hexChar(r & 0x0F);
        buf[3] = hexChar(g >> 4);
        buf[4] = hexChar(g & 0x0F);
        buf[5] = hexChar(b >> 4);
        buf[6] = hexChar(b & 0x0F);
        return string(buf);
    }

    /// @notice Convert nibble to hex character
    function hexChar(uint8 nibble) internal pure returns (bytes1) {
        uint8 v = nibble & 0x0F;
        return bytes1(v + (v < 10 ? 48 : 87));
    }

    // ---------------------------------------------------------------------
    // FIXED-POINT MATH (1e6 SCALE)
    // ---------------------------------------------------------------------

    /// @notice Format 1e6 fixed-point unsigned value as string
    function dec6(uint256 x) internal pure returns (string memory) {
        uint256 i = x / 1_000_000;
        uint256 f = x % 1_000_000;
        return string(abi.encodePacked(i.toString(), ".", pad6(uint32(f))));
    }

    /// @notice Format 1e6 fixed-point signed value as string
    function dec6s(int256 x) internal pure returns (string memory) {
        if (x < 0) {
            uint256 y = uint256(-x);
            return string(abi.encodePacked("-", dec6(y)));
        }
        return dec6(uint256(x));
    }

    /// @notice Zero-pad 6-digit fractional part
    function pad6(uint32 f) internal pure returns (string memory) {
        bytes memory b = new bytes(6);
        for (uint256 k; k < 6; ++k) {
            b[5 - k] = bytes1(uint8(48 + (f % 10)));
            f /= 10;
        }
        return string(b);
    }

    /// @notice SVG matrix transform from 1e6-scale parameters
    function mat6(uint32 s1e6, int256 tx1e6, int256 ty1e6) internal pure returns (string memory) {
        string memory s = dec6(uint256(s1e6));
        string memory txn = dec6s(tx1e6);
        string memory tyn = dec6s(ty1e6);
        return string(abi.encodePacked("matrix(", s, " 0 0 ", s, " ", txn, " ", tyn, ")"));
    }

    /// @notice Convert int16 to string (for SVG coordinates)
    function intToString(int16 v) internal pure returns (string memory) {
        int256 x = v;
        if (x >= 0) return uint256(x).toString();
        return string.concat("-", uint256(-x).toString());
    }

    // ---------------------------------------------------------------------
    // SVG HELPERS
    // ---------------------------------------------------------------------

    /// @notice SVG header with inversion filter and outer square
    function svgHeader(string memory borderColor, string memory squareFill) internal pure returns (string memory) {
        return
            string(
                abi.encodePacked(
                    '<svg xmlns="http://www.w3.org/2000/svg" viewBox="-60 -60 120 120">',
                    '<defs><filter id="inv" color-interpolation-filters="sRGB">',
                    '<feColorMatrix type="matrix" values="',
                    "-1 0 0 0 1 ",
                    "0 -1 0 0 1 ",
                    "0 0 -1 0 1 ",
                    "0 0 0  1 0",
                    '"/></filter></defs>',
                    '<rect x="-50" y="-50" width="100" height="100" rx="12" fill="',
                    squareFill,
                    '" stroke="',
                    borderColor,
                    '" stroke-width="2"/>'
                )
            );
    }

    /// @notice SVG footer (closing tag)
    function svgFooter() internal pure returns (string memory) {
        return "</svg>";
    }

    /// @notice Draw three concentric circles (rings)
    function rings(
        string memory outerColor,
        string memory midColor,
        string memory innerColor,
        uint32 rOut,
        uint32 rMid,
        uint32 rIn,
        int16 cx,
        int16 cy
    ) internal pure returns (string memory) {
        string memory cxs = intToString(cx);
        string memory cys = intToString(cy);
        return
            string(
                abi.encodePacked(
                    '<circle cx="',
                    cxs,
                    '" cy="',
                    cys,
                    '" r="',
                    uint256(rOut).toString(),
                    '" fill="',
                    outerColor,
                    '"/>',
                    '<circle cx="',
                    cxs,
                    '" cy="',
                    cys,
                    '" r="',
                    uint256(rMid).toString(),
                    '" fill="',
                    midColor,
                    '"/>',
                    '<circle cx="',
                    cxs,
                    '" cy="',
                    cys,
                    '" r="',
                    uint256(rIn).toString(),
                    '" fill="',
                    innerColor,
                    '"/>'
                )
            );
    }
}
