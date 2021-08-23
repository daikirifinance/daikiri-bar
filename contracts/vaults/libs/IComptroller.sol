// SPDX-License-Identifier: MIT

pragma solidity 0.7.3;

interface IComptroller {
    function claimReward(uint8 rewardType, address holder) external;
}