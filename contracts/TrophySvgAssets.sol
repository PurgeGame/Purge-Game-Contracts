// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

/*
╔═══════════════════════════════════════════════════════════════════════════════════════════════════════╗
║                                        TrophySvgAssets                                                ║
║                       On-Chain SVG Animation Assets for Degenerus Trophies                            ║
╠═══════════════════════════════════════════════════════════════════════════════════════════════════════╣
║                                                                                                       ║
║  ARCHITECTURE OVERVIEW                                                                                ║
║  ─────────────────────                                                                                ║
║  TrophySvgAssets stores complex SVG markup for special trophy renders. Currently contains the         ║
║  animated coin flip used for BAF (Burn and Flip) trophies.                                           ║
║                                                                                                       ║
║  ┌──────────────────────────────────────────────────────────────────────────────────────────────────┐ ║
║  │                              BAF COIN FLIP ANIMATION                                             │ ║
║  │                                                                                                  │ ║
║  │   ┌─────────────┐     6 second loop     ┌─────────────┐                                         │ ║
║  │   │   Face A    │ ◄──────────────────── │   Face B    │                                         │ ║
║  │   │  (PURGE)    │ ──────────────────► │  (Ethereum) │                                         │ ║
║  │   │   Red/111   │    Y-axis flip        │  Green/111  │                                         │ ║
║  │   └─────────────┘                       └─────────────┘                                         │ ║
║  │                                                                                                  │ ║
║  │   Animation Phases (6s total):                                                                   │ ║
║  │   • 0.00-1.50s: Face A visible                                                                  │ ║
║  │   • 1.50-3.00s: Flip to Face B (scale Y: 1 → 0 → -1)                                           │ ║
║  │   • 3.00-4.50s: Face B visible                                                                  │ ║
║  │   • 4.50-6.00s: Flip to Face A (scale Y: -1 → 0 → 1)                                           │ ║
║  │                                                                                                  │ ║
║  │   Visual Structure:                                                                              │ ║
║  │   • Outer ring (color-coded: Red=Purge, Green=ETH)                                              │ ║
║  │   • Middle ring (dark #111)                                                                      │ ║
║  │   • Inner circle (white #fff)                                                                    │ ║
║  │   • Clipped symbol (Purge flame or Ethereum diamond)                                            │ ║
║  └──────────────────────────────────────────────────────────────────────────────────────────────────┘ ║
║                                                                                                       ║
║  DESIGN RATIONALE                                                                                     ║
║  ────────────────                                                                                     ║
║  1. Pure function returns static SVG string - no state, no gas for storage reads                    ║
║  2. SVG uses SMIL animation (native browser support, no JavaScript required)                        ║
║  3. Symbols and clip paths are defined as reusable <symbol> elements                                ║
║  4. Animation uses discrete keyTimes for crisp face switching                                       ║
║                                                                                                       ║
╠═══════════════════════════════════════════════════════════════════════════════════════════════════════╣
║  SECURITY CONSIDERATIONS                                                                              ║
║  ───────────────────────                                                                              ║
║                                                                                                       ║
║  1. PURE FUNCTION                                                                                     ║
║     • bafFlipSymbol() is pure - no state reads or external calls                                     ║
║     • Cannot be manipulated by contract state                                                        ║
║     • Returns deterministic output                                                                   ║
║                                                                                                       ║
║  2. NO ADMIN FUNCTIONS                                                                                ║
║     • Contract is completely stateless                                                               ║
║     • No owner, no upgrade path, no state variables                                                  ║
║                                                                                                       ║
║  3. SVG INJECTION SAFETY                                                                              ║
║     • All SVG content is hardcoded (no user input)                                                   ║
║     • No script tags or event handlers in the SVG                                                    ║
║     • Uses only path data and standard SVG elements                                                  ║
║                                                                                                       ║
║  4. GAS EFFICIENCY                                                                                    ║
║     • Pure function - free for off-chain calls                                                       ║
║     • String is compiled into contract bytecode                                                      ║
║     • No storage operations                                                                          ║
║                                                                                                       ║
╠═══════════════════════════════════════════════════════════════════════════════════════════════════════╣
║  TRUST ASSUMPTIONS                                                                                    ║
║  ─────────────────                                                                                    ║
║                                                                                                       ║
║  1. SVG content was reviewed at deployment time for safety                                           ║
║  2. Calling contracts (IconRendererTrophy32Svg) trust the returned SVG                               ║
║                                                                                                       ║
╚═══════════════════════════════════════════════════════════════════════════════════════════════════════╝
*/

// ─────────────────────────────────────────────────────────────────────────────
// INTERFACE
// ─────────────────────────────────────────────────────────────────────────────

/// @title ITrophySvgAssets
/// @notice Interface for accessing trophy SVG assets
/// @dev Implemented by TrophySvgAssets contract
interface ITrophySvgAssets {
    /// @notice Get the BAF (Burn and Flip) animated coin SVG
    /// @return The complete SVG markup for the flipping coin animation
    function bafFlipSymbol() external pure returns (string memory);
}

// ─────────────────────────────────────────────────────────────────────────────
// CONTRACT
// ─────────────────────────────────────────────────────────────────────────────

