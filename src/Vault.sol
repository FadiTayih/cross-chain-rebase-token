// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IRebaseToken} from "./Interfaces/IRebaseToken.sol";

contract Vault {
    error Vault__RedeemFailed();

    IRebaseToken private immutable i_rebaseToken;

    event Deposit(address indexed user, uint256 amount);
    event Redeem(address indexed user, uint256 amount);

    constructor(address _rebaseToken) {
        i_rebaseToken = IRebaseToken(_rebaseToken);
    }

    receive() external payable {}

    function deposit() external payable {
        // Mint the rebase token to the user.
        // NOTE: i_rebaseToken.mint() is role-gated on the token
        //       (MINT_AND_BURN_ROLE), so the deploy script must call
        //       rebaseToken.grantMintAndBurnRole(address(vault))
        //       before any deposit / redeem will succeed.
        i_rebaseToken.mint(msg.sender, msg.value);
        emit Deposit(msg.sender, msg.value);
    }

    function redeem(uint256 _amount) external {
        // FIX: the token's burn() converts type(uint256).max internally,
        // but the Vault's local `_amount` is not modified. Resolve max here
        // before calling burn() so the amount we send back matches the
        // amount actually burned.
        if (_amount == type(uint256).max) {
            _amount = i_rebaseToken.balanceOf(msg.sender);
        }

        i_rebaseToken.burn(msg.sender, _amount);

        (bool success, ) = msg.sender.call{value: _amount}("");
        if (!success) {
            revert Vault__RedeemFailed();
        }

        emit Redeem(msg.sender, _amount);
    }

    function getRebaseTokenAddress() external view returns (address) {
        return address(i_rebaseToken);
    }
}
