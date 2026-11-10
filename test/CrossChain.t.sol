// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test, console} from "forge-std/Test.sol";

import {RebaseToken} from "../src/RebaseToken.sol";
import {Vault} from "../src/Vault.sol";
import {RebaseTokenPool} from "../src/RebaseTokenPool.sol";
import {IRebaseToken} from "../src/Interfaces/IRebaseToken.sol";

import {
    IERC20
} from "@ccip/src/v0.8/vendor/openzeppelin-solidity/v4.8.3/contracts/token/ERC20/IERC20.sol";
import {Pool} from "@ccip/src/v0.8/ccip/libraries/Pool.sol";
import {TokenPool} from "@ccip/src/v0.8/ccip/pools/TokenPool.sol";
import {RateLimiter} from "@ccip/src/v0.8/ccip/libraries/RateLimiter.sol";

/**
 * @notice Unit-tests the pool's lockOrBurn / releaseOrMint logic directly.
 *         No simulator, no fork, no registry, no RPC.
 *
 *         The test contract plays THREE roles simultaneously:
 *           - the pool's Router (implements getOnRamp / isOnRamp / isOffRamp)
 *           - the pool's RMN proxy (implements isCursed → false)
 *           - the caller of lockOrBurn / releaseOrMint
 */
contract CrossChainTest is Test {
    uint256 private constant AMOUNT = 1 ether;
    uint64 private constant REMOTE_CHAIN_SELECTOR = 16015286601757825753;

    address private owner = makeAddr("owner");
    address private user = makeAddr("user");

    RebaseToken private token;
    Vault private vault;
    RebaseTokenPool private pool;

    function setUp() public {
        vm.startPrank(owner);
        token = new RebaseToken();
        pool = new RebaseTokenPool(
            IERC20(address(token)),
            new address[](0),
            address(this), // RMN proxy
            address(this) // Router
        );
        vault = new Vault(address(token));

        token.grantMintAndBurnRole(address(vault));
        token.grantMintAndBurnRole(address(pool));

        TokenPool.ChainUpdate[] memory updates = new TokenPool.ChainUpdate[](1);
        updates[0] = TokenPool.ChainUpdate({
            remoteChainSelector: REMOTE_CHAIN_SELECTOR,
            allowed: true,
            remotePoolAddress: abi.encode(address(pool)),
            remoteTokenAddress: abi.encode(address(token)),
            outboundRateLimiterConfig: RateLimiter.Config({
                isEnabled: false,
                capacity: 0,
                rate: 0
            }),
            inboundRateLimiterConfig: RateLimiter.Config({
                isEnabled: false,
                capacity: 0,
                rate: 0
            })
        });
        TokenPool(address(pool)).applyChainUpdates(updates);
        vm.stopPrank();
    }

    // ── Router mocks ───────────────────────────────────────────────────────

    function getOnRamp(uint64) external view returns (address) {
        return address(this);
    }

    function isOnRamp(uint64, address onRamp) external view returns (bool) {
        return onRamp == address(this);
    }

    function isOffRamp(uint64, address offRamp) external view returns (bool) {
        return offRamp == address(this);
    }

    function isCursed(bytes16) external pure returns (bool) {
        return false;
    }

    // ─────────────────────────────────────────────────────────────────────
    // bridgeTokens — simulates the full CCIP message flow on a single
    // chain:  Router moves tokens → pool.lockOrBurn → destPoolData →
    //         pool.releaseOrMint.  The rate is preserved end‑to‑end.
    //
    // Returns the amount minted on the destination side (equal to
    // `releaseOrMintOut.destinationAmount`, i.e. `_amount` on success).
    // ─────────────────────────────────────────────────────────────────────
    function bridgeTokens(
        address _user,
        uint256 _amount
    ) internal returns (uint256) {
        uint256 originRate = token.getUserInterestRate(_user);

        // ── SOURCE: Router transfers user's tokens into the pool ──
        vm.prank(_user);
        assertTrue(token.transfer(address(pool), _amount));

        Pool.LockOrBurnInV1 memory lockOrBurnIn = Pool.LockOrBurnInV1({
            receiver: abi.encode(_user),
            remoteChainSelector: REMOTE_CHAIN_SELECTOR,
            originalSender: _user,
            amount: _amount,
            localToken: address(token)
        });

        Pool.LockOrBurnOutV1 memory lockOrBurnOut = pool.lockOrBurn(
            lockOrBurnIn
        );

        // ── DESTINATION: user's balance between burn and mint ──
        // On a real two-chain bridge this would be the balance on the
        // destination chain. Here it's the balance after the source-side
        // burn (i.e. whatever the user still holds locally — 0 in the
        // simple case).
        uint256 destinationBalanceBefore = token.balanceOf(_user);

        Pool.ReleaseOrMintInV1 memory releaseOrMintIn = Pool.ReleaseOrMintInV1({
            originalSender: abi.encode(_user),
            remoteChainSelector: REMOTE_CHAIN_SELECTOR,
            receiver: _user,
            amount: _amount,
            localToken: address(token),
            sourcePoolAddress: abi.encode(address(pool)),
            sourcePoolData: lockOrBurnOut.destPoolData, // ← bridged rate
            offchainTokenData: ""
        });

        Pool.ReleaseOrMintOutV1 memory releaseOrMintOut = pool.releaseOrMint(
            releaseOrMintIn
        );

        // ── ASSERTIONS ──
        // 1. Recipient received exactly `_amount` on the destination.
        assertEq(token.balanceOf(_user), destinationBalanceBefore + _amount);

        // 2. The user's rate survived the bridge unchanged.
        assertEq(token.getUserInterestRate(_user), originRate);

        // 3. releaseOrMint returned the correct destinationAmount.
        assertEq(releaseOrMintOut.destinationAmount, _amount);

        return releaseOrMintOut.destinationAmount;
    }

    // ── Source-side unit test ──────────────────────────────────────────────

    function testLockOrBurnEncodesRate() public {
        vm.deal(user, AMOUNT);
        vm.prank(user);
        vault.deposit{value: AMOUNT}();

        uint256 userRate = token.getUserInterestRate(user);
        assertEq(token.balanceOf(user), AMOUNT);

        vm.prank(user);
        assertTrue(token.transfer(address(pool), AMOUNT));
        assertEq(token.balanceOf(address(pool)), AMOUNT);

        Pool.LockOrBurnInV1 memory input = Pool.LockOrBurnInV1({
            receiver: abi.encode(user),
            remoteChainSelector: REMOTE_CHAIN_SELECTOR,
            originalSender: user,
            amount: AMOUNT,
            localToken: address(token)
        });

        Pool.LockOrBurnOutV1 memory output = pool.lockOrBurn(input);

        assertEq(abi.decode(output.destPoolData, (uint256)), userRate);
        assertEq(token.balanceOf(address(pool)), 0);
        assertEq(token.balanceOf(user), 0);
    }

    // ── Destination-side unit test ─────────────────────────────────────────

    function testReleaseOrMintAppliesRate() public {
        uint256 bridgedRate = 5e10;

        Pool.ReleaseOrMintInV1 memory input = Pool.ReleaseOrMintInV1({
            originalSender: abi.encode(user),
            remoteChainSelector: REMOTE_CHAIN_SELECTOR,
            receiver: user,
            amount: AMOUNT,
            localToken: address(token),
            sourcePoolAddress: abi.encode(address(pool)),
            sourcePoolData: abi.encode(bridgedRate),
            offchainTokenData: ""
        });

        pool.releaseOrMint(input);

        assertEq(token.balanceOf(user), AMOUNT);
        assertEq(token.getUserInterestRate(user), bridgedRate);
    }

    // ── End-to-end bridge via the new helper ───────────────────────────────

    function testBridgeTokens() public {
        // 1. User deposits → tokens minted with the current global rate.
        vm.deal(user, AMOUNT);
        vm.prank(user);
        vault.deposit{value: AMOUNT}();
        assertEq(token.balanceOf(user), AMOUNT);

        uint256 rateBefore = token.getUserInterestRate(user);

        // 2. Bridge.
        uint256 bridgedAmount = bridgeTokens(user, AMOUNT);

        // 3. User's balance and rate are intact after the round-trip.
        assertEq(bridgedAmount, AMOUNT);
        assertEq(token.balanceOf(user), AMOUNT);
        assertEq(token.getUserInterestRate(user), rateBefore);
    }

    // ── End-to-end round-trip that also preserves accrued interest ────────

    function testBridgeRoundTripWithAccruedInterest() public {
        // 1. Deposit.
        vm.deal(user, AMOUNT);
        vm.prank(user);
        vault.deposit{value: AMOUNT}();

        // 2. Bridge to "destination".
        bridgeTokens(user, AMOUNT);
        uint256 rateAfterFirstBridge = token.getUserInterestRate(user);

        // 3. Let one hour of interest accrue on the "destination".
        uint256 startTimestamp = block.timestamp;
        vm.warp(startTimestamp + 1 hours);

        uint256 balanceWithInterest = token.balanceOf(user);
        assertGt(balanceWithInterest, AMOUNT);

        // 4. Bridge back the full balance (principal + accrued interest).
        //    README: "Don't forget to bridge back the amount of interest
        //    they accrued on the destination chain in that time."
        bridgeTokens(user, balanceWithInterest);

        // 5. Both principal AND accrued interest survive the round-trip.
        assertEq(token.balanceOf(user), balanceWithInterest);
        assertEq(token.getUserInterestRate(user), rateAfterFirstBridge);
    }
}
