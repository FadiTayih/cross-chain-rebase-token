// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Script, console} from "forge-std/Script.sol";

import {TokenPool} from "@ccip/src/v0.8/ccip/pools/TokenPool.sol";
import {RateLimiter} from "@ccip/src/v0.8/ccip/libraries/RateLimiter.sol";

/**
 * @title ConfigurePool
 * @notice Configures an already-deployed RebaseTokenPool to accept transfers
 *         from a single remote chain.
 *
 *         Run this AFTER both chains have been deployed (Deployer.s.sol on
 *         Sepolia AND Arbitrum Sepolia).
 *
 *         Sepolia → Arbitrum Sepolia example:
 *
 *           POOL_ADDRESS=0xYourSepoliaPool \
 *           REMOTE_CHAIN_SELECTOR=3478487238524512106 \
 *           REMOTE_POOL_ADDRESS=0xYourArbSepoliaPool \
 *           REMOTE_TOKEN_ADDRESS=0xYourArbSepoliaToken \
 *           forge script script/ConfigurePool.s.sol \
 *               --rpc-url $SEPOLIA_RPC_URL \
 *               --private-key $PRIVATE_KEY \
 *               --broadcast
 *
 *         Chain selectors (CCIP directory):
 *           Ethereum Sepolia   : 16015286601757825753
 *           Arbitrum Sepolia   : 3478487238524512106
 */
contract ConfigurePool is Script {
    function run() external {
        // ── Read configuration from environment ────────────────────────
        address poolAddress = vm.envAddress("POOL_ADDRESS");
        uint64 remoteChainSelector = uint64(
            vm.envUint("REMOTE_CHAIN_SELECTOR")
        );
        address remotePoolAddress = vm.envAddress("REMOTE_POOL_ADDRESS");
        address remoteTokenAddress = vm.envAddress("REMOTE_TOKEN_ADDRESS");

        // ── Build the ChainUpdate ──────────────────────────────────────
        // v1.5.0 ChainUpdate uses a SINGLE `remotePoolAddress` (bytes),
        // not a bytes[] array. Rate limiting is disabled (0/0/0), which
        // is valid because `allowed` is true.
        TokenPool.ChainUpdate[] memory updates = new TokenPool.ChainUpdate[](1);
        updates[0] = TokenPool.ChainUpdate({
            remoteChainSelector: remoteChainSelector,
            allowed: true,
            remotePoolAddress: abi.encode(remotePoolAddress),
            remoteTokenAddress: abi.encode(remoteTokenAddress),
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

        // ── Broadcast ──────────────────────────────────────────────────
        vm.startBroadcast();
        TokenPool(poolAddress).applyChainUpdates(updates);
        vm.stopBroadcast();

        console.log("Pool configured:", poolAddress);
        console.log("Remote chain  :", remoteChainSelector);
        console.log("Remote pool   :", remotePoolAddress);
        console.log("Remote token  :", remoteTokenAddress);
    }
}
