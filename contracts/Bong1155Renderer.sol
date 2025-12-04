// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import "@openzeppelin/contracts/utils/Base64.sol";
import "@openzeppelin/contracts/utils/Strings.sol";
import "./interfaces/IconRendererTypes.sol";

interface IPurgeBong1155Renderer {
    function bongURI(
        uint256 id,
        uint256 supply,
        bool locked,
        uint256 principalSupply,
        bool funded
    ) external view returns (string memory);
}

interface IPurgeBongsOwner {
    function owner() external view returns (address);
}

/**
 * @title Bong1155Renderer
 * @notice Renders ERC1155 bond/bong metadata using the legacy badge (no square background).
 */
contract Bong1155Renderer is IPurgeBong1155Renderer {
    using Strings for uint256;

    error Unauthorized();

    IColorRegistry public immutable registry;
    address public immutable bongs;

    string private constant _ETH_PATH =
        "<g id='ico'><g fill-rule='nonzero'>"
        "<polygon fill='#343434' points='392.07,0 383.5,29.11 383.5,873.74 392.07,882.29 784.13,650.54'/>"
        "<polygon fill='#8C8C8C' points='392.07,0 0,650.54 392.07,882.29 392.07,472.33'/>"
        "<polygon fill='#3C3C3B' points='392.07,956.52 387.24,962.41 387.24,1263.28 392.07,1277.38 784.37,724.89'/>"
        "<polygon fill='#8C8C8C' points='392.07,1277.38 392.07,956.52 0,724.89'/>"
        "<polygon fill='#141414' points='392.07,882.29 784.13,650.54 392.07,472.33'/>"
        "<polygon fill='#393939' points='0,650.54 392.07,882.29 392.07,472.33'/>"
        "</g></g>";

    string private constant _FLAME_D =
        "M431.48,504.54c-5.24-10.41-12.36-18.75-21.62-24.98-6.91-4.65-14.21-8.76-21.56-12.69-12.95-6.93-26.54-12.66-38.78-20.91-19.24-12.96-31.77-30.57-36.56-53.37-3.66-17.46-2.13-34.69,2.89-51.71,4.01-13.6,10.35-26.15,16.95-38.6,7.71-14.54,15.86-28.87,21.81-44.28,3.39-8.77,5.94-17.76,7.2-27.11,0,3.69,.24,7.4-.04,11.07-1.48,19.17-7.44,37.4-11.94,55.94-3.57,14.72-6.92,29.46-6.53,44.78,.46,18.05,6.14,34.08,19.02,46.86,9.15,9.09,19.11,17.38,28.83,25.89,8.46,7.41,17.32,14.37,24.28,23.36,7.48,9.66,11.24,20.77,13.22,32.63,.32,1.93,.63,3.86,1.02,6.22,4.22-6.71,8.24-12.99,12.15-19.34,2.97-4.81,5.94-9.63,8.66-14.58,8.98-16.34,8-31.83-4.22-46.28-6.7-7.92-13.41-15.82-20.01-23.82-4.83-5.86-9.23-12.01-10.54-19.77-1.49-8.9,.02-17.43,3.25-25.74,3.45-8.89,7.2-17.67,10.28-26.69,3.52-10.29,5.13-21.02,5.5-31.89,.14-4.19-.28-8.39-.74-12.61-3.91,16.79-14.43,29.92-23.51,43.8-7.15,10.93-14.4,21.79-19.47,33.9-3.78,9.03-6.23,18.4-6.71,28.2-.59,11.95,2.26,23.17,8.54,33.28,3.76,6.07,8.44,11.56,12.72,17.31,.36,.49,.75,.96,1.13,1.44l-.39,.49c-2.78-2-5.65-3.89-8.33-6.02-12.9-10.23-23.86-22.09-30.76-37.27-5.35-11.77-6.76-24.15-5.31-36.9,2.41-21.24,11.63-39.66,23.7-56.9,7.63-10.9,15.43-21.7,22.75-32.81,7.31-11.11,11.78-23.44,13.48-36.65,1.58-12.32,.38-24.49-2.45-36.55-2.43-10.38-6-20.36-10.24-30.13l.47-.43c3.18,3.14,6.6,6.08,9.51,9.45,16.8,19.42,27.96,41.68,33.29,66.83,3.12,14.73,3.44,29.56,1.84,44.51-1.06,9.89-2.25,19.82-2.49,29.75-.27,11.05,3.86,21.06,9.7,30.3,5.19,8.22,10.8,16.18,15.83,24.48,7.27,12.01,11.77,25.09,13,39.09,1.06,12.19-1.32,23.97-5.7,35.33-4.68,12.14-11.42,23.07-19.75,33.04-.28,.34-.5,.73-.98,1.42,.58-.2,.81-.21,.94-.33,13.86-12.66,25.56-26.91,32.56-44.59,4.2-10.61,4.64-21.64,2.92-32.71-1.55-9.97-3.84-19.83-5.69-29.75-1.3-6.98-1.62-14.03-.96-21.16,2.41,11.44,9.46,20.38,15.71,29.77,4.45,6.69,8.7,13.49,10.95,21.34l.78-.11c-.52-5.46-.86-10.95-1.6-16.38-1.57-11.65-6.36-22.27-10.97-32.92-5.36-12.4-10.87-24.73-14.2-37.9-4.6-18.21-6.04-36.6-3.4-55.24,.17-1.22,.27-2.44,.62-3.65,3.31,18.57,10.98,35.38,19.91,51.69,5.97,10.9,12.18,21.66,18.06,32.61,7.08,13.2,12.26,27.14,14.41,42.02,4.35,30.04-2.87,56.63-24.51,78.55-9.21,9.33-20.5,15.79-31.95,21.98-9.44,5.1-18.91,10.16-28.11,15.67-11.91,7.14-21.38,16.78-27.83,29.82Z";

    constructor(address registry_, address bongs_) {
        registry = IColorRegistry(registry_);
        bongs = bongs_;
    }

    function setLevelColors(
        uint256 id,
        string calldata outline,
        string calldata flame,
        string calldata diamond
    ) external {
        if (msg.sender != IPurgeBongsOwner(bongs).owner()) revert Unauthorized();
        uint256[] memory ids = new uint256[](1);
        ids[0] = id;
        bool ok = registry.setCustomColorsForMany(
            msg.sender,
            bongs,
            ids,
            outline,
            flame,
            diamond,
            "",
            0
        );
        if (!ok) revert Unauthorized();
    }

    function bongURI(
        uint256 id,
        uint256 supply,
        bool locked,
        uint256 principalSupply,
        bool funded
    ) external view returns (string memory) {
        (string memory outline, string memory diamond, string[3] memory flames) = _getColors(id);
        uint256 chanceBps = principalSupply >= 0.5 ether ? 5000 : (principalSupply * 10_000) / 1 ether;
        string memory image = _generateSvg(chanceBps, outline, diamond, flames);

        string memory name_ = string.concat("Purge Bong L", id.toString());
        string memory desc = "Fungible Purge bong (ERC1155) representing a claim on level-based bong payouts.";
        string memory attributes = _attributes(id, supply, principalSupply, locked, funded, chanceBps);

        return _packJson(name_, desc, image, attributes);
    }

    function _packJson(string memory name_, string memory desc, string memory image, string memory attributes) private pure returns (string memory) {
        bytes memory data = abi.encodePacked(
            '{"name":"', name_,
            '","description":"', desc,
            '","image":"data:image/svg+xml;base64,', Base64.encode(bytes(image)),
            '","attributes":[', attributes, "]}"
        );
        return string.concat("data:application/json;base64,", Base64.encode(data));
    }

    function _attributes(
        uint256 id,
        uint256 supply,
        uint256 principalSupply,
        bool locked,
        bool funded,
        uint256 chanceBps
    ) private pure returns (string memory) {
        return string.concat(
            _attr("Level", id.toString(), true),
            _attr("Status", locked ? "Locked" : "Liquid", true),
            _attr("Fully Funded", funded ? "Yes" : "No", true),
            _attr("Outstanding Principal", _formatEth(supply), true),
            _attr("Minted Principal", _formatEth(principalSupply), true),
            _attr("Chance", _formatBps(chanceBps), false)
        );
    }

    function _attr(string memory t, string memory v, bool tail) private pure returns (string memory) {
        return string.concat('{"trait_type":"', t, '","value":"', v, '"}', tail ? "," : "");
    }

    function _formatEth(uint256 weiVal) private pure returns (string memory) {
        uint256 whole = weiVal / 1 ether;
        uint256 frac = (weiVal % 1 ether) / 1e15; // 3 decimals
        if (frac == 0) return string.concat(whole.toString(), " ETH");
        string memory fracStr = frac < 10 ? string.concat("00", frac.toString()) : (frac < 100 ? string.concat("0", frac.toString()) : frac.toString());
        return string.concat(whole.toString(), ".", fracStr, " ETH");
    }

    function _formatBps(uint256 bps) private pure returns (string memory) {
        uint256 pctInt = bps / 100;
        uint256 pctFrac = bps % 100;
        string memory fracStr = pctFrac < 10 ? string.concat("0", pctFrac.toString()) : pctFrac.toString();
        return string.concat(pctInt.toString(), ".", fracStr, "%");
    }

    function _getColors(uint256 tokenId) private view returns (string memory outline, string memory diamond, string[3] memory flames) {
        outline = _outlineColor(tokenId); // Border
        diamond = _greenShade(tokenId); // Diamond

        uint256 baseIdx = tokenId == 0 ? 0 : (tokenId - 1) % 10;
        flames[0] = _flamePalette(baseIdx);
        flames[1] = _flamePalette(baseIdx);
        flames[2] = _flamePalette((baseIdx + 1) % 10);

        if (bongs == address(0)) return (outline, diamond, flames);

        string memory c = registry.tokenColor(bongs, tokenId, 0);
        if (bytes(c).length != 0) outline = c;
        c = registry.tokenColor(bongs, tokenId, 1);
        if (bytes(c).length != 0) {
            flames[0] = c;
            flames[1] = c;
            flames[2] = c;
        }
        c = registry.tokenColor(bongs, tokenId, 2);
        if (bytes(c).length != 0) diamond = c;

        return (outline, diamond, flames);
    }

    function _outlineColor(uint256 tokenId) private pure returns (string memory) {
        uint256 h = _rand(tokenId, "bong-outline");
        uint8 bucket = uint8(h % 6);
        uint16 baseHue = bucket == 0
            ? 0
            : bucket == 1
                ? 25
                : bucket == 2
                    ? 300
                    : bucket == 3
                        ? 260
                        : bucket == 4
                            ? 210
                            : uint16(340);
        uint16 hue = uint16((baseHue + (h % 15)) % 360);
        uint8 sat = 160 + uint8((h >> 8) % 80); // 160-239
        uint8 val = 150 + uint8((h >> 16) % 90); // 150-239
        return _rgbHex(_hsvToRgb(hue, sat, val));
    }

    function _greenShade(uint256 tokenId) private pure returns (string memory) {
        uint256 h = _rand(tokenId, "bong-green");
        uint16 hue = 105 + uint16(h % 70); // 105-174 (greens)
        uint8 sat = 180 + uint8((h >> 8) % 70); // 180-249
        uint8 val = 170 + uint8((h >> 16) % 70); // 170-239
        return _rgbHex(_hsvToRgb(hue, sat, val));
    }

    function _flamePalette(uint256 idx) private pure returns (string memory) {
        // 0-9 red -> blue/violet spectrum
        if (idx == 0) return "#ff2b2b";
        if (idx == 1) return "#ff6a2b";
        if (idx == 2) return "#ffb52b";
        if (idx == 3) return "#ffd52b";
        if (idx == 4) return "#c8ff2b";
        if (idx == 5) return "#6bff6b";
        if (idx == 6) return "#2bffda";
        if (idx == 7) return "#2b8aff";
        if (idx == 8) return "#6b2bff";
        return "#b62bff"; // idx 9
    }

    function _generateSvg(uint256 chanceBps, string memory outline, string memory diamond, string[3] memory flames) private pure returns (string memory) {
        uint256 scaleInt = 7;
        if (chanceBps > 20) {
            uint256 c = chanceBps > 500 ? 500 : chanceBps;
            scaleInt = 7 + ((c - 20) * 31) / 480;
        }

        uint256 txVal = 256 - (256 * scaleInt) / 100;
        uint256 ty = 250 - (256 * scaleInt) / 100;
        uint256 fOff = (38 - scaleInt) * 15 / 10;
        uint256 xOff = (38 - scaleInt);

        string memory s = scaleInt.toString();
        if (scaleInt < 10) s = string.concat("0", s);
        string memory scaleStr = string.concat("0.", s);

        string memory transform = string.concat(
            "matrix(", scaleStr, " 0 0 ", scaleStr, " ", txVal.toString(), " ", ty.toString(), ")"
        );

        string memory flamesSvg;
        if (chanceBps <= 150 || chanceBps >= 300) {
            flamesSvg = string.concat(
                "<use href='#flame-icon' x='256' y='", (330 - fOff).toString(), "' width='180' height='180' transform='translate(-90, -90)' fill='", flames[0], "'/>"
            );
        }
        if (chanceBps > 150) {
            uint256 outerY = 300;
            uint256 outerXBase = 206;
            uint256 outerXBaseRight = 306;
            if (chanceBps < 300) {
                outerY = 310;
                outerXBase = 211;
                outerXBaseRight = 301;
            }
            flamesSvg = string.concat(
                flamesSvg,
                "<use href='#flame-icon' x='", (outerXBase + xOff).toString(), "' y='", (outerY - fOff).toString(), "' width='180' height='180' transform='translate(-90, -90)' fill='", flames[1], "'/>",
                "<use href='#flame-icon' x='", (outerXBaseRight - xOff).toString(), "' y='", (outerY - fOff).toString(), "' width='180' height='180' transform='translate(-90, -90)' fill='", flames[2], "'/>"
            );
        }

        return string.concat(
            "<svg xmlns='http://www.w3.org/2000/svg' viewBox='0 0 512 512'>",
            "<defs><clipPath id='flame-clip'><circle cx='0' cy='0' r='27'/></clipPath>",
            "<symbol id='ico' viewBox='0 0 784.37 1277.38'>", _ETH_PATH, "</symbol>",
            "<symbol id='flame-icon' viewBox='-60 -60 120 120'><g clip-path='url(#flame-clip)'>",
            "<path transform='matrix(0.13 0 0 0.13 -56 -41)' d='", _FLAME_D, "'/></g></symbol></defs>",
            "<g transform='", transform, "'>",
            "<circle cx='256' cy='256' r='256' fill='", outline, "'/>",
            "<circle cx='256' cy='256' r='230' fill='", diamond, "'/>",
            "<use href='#ico' x='128' y='128' width='256' height='256'/>",
            flamesSvg,
            "</g></svg>"
        );
    }

    function _rand(uint256 tokenId, string memory salt) private pure returns (uint256) {
        return uint256(keccak256(abi.encodePacked(tokenId, salt)));
    }

    function _hsvToRgb(uint16 h, uint8 s, uint8 v) private pure returns (uint8[3] memory) {
        uint8 region = uint8(h / 60);
        uint16 remainder = (h - (region * 60)) * 256 / 60;

        uint256 p = (uint256(v) * (256 - s)) >> 8;
        uint256 q = (uint256(v) * (256 - ((uint256(s) * remainder) >> 8))) >> 8;
        uint256 t = (uint256(v) * (256 - ((uint256(s) * (256 - remainder)) >> 8))) >> 8;

        if (region == 0) return [v, uint8(t), uint8(p)];
        if (region == 1) return [uint8(q), v, uint8(p)];
        if (region == 2) return [uint8(p), v, uint8(t)];
        if (region == 3) return [uint8(p), uint8(q), v];
        if (region == 4) return [uint8(t), uint8(p), v];
        return [v, uint8(p), uint8(q)];
    }

    function _rgbHex(uint8[3] memory rgb) private pure returns (string memory) {
        bytes memory out = new bytes(7);
        out[0] = "#";
        for (uint256 i; i < 3; ++i) {
            uint8 b = rgb[i];
            out[1 + i * 2] = _hexChar(b >> 4);
            out[2 + i * 2] = _hexChar(b & 0x0f);
        }
        return string(out);
    }

    function _hexChar(uint8 nibble) private pure returns (bytes1) {
        return nibble < 10 ? bytes1(nibble + 0x30) : bytes1(nibble + 0x57);
    }
}