/// @title TrophySvgAssets
/// @notice On-chain storage for complex trophy SVG animations
/// @dev Stateless contract providing pure SVG string returns
contract TrophySvgAssets is ITrophySvgAssets {

    /// @notice Get the BAF (Burn and Flip) trophy animated coin SVG
    /// @dev Returns a complete SVG group (<g>) containing:
    ///      - Two coin face symbols (faceA = Purge/Red, faceB = Ethereum/Green)
    ///      - SMIL animation for Y-axis coin flip effect (6 second loop)
    ///      - Each face has: outer colored ring, dark middle ring, white core, clipped symbol
    /// @return The SVG markup string (designed for 130x130 viewBox, centered at 65,65)
    function bafFlipSymbol() external pure override returns (string memory) {
        // SVG structure:
        // <g>
        //   <defs>
        //     <symbol id="faceA">  - Purge coin face (red outer ring, flame symbol)
        //     <symbol id="faceB">  - Ethereum coin face (green outer ring, ETH diamond)
        //   </defs>
        //   <g transform="translate(65 65)">  - Center the animation
        //     <g id="flip">  - Y-scale animation container
        //       <use href="#faceA"> with opacity animation (visible 0-25%, 75-100%)
        //       <use href="#faceB"> with opacity animation (visible 25-75%)
        //       <animateTransform> Y-scale: 1→0→-1→0→1 over 6s
        //     </g>
        //   </g>
        // </g>
        return
            string(
                abi.encodePacked(
                    "<g><defs>",
                    // Face A: Purge coin (red outer ring, flame symbol)
                    // Clip path limits the flame to the inner white circle
                    "<symbol id='faceA' viewBox='0 0 130 130'><defs><clipPath id='fa-clip' clipPathUnits='userSpaceOnUse'><circle cx='65' cy='65' r='33'/></clipPath></defs>",
                    "<circle cx='65' cy='65' r='58' fill='#ed0e11'/><circle cx='65' cy='65' r='46' fill='#111'/><circle cx='65' cy='65' r='33' fill='#fff'/>",
                    // Flame symbol (Purge logo) - scaled and translated to fit
                    "<g clip-path='url(#fa-clip)'><g transform='translate(65 65) scale(0.096679) translate(-256 -212)'>",
                    "<path fill='#ed0e11' d='M437 0h74L357 152.48c-55.77 55.19-146.19 55.19-202 0L.94 0H75l117 115.83a91.1 91.1 0 0 0 127.91 0Z'/>",
                    "<path fill='#ed0e11' d='M74.05 424H0l155-153.42c55.77-55.19 146.19-55.19 202 0L512 424h-74L320 307.23a91.1 91.1 0 0 0-127.91 0Z'/>",
                    "</g></g></symbol>",
                    // Face B: Ethereum coin (green outer ring, ETH diamond)
                    "<symbol id='faceB' viewBox='0 0 130 130'><defs><clipPath id='fb-clip' clipPathUnits='userSpaceOnUse'><circle cx='65' cy='65' r='33'/></clipPath></defs>",
                    "<circle cx='65' cy='65' r='58' fill='#30D100'/><circle cx='65' cy='65' r='46' fill='#111'/><circle cx='65' cy='65' r='33' fill='#fff'/>",
                    // Ethereum diamond - scaled to fit the inner circle
                    "<g clip-path='url(#fb-clip)'><g transform='translate(65 65) scale(0.038762) translate(-392 -638)'><g fill-rule='nonzero'>",
                    "<polygon fill='#343434' points='392.07,0 383.5,29.11 383.5,873.74 392.07,882.29 784.13,650.54'/>",
                    "<polygon fill='#8C8C8C' points='392.07,0 -0,650.54 392.07,882.29 392.07,472.33'/>",
                    "<polygon fill='#3C3C3B' points='392.07,956.52 387.24,962.41 387.24,1263.28 392.07,1277.38 784.37,724.89'/>",
                    "<polygon fill='#8C8C8C' points='392.07,1277.38 392.07,956.52 -0,724.89'/>",
                    "<polygon fill='#141414' points='392.07,882.29 784.13,650.54 392.07,472.33'/>",
                    "<polygon fill='#393939' points='0,650.54 392.07,882.29 392.07,472.33'/>",
                    "</g></g></g></symbol>",
                    "</defs>",
                    // Animation container - centered at (65,65) for a 130x130 viewBox
                    "<g transform='translate(65 65)'><g id='flip' transform='scale(1 1)'><g transform='translate(-65 -65)'>",
                    // Face A with opacity animation (visible 0-25% and 75-100% of cycle)
                    "<use href='#faceA'><animate attributeName='opacity' values='1;1;0;0;1;1' keyTimes='0;0.2499;0.25;0.75;0.7501;1' calcMode='discrete' dur='6s' repeatCount='indefinite'/></use>",
                    // Face B (mirrored on Y) with inverse opacity animation (visible 25-75% of cycle)
                    "<g transform='translate(0 130) scale(1 -1)'><use href='#faceB'><animate attributeName='opacity' values='0;0;1;1;0;0' keyTimes='0;0.2499;0.25;0.75;0.7501;1' calcMode='discrete' dur='6s' repeatCount='indefinite'/></use></g>",
                    "</g>",
                    // Y-scale animation: creates the coin flip illusion
                    // 1→0: coin appears to rotate away
                    // 0→-1: coin shows back face
                    // -1→0→1: coin rotates back to front
                    "<animateTransform attributeName='transform' type='scale' values='1 1;1 0;1 -1;1 0;1 1' keyTimes='0;0.25;0.5;0.75;1' dur='6s' repeatCount='indefinite'/></g></g></g>"
                )
            );
    }
}
