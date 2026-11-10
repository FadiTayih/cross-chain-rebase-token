// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {AccessControl} from "@openzeppelin/contracts/access/AccessControl.sol";

/**
 * @title RebaseToken
 * @notice this is a cross-chain rebase token
 * @notice the interest rate in the smart contract can only be decreased
 * @notice each user has their own interest rate, set on their first mint
 */
contract RebaseToken is ERC20, Ownable, AccessControl {
    error RebaseToken__InterestRateCanOnlyBeDecreased(
        uint256 oldInterestRate,
        uint256 newInterestRate
    );

    uint256 private constant PRECISION_FACTOR = 1e18;
    uint256 private s_interestRate = 5e10;
    bytes32 private constant MINT_AND_BURN_ROLE =
        keccak256("MINT_AND_BURN_ROLE");
    mapping(address => uint256) private s_userInterestRate;
    mapping(address => uint256) private s_userLastUpdatedTimestamp;

    event InterestRateChanged(uint256 oldInterestRate, uint256 newInterestRate);

    constructor() ERC20("RebaseToken", "RBT") Ownable(msg.sender) {}

    function grantMintAndBurnRole(address _account) external onlyOwner {
        _grantRole(MINT_AND_BURN_ROLE, _account);
    }

    function setInterestRate(uint256 _newInterestRate) external onlyOwner {
        if (_newInterestRate >= s_interestRate) {
            revert RebaseToken__InterestRateCanOnlyBeDecreased(
                s_interestRate,
                _newInterestRate
            );
        }

        uint256 oldInterestRate = s_interestRate;
        s_interestRate = _newInterestRate;
        emit InterestRateChanged(oldInterestRate, _newInterestRate);
    }

    /**
     * @notice Mint at the current global rate — used by the Vault when a
     *         user deposits. The user's rate is only set on their first
     *         mint, so early depositors keep their higher rate.
     */
    function mint(
        address _to,
        uint256 _amount
    ) external onlyRole(MINT_AND_BURN_ROLE) {
        _mintAccruedInterest(_to);

        // Only set the user's rate on their first mint so that users who
        // deposited at a higher rate keep that rate forever.
        if (s_userInterestRate[_to] == 0) {
            s_userInterestRate[_to] = s_interestRate;
        }

        _mint(_to, _amount);
    }

    /**
     * @notice Mint at a specific rate — used by the CCIP pool when tokens
     *         arrive from another chain. The bridged rate overrides any
     *         existing rate on the recipient (README: rate stays static
     *         across bridges).
     */
    function mint(
        address _to,
        uint256 _amount,
        uint256 _userInterestRate
    ) external onlyRole(MINT_AND_BURN_ROLE) {
        _mintAccruedInterest(_to);
        s_userInterestRate[_to] = _userInterestRate;
        _mint(_to, _amount);
    }

    /**
     * @notice Mints the interest a user has accrued since their last update
     *         so it becomes part of their principal, then resets the
     *         timestamp so future interest is measured from now.
     */
    function _mintAccruedInterest(address _user) internal {
        uint256 previousPrincipalBalance = super.balanceOf(_user);
        uint256 currentBalance = balanceOf(_user);
        uint256 balanceIncrease = currentBalance - previousPrincipalBalance;

        s_userLastUpdatedTimestamp[_user] = block.timestamp;
        _mint(_user, balanceIncrease);
    }

    // Override balanceOf to include interest accrued since the last update.
    function balanceOf(address _user) public view override returns (uint256) {
        return
            super.balanceOf(_user) +
            _calculateUserAccumulatedInterestSinceLastUpdate(_user);
    }

    function transfer(
        address _recipient,
        uint256 _amount
    ) public override returns (bool) {
        _mintAccruedInterest(msg.sender);
        _mintAccruedInterest(_recipient);
        if (_amount == type(uint256).max) {
            _amount = balanceOf(msg.sender);
        }
        if (balanceOf(_recipient) == 0) {
            s_userInterestRate[_recipient] = s_interestRate;
        }

        return super.transfer(_recipient, _amount);
    }

    function transferFrom(
        address _sender,
        address _recipient,
        uint256 _amount
    ) public override returns (bool) {
        _mintAccruedInterest(_sender);
        _mintAccruedInterest(_recipient);
        if (_amount == type(uint256).max) {
            _amount = balanceOf(_sender);
        }
        if (balanceOf(_recipient) == 0) {
            s_userInterestRate[_recipient] = s_interestRate;
        }

        return super.transferFrom(_sender, _recipient, _amount);
    }

    function principalBalanceOf(address _user) external view returns (uint256) {
        return super.balanceOf(_user);
    }

    // Interest the user has accrued since their last update.
    function _calculateUserAccumulatedInterestSinceLastUpdate(
        address _user
    ) internal view returns (uint256) {
        uint256 timeElapsed = block.timestamp -
            s_userLastUpdatedTimestamp[_user];
        return
            (super.balanceOf(_user) * timeElapsed * s_userInterestRate[_user]) /
            PRECISION_FACTOR;
    }

    function getUserInterestRate(
        address _user
    ) external view returns (uint256) {
        return s_userInterestRate[_user];
    }

    function getInterestRate() external view returns (uint256) {
        return s_interestRate;
    }

    function burn(
        address _from,
        uint256 _amount
    ) external onlyRole(MINT_AND_BURN_ROLE) {
        if (_amount == type(uint256).max) {
            _amount = balanceOf(_from);
        }
        _mintAccruedInterest(_from);
        _burn(_from, _amount);
    }
}
