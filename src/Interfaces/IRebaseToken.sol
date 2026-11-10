// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

interface IRebaseToken {
    // Vault path (2-arg)
    function mint(address _to, uint256 _amount) external;

    // Pool path (3-arg, applies the bridged rate)
    function mint(
        address _to,
        uint256 _amount,
        uint256 _userInterestRate
    ) external;

    function burn(address _from, uint256 _amount) external;

    function balanceOf(address _user) external view returns (uint256);
    function principalBalanceOf(address _user) external view returns (uint256);

    function getInterestRate() external view returns (uint256);
    function setInterestRate(uint256 _newInterestRate) external;
    function getUserInterestRate(address _user) external view returns (uint256);
}
