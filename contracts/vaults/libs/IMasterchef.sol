// SPDX-License-Identifier: MIT

pragma solidity 0.7.3;

interface IMasterchef {
    function deposit(uint256 _pid, uint256 _amount) external;

    function deposit(uint256 _pid, uint256 _amount, address _ref) external;

    function withdraw(uint256 _pid, uint256 _amount) external;

    function withdraw(uint256 _pid, uint256 _amount, address _ref) external;

    function emergencyWithdraw(uint256 _pid) external;
    
    function userInfo(uint256 _pid, address _address) external view returns (uint256, uint256);
}