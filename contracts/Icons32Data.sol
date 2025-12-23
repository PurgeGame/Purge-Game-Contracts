// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

contract Icons32Data {
    string[33] private _paths;
    string private _diamond;
    string[8] private _symQ1;
    string[8] private _symQ2;
    string[8] private _symQ3;

    constructor(
        string[33] memory paths_,
        string memory diamond_,
        string[8] memory symQ1_,
        string[8] memory symQ2_,
        string[8] memory symQ3_
    ) {
        for (uint256 i; i < 33; ++i) {
            _paths[i] = paths_[i];
        }

        _diamond = diamond_;

        for (uint256 i; i < 8; ++i) {
            _symQ1[i] = symQ1_[i];
            _symQ2[i] = symQ2_[i];
            _symQ3[i] = symQ3_[i];
        }
    }

    function data(uint256 i) external view returns (string memory) {
        return _paths[i];
    }

    function diamond() external view returns (string memory) {
        return _diamond;
    }

    function symbol(uint256 quadrant, uint8 idx) external view returns (string memory) {
        if (quadrant == 0) return _symQ1[idx];
        if (quadrant == 1) return _symQ2[idx];
        if (quadrant == 2) return _symQ3[idx];
        return "";
    }
}
