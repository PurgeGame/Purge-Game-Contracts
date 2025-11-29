// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

interface IPurgeJackpots {
    function runExternalJackpot(
        uint8 kind,
        uint256 poolWei,
        uint32 cap,
        uint24 lvl,
        uint256 rngWord
    )
        external
        returns (
            bool finished,
            address[] memory winners,
            uint256[] memory amounts,
            uint256 trophyPoolDelta,
            uint256 returnAmountWei
        );

    function runBafJackpot(
        uint256 poolWei,
        uint32 cap,
        uint24 lvl,
        uint256 rngWord
    )
        external
        returns (
            bool finished,
            address[] memory winners,
            uint256[] memory amounts,
            uint256 trophyPoolDelta,
            uint256 returnAmountWei
        );

    function runDecimatorJackpot(
        uint256 poolWei,
        uint32 cap,
        uint24 lvl,
        uint256 rngWord
    )
        external
        returns (
            bool finished,
            address[] memory winners,
            uint256[] memory amounts,
            uint256 trophyPoolDelta,
            uint256 returnAmountWei
        );

    function consumeDecClaim(address player, uint24 lvl) external returns (uint256 amountWei);
    function consumeBafClaim(address player, uint24 lvl) external returns (uint256 amountWei);
    function claimDecimatorJackpot(uint24 lvl) external;
    function claimBafJackpot(uint24 lvl) external;

    function decClaimable(address player, uint24 lvl) external view returns (uint256 amountWei, bool winner);
    function bafClaimable(address player, uint24 lvl) external view returns (uint256 amountWei, bool winner);

    function recordBafFlip(address player, uint24 lvl) external;
    function recordDecBurn(address player, uint24 lvl, uint8 bucket, uint256 amount) external returns (uint8 bucketUsed);

    function wire(address coin_, address purgeGame_, address trophies_) external;
}
