// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

interface ITrophySvgAssets {
    function bafFlipSymbol() external pure returns (string memory);
}

contract TrophySvgAssets is ITrophySvgAssets {
    function bafFlipSymbol() external pure override returns (string memory) {
        return
            string(
                abi.encodePacked(
                    "<g><defs>",
                    "<symbol id='faceA' viewBox='0 0 130 130'><defs><clipPath id='fa-clip' clipPathUnits='userSpaceOnUse'><circle cx='65' cy='65' r='33'/></clipPath></defs>",
                    "<circle cx='65' cy='65' r='58' fill='#ed0e11'/><circle cx='65' cy='65' r='46' fill='#111'/><circle cx='65' cy='65' r='33' fill='#fff'/>",
                    "<g clip-path='url(#fa-clip)'><g transform='translate(65 65) scale(0.096679) translate(-256 -212)'>",
                    "<path fill='#ed0e11' d='M437 0h74L357 152.48c-55.77 55.19-146.19 55.19-202 0L.94 0H75l117 115.83a91.1 91.1 0 0 0 127.91 0Z'/>",
                    "<path fill='#ed0e11' d='M74.05 424H0l155-153.42c55.77-55.19 146.19-55.19 202 0L512 424h-74L320 307.23a91.1 91.1 0 0 0-127.91 0Z'/>",
                    "</g></g></symbol>",
                    "<symbol id='faceB' viewBox='0 0 130 130'><defs><clipPath id='fb-clip' clipPathUnits='userSpaceOnUse'><circle cx='65' cy='65' r='33'/></clipPath></defs>",
                    "<circle cx='65' cy='65' r='58' fill='#30D100'/><circle cx='65' cy='65' r='46' fill='#111'/><circle cx='65' cy='65' r='33' fill='#fff'/>",
                    "<g clip-path='url(#fb-clip)'><g transform='translate(65 65) scale(0.038762) translate(-392 -638)'><g fill-rule='nonzero'>",
                    "<polygon fill='#343434' points='392.07,0 383.5,29.11 383.5,873.74 392.07,882.29 784.13,650.54'/>",
                    "<polygon fill='#8C8C8C' points='392.07,0 -0,650.54 392.07,882.29 392.07,472.33'/>",
                    "<polygon fill='#3C3C3B' points='392.07,956.52 387.24,962.41 387.24,1263.28 392.07,1277.38 784.37,724.89'/>",
                    "<polygon fill='#8C8C8C' points='392.07,1277.38 392.07,956.52 -0,724.89'/>",
                    "<polygon fill='#141414' points='392.07,882.29 784.13,650.54 392.07,472.33'/>",
                    "<polygon fill='#393939' points='0,650.54 392.07,882.29 392.07,472.33'/>",
                    "</g></g></g></symbol>",
                    "</defs>",
                    "<g transform='translate(65 65)'><g id='flip' transform='scale(1 1)'><g transform='translate(-65 -65)'>",
                    "<use href='#faceA'><animate attributeName='opacity' values='1;1;0;0;1;1' keyTimes='0;0.2499;0.25;0.75;0.7501;1' calcMode='discrete' dur='6s' repeatCount='indefinite'/></use>",
                    "<g transform='translate(0 130) scale(1 -1)'><use href='#faceB'><animate attributeName='opacity' values='0;0;1;1;0;0' keyTimes='0;0.2499;0.25;0.75;0.7501;1' calcMode='discrete' dur='6s' repeatCount='indefinite'/></use></g>",
                    "</g><animateTransform attributeName='transform' type='scale' values='1 1;1 0;1 -1;1 0;1 1' keyTimes='0;0.25;0.5;0.75;1' dur='6s' repeatCount='indefinite'/></g></g></g>"
                )
            );
    }
}
