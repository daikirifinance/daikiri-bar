// SPDX-License-Identifier: MIT

pragma solidity 0.7.3;

interface IStrategyDaiki {
    function depositReward(uint256 _depositAmt) external returns (bool);
}