// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Pool} from "@ccip/src/v0.8/ccip/libraries/Pool.sol";
import {TokenPool} from "@ccip/src/v0.8/ccip/pools/TokenPool.sol";
import {
    IERC20
} from "@ccip/src/v0.8/vendor/openzeppelin-solidity/v4.8.3/contracts/token/ERC20/IERC20.sol";
import {IRebaseToken} from "./Interfaces/IRebaseToken.sol";

/**
 * @title RebaseTokenPool
 * @notice CCIP token pool for RebaseToken.
 * @notice The user's interest rate is encoded into destPoolData on the
 *         source chain and applied on the destination chain, so the rate
 *         stays static across the bridge (per README).
 */
contract RebaseTokenPool is TokenPool {
    constructor(
        IERC20 token,
        address[] memory allowlist,
        address rmnProxy,
        address router
    ) TokenPool(token, allowlist, rmnProxy, router) {}

    function lockOrBurn(
        Pool.LockOrBurnInV1 calldata lockOrBurnIn
    )
        external
        virtual
        override
        returns (Pool.LockOrBurnOutV1 memory lockOrBurnOut)
    {
        _validateLockOrBurn(lockOrBurnIn);

        IRebaseToken token = IRebaseToken(address(i_token));

        uint256 userInterestRate = token.getUserInterestRate(
            lockOrBurnIn.originalSender
        );

        // The Router moved the user's tokens to this pool before calling
        // lockOrBurn, so we burn from address(this), not from the sender.
        token.burn(address(this), lockOrBurnIn.amount);

        lockOrBurnOut = Pool.LockOrBurnOutV1({
            destTokenAddress: getRemoteToken(lockOrBurnIn.remoteChainSelector),
            destPoolData: abi.encode(userInterestRate)
        });
    }

    function releaseOrMint(
        Pool.ReleaseOrMintInV1 calldata releaseOrMintIn
    ) external override returns (Pool.ReleaseOrMintOutV1 memory) {
        _validateReleaseOrMint(releaseOrMintIn);

        IRebaseToken token = IRebaseToken(address(i_token));

        uint256 userInterestRate = abi.decode(
            releaseOrMintIn.sourcePoolData,
            (uint256)
        );

        token.mint(
            releaseOrMintIn.receiver,
            releaseOrMintIn.amount,
            userInterestRate
        );

        return
            Pool.ReleaseOrMintOutV1({
                destinationAmount: releaseOrMintIn.amount
            });
    }
}
