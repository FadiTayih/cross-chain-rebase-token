// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Script, console} from "forge-std/Script.sol";

import {Client} from "@ccip/src/v0.8/ccip/libraries/Client.sol";
import {IRouterClient} from "@ccip/src/v0.8/ccip/interfaces/IRouterClient.sol";

import {
    IERC20
} from "@ccip/src/v0.8/vendor/openzeppelin-solidity/v4.8.3/contracts/token/ERC20/IERC20.sol";

/**
 * @title BridgeTokens
 * @notice Bridges RebaseTokens from the current chain to a remote chain via CCIP.
 *
 *         IMPORTANT: This script assumes the caller ALREADY holds the tokens.
 *         The script contract cannot mint (it lacks MINT_AND_BURN_ROLE).
 *         To get tokens, deposit ETH into the Vault first:
 *
 *           cast send $VAULT_ADDRESS "deposit()" --value 1ether \
 *               --rpc-url $SEPOLIA_RPC_URL --private-key $PRIVATE_KEY
 *
 *         Sepolia → Arbitrum Sepolia example:
 *
 *           TOKEN_ADDRESS=0xYourSepoliaToken \
 *           ROUTER_ADDRESS=0x0BF3dE8c5D3e8A2B34D2BEeB17ABFCeBaf363A59 \
 *           DEST_CHAIN_SELECTOR=3478487238524512106 \
 *           AMOUNT=1000000000000000 \
 *           forge script script/BridgeTokens.s.sol \
 *               --rpc-url $SEPOLIA_RPC_URL \
 *               --private-key $PRIVATE_KEY \
 *               --broadcast
 *
 *         Optional env vars:
 *           FEE_TOKEN  — LINK address to pay fees in LINK. Omit for native ETH.
 *           RECEIVER   — destination address. Defaults to the broadcaster.
 */
contract BridgeTokens is Script {
    function run() external {
        // ── Read configuration ────────────────────────────────────────
        address tokenAddress = vm.envAddress("TOKEN_ADDRESS");
        address routerAddress = vm.envAddress("ROUTER_ADDRESS");
        uint64 destChainSelector = uint64(vm.envUint("DEST_CHAIN_SELECTOR"));
        uint256 amount = vm.envUint("AMOUNT");

        // Receiver defaults to the broadcaster (msg.sender of the tx).
        address receiver = vm.envOr("RECEIVER", msg.sender);

        // Fee token: address(0) = native ETH. Set FEE_TOKEN to a LINK
        // address to pay in LINK instead.
        address feeToken = vm.envOr("FEE_TOKEN", address(0));

        // ── Build the CCIP message ────────────────────────────────────
        Client.EVMTokenAmount[]
            memory tokenAmounts = new Client.EVMTokenAmount[](1);
        tokenAmounts[0] = Client.EVMTokenAmount({
            token: tokenAddress,
            amount: amount
        });

        Client.EVM2AnyMessage memory message = Client.EVM2AnyMessage({
            receiver: abi.encode(receiver),
            data: "",
            tokenAmounts: tokenAmounts,
            feeToken: feeToken,
            extraArgs: Client._argsToBytes(
                Client.EVMExtraArgsV1({gasLimit: 500_000})
            )
        });

        // ── Estimate the CCIP fee ────────────────────────────────────
        uint256 fee = IRouterClient(routerAddress).getFee(
            destChainSelector,
            message
        );
        console.log("CCIP fee:", fee);

        // ── Approve the Router to pull the tokens ────────────────────
        // The Router needs an allowance to move the tokens from the caller
        // to the pool before it calls lockOrBurn.
        IERC20(tokenAddress).approve(routerAddress, amount);

        // ── Send the message ──────────────────────────────────────────
        vm.startBroadcast();
        bytes32 messageId = IRouterClient(routerAddress).ccipSend{
            value: feeToken == address(0) ? fee : 0
        }(destChainSelector, message);
        vm.stopBroadcast();

        console.log("Message ID:", uint256(messageId));
        console.log("Tokens bridged:", amount);
        console.log("Receiver:", receiver);
    }
}
