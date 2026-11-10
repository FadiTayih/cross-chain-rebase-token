// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Script, console} from "forge-std/Script.sol";

import {RebaseToken} from "../src/RebaseToken.sol";
import {Vault} from "../src/Vault.sol";
import {RebaseTokenPool} from "../src/RebaseTokenPool.sol";

import {
    IERC20
} from "@ccip/src/v0.8/vendor/openzeppelin-solidity/v4.8.3/contracts/token/ERC20/IERC20.sol";

/**
 * @title Deployer
 * @notice Deploys RebaseToken, Vault, and RebaseTokenPool, and grants
 *         MINT_AND_BURN_ROLE to the vault and pool.
 *
 *         Router & RMN addresses are read from environment variables
 *         (CCIP_ROUTER, CCIP_RMN_PROXY). For local runs without env vars,
 *         a placeholder address(1) is used — it is NOT address(this),
 *         which Foundry forbids in scripts (ephemeral address).
 *
 *         Sepolia example:
 *           CCIP_ROUTER=0x0BF3dE8c5D3e8A2B34D2BEeB17ABfCeBaf363A59 \
 *           CCIP_RMN_PROXY=0xba3f6a74BD12Cf1e48d4416c7b50963cA98AfD61 \
 *           forge script script/Deployer.s.sol --network sepolia --broadcast
 */
contract Deployer is Script {
    struct Deployments {
        address token;
        address pool;
        address vault;
    }

    /// @dev Placeholder for local runs — NOT address(this).
    address private constant PLACEHOLDER = address(1);

    function run() external returns (Deployments memory) {
        // Use envOr with a fixed placeholder instead of address(this).
        // address(this) would trigger Foundry's script-execution-protection.
        address router = vm.envOr("CCIP_ROUTER", PLACEHOLDER);
        address rmnProxy = vm.envOr("CCIP_RMN_PROXY", PLACEHOLDER);

        vm.startBroadcast();

        // 1. Token — deployer becomes owner.
        RebaseToken token = new RebaseToken();

        // 2. Vault — needs the token address.
        Vault vault = new Vault(address(token));

        // 3. Pool — needs the token, an allowlist, the RMN proxy, and router.
        RebaseTokenPool pool = new RebaseTokenPool(
            IERC20(address(token)),
            new address[](0), // allowlist disabled
            rmnProxy,
            router
        );

        // 4. CRITICAL — grant MINT_AND_BURN_ROLE to both the vault and the
        //    pool. Without this, deposit / redeem / lockOrBurn / releaseOrMint
        //    all revert with AccessControlUnauthorizedAccount.
        token.grantMintAndBurnRole(address(vault));
        token.grantMintAndBurnRole(address(pool));

        vm.stopBroadcast();

        console.log("RebaseToken       :", address(token));
        console.log("Vault             :", address(vault));
        console.log("RebaseTokenPool   :", address(pool));
        console.log("Router            :", router);
        console.log("RMN Proxy         :", rmnProxy);

        return
            Deployments({
                token: address(token),
                pool: address(pool),
                vault: address(vault)
            });
    }
}
