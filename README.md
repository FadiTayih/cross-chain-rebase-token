# Rebase Token — Cross-Chain Rebase Token with Chainlink CCIP

An interest-bearing ERC-20 that preserves per-user interest rates across
Ethereum Sepolia and Arbitrum Sepolia via Chainlink CCIP.

[![Foundry](https://img.shields.io/badge/Built%20with-Foundry-FFDB1C.svg)](https://getfoundry.sh/)
[![Solidity](https://img.shields.io/badge/Solidity-0.8.24-363636.svg)](https://soliditylang.org/)
[![Tests](https://img.shields.io/badge/Tests-14%20passing-brightgreen.svg)]()
[![License: MIT](https://img.shields.io/badge/License-MIT-blue.svg)](./LICENSE)

---

## Overview

Users deposit ETH into a `Vault` on the source chain and receive `RebaseToken`
(RBT), an ERC-20 whose `balanceOf` grows linearly with time at a per-user
interest rate. Tokens can be bridged between chains through Chainlink CCIP
while **preserving each user's individual rate** — the rate travels with the
token as part of the cross-chain payload.

The core design rule: _whatever interest rate you deposit with, you stick
with_. Later rate decreases by the protocol do not affect existing depositors.
When you bridge, your rate follows you — it does not reset to the current
global rate on the destination chain.

---

## How It Works

```
┌──────────────────────────── SOURCE CHAIN ────────────────────────────┐
│                                                                       │
│   User ──deposit(ETH)──▶ Vault ──mint(amount)──▶ RebaseToken          │
│                                                       │               │
│   User ──approve(router)──▶ Router ──transfer──▶ RebaseTokenPool      │
│                                                       │               │
│                                           lockOrBurn() ──▶ burn       │
│                                           destPoolData = abi.encode(rate)
│                                                       │               │
└───────────────────────────────────────────────────────┼───────────────┘
                                                        │
                                                 CCIP Message
                                                        │
┌───────────────────────────────────────────────────────┼───────────────┐
│                                                       ▼               │
│                                         RebaseTokenPool.releaseOrMint │
│                                                       │               │
│                                           mint(receiver, amount, rate)│
│                                                       ▼               │
│                                               RebaseToken             │
│                                                       │               │
└──────────────────────────── DESTINATION CHAIN ────────────────────────┘
```

1. **Deposit** — user sends ETH to the `Vault`; the Vault mints RBT 1:1 at
   the current global rate.
2. **Accrue** — `RebaseToken.balanceOf()` returns `principal + interest`,
   where interest is computed on-chain at read time.
3. **Bridge** — the user approves the Router, which moves tokens into the
   pool. The pool burns them and ABI-encodes the user's rate into
   `destPoolData`.
4. **Deliver** — CCIP routes the message. On the destination chain, the
   pool decodes the rate from `sourcePoolData` and mints at that exact rate.

---

## Contracts

### `src/RebaseToken.sol`

ERC-20 with `balanceOf` overridden to include accrued interest. Inherits
`Ownable` and `AccessControl`.

| Function                     | Who calls                | Purpose                                             |
| ---------------------------- | ------------------------ | --------------------------------------------------- |
| `mint(to, amount)`           | Vault (on deposit)       | Sets user rate only on first mint (sticky)          |
| `mint(to, amount, rate)`     | Pool (on bridge receipt) | Forces user rate to bridged value                   |
| `burn(from, amount)`         | Vault or Pool            | Burns principal; `type(uint256).max` = full balance |
| `setInterestRate(rate)`      | Owner                    | Decreases global rate (increase reverts)            |
| `grantMintAndBurnRole(addr)` | Owner                    | Grants `MINT_AND_BURN_ROLE`                         |
| `getInterestRate()`          | Anyone                   | Returns current global rate                         |
| `getUserInterestRate(user)`  | Anyone                   | Returns user's locked rate                          |
| `principalBalanceOf(user)`   | Anyone                   | Returns principal (excludes accrued interest)       |

### `src/Vault.sol`

Minimal ETH custodian. Holds deposits, mints RBT 1:1, burns on redemption.

| Function                  | Purpose                                   |
| ------------------------- | ----------------------------------------- |
| `deposit()` (payable)     | Mints `msg.value` RBT to caller           |
| `redeem(amount)`          | Burns RBT and returns `amount` wei of ETH |
| `getRebaseTokenAddress()` | Returns the linked token address          |

### `src/RebaseTokenPool.sol`

Extends CCIP's abstract `TokenPool`. Overrides the two mandatory hooks.

| Hook            | Behavior                                                   |
| --------------- | ---------------------------------------------------------- |
| `lockOrBurn`    | Burns pool's tokens, encodes user rate into `destPoolData` |
| `releaseOrMint` | Decodes `sourcePoolData`, mints at bridged rate            |

### `src/Interfaces/IRebaseToken.sol`

Interface used by `Vault` and `RebaseTokenPool` to call the token without
importing the concrete implementation.

---

## Quickstart

### Requirements

- [Foundry](https://getfoundry.sh/) (forge, cast, anvil)
- [Node.js](https://nodejs.org/) + npm (for the CCIP package)
- A Unix-like shell (macOS, Linux, or WSL)

### Install

```bash
git clone <your-repo-url> Rebase-Token
cd Rebase-Token

# Solidity dependencies
forge install foundry-rs/forge-std
forge install openzeppelin/openzeppelin-contracts
forge install smartcontractkit/chainlink-local

# CCIP package (npm — do NOT use the GitHub repo; see "Design Notes")
npm install @chainlink/contracts-ccip@1.5.0
```

### Build & test

```bash
forge build
forge test
```

Expected: **14 tests passing** (10 in `RebaseToken.t.sol`, 4 in `CrossChain.t.sol`).

### Run a local node (optional)

```bash
anvil
```

### Deploy locally

```bash
forge script script/Deployer.s.sol -vv
```

No env vars required for local simulation — the script falls back to
`address(1)` for Router/RMN.

---

## Testing

```bash
forge test                                  # all tests
forge test --match-contract RebaseTokenTest # token + vault only
forge test --match-contract CrossChainTest  # pool bridge logic only
forge test -vvv                             # verbose traces on failure
forge coverage                              # line coverage report
```

### Test inventory

**`test/RebaseToken.t.sol` — 10 tests**

- `testDepositAndRedeem` — round-trip with no time elapsed
- `testDepositLinear` — two equal 1h intervals produce equal accruals (fuzz)
- `testRedeemStraightWay` — immediate redeem drains balance
- `testRedeemAfterTimePassed` — redeem after warp (fuzz)
- `testTransfer` — transfers fold accrued interest for both parties (fuzz)
- `testCannotSetInterestRateDirectly` — non-owner cannot change rate
- `testCannotCallMintAndBurnDirectly` — non-role cannot mint or burn
- `testGetPrincipalAmount` — principal balance equals deposit (fuzz)
- `testGetRebaseTokenAddress` — Vault getter returns token address
- `testInterestRateCanOnlyDecrease` — decrease works, increase reverts

**`test/CrossChain.t.sol` — 4 tests**

- `testLockOrBurnEncodesRate` — `destPoolData` decodes to pre-burn rate
- `testReleaseOrMintAppliesRate` — `sourcePoolData` becomes recipient's rate
- `testBridgeTokens` — end-to-end round trip preserves balance and rate
- `testBridgeRoundTripWithAccruedInterest` — interest survives a bridge-back

The CrossChain tests avoid the CCIP fork simulator entirely. The test
contract acts as the Router and the RMN proxy via mocks, so tests run in
milliseconds with no RPC dependency.

---

## Deployment

### 1. Deploy on each chain

**Sepolia:**

```bash
CCIP_ROUTER=0x0BF3dE8c5D3e8A2B34D2BEeB17ABfCeBaf363A59 \
CCIP_RMN_PROXY=0xba3f6a74BD12Cf1e48d4416c7b50963cA98AfD61 \
forge script script/Deployer.s.sol \
    --rpc-url $SEPOLIA_RPC_URL \
    --private-key $PRIVATE_KEY \
    --broadcast --verify --etherscan-api-key $ETHERSCAN_API_KEY
```

**Arbitrum Sepolia:**

```bash
CCIP_ROUTER=0x2a9C5afB0d0e4BAb2BCdaE109EC4b0c4Be15a165 \
CCIP_RMN_PROXY=<arb-sepolia-rmn> \
forge script script/Deployer.s.sol \
    --rpc-url $ARB_SEPOLIA_RPC_URL \
    --private-key $PRIVATE_KEY \
    --broadcast --verify --etherscan-api-key $ARBISCAN_API_KEY
```

> Verify Router/RMN addresses against the
> [CCIP Directory](https://docs.chain.link/ccip/directory/testnet) before
> broadcasting — Chainlink occasionally rotates them.

### 2. Configure each pool for the other chain

**Sepolia → Arbitrum Sepolia:**

```bash
POOL_ADDRESS=0x<sepolia-pool> \
REMOTE_CHAIN_SELECTOR=3478487238524512106 \
REMOTE_POOL_ADDRESS=0x<arb-pool> \
REMOTE_TOKEN_ADDRESS=0x<arb-token> \
forge script script/ConfigurePool.s.sol \
    --rpc-url $SEPOLIA_RPC_URL --private-key $PRIVATE_KEY --broadcast
```

**Arbitrum Sepolia → Sepolia:**

```bash
POOL_ADDRESS=0x<arb-pool> \
REMOTE_CHAIN_SELECTOR=16015286601757825753 \
REMOTE_POOL_ADDRESS=0x<sepolia-pool> \
REMOTE_TOKEN_ADDRESS=0x<sepolia-token> \
forge script script/ConfigurePool.s.sol \
    --rpc-url $ARB_SEPOLIA_RPC_URL --private-key $PRIVATE_KEY --broadcast
```

### 3. Bridge

```bash
TOKEN_ADDRESS=0x<sepolia-token> \
ROUTER_ADDRESS=0x0BF3dE8c5D3e8A2B34D2BEeB17ABfCeBaf363A59 \
DEST_CHAIN_SELECTOR=3478487238524512106 \
AMOUNT=1000000000000000 \
forge script script/BridgeTokens.s.sol \
    --rpc-url $SEPOLIA_RPC_URL --private-key $PRIVATE_KEY --broadcast
```

Optional env vars:

- `RECEIVER` — destination address (defaults to `msg.sender`)
- `FEE_TOKEN` — LINK address to pay fees in LINK (defaults to native ETH)

---

## Project Structure

```
Rebase-Token/
├── foundry.toml
├── src/
│   ├── RebaseToken.sol
│   ├── Vault.sol
│   ├── RebaseTokenPool.sol
│   └── Interfaces/
│       └── IRebaseToken.sol
├── test/
│   ├── RebaseToken.t.sol
│   └── CrossChain.t.sol
├── script/
│   ├── Deployer.s.sol
│   ├── ConfigurePool.s.sol
│   └── BridgeTokens.s.sol
├── docs/
│   └── Rebase-Token-Documentation.html
└── lib/
    ├── forge-std/
    ├── openzeppelin-contracts/
    └── chainlink-local/
```

---

## Dependencies

| Dependency                | Version | Source                                              |
| ------------------------- | ------- | --------------------------------------------------- |
| Solc                      | 0.8.24  | `foundry.toml`                                      |
| forge-std                 | v1.17.0 | `forge install foundry-rs/forge-std`                |
| OpenZeppelin Contracts    | v5.7.0  | `forge install openzeppelin/openzeppelin-contracts` |
| @chainlink/contracts-ccip | 1.5.0   | `npm install @chainlink/contracts-ccip@1.5.0`       |
| chainlink-local           | v0.3.1  | `forge install smartcontractkit/chainlink-local`    |

### Remappings

All remappings live inline in `foundry.toml` (do **not** also create a
`remappings.txt` — having both causes conflicts).

```toml
remappings = [
    "@openzeppelin/contracts@4.8.3/=lib/chainlink-local/lib/openzeppelin-contracts-4.8.3/contracts/",
    "@openzeppelin/contracts@5.3.0/=lib/chainlink-local/lib/openzeppelin-contracts-5.3.0/contracts/",
    "@openzeppelin/contracts/=lib/openzeppelin-contracts/contracts/",
    "forge-std/=lib/forge-std/src/",
    "@ccip/=node_modules/@chainlink/contracts-ccip/",
    "@chainlink/local/=lib/chainlink-local/",
    "@chainlink/contracts-ccip/=lib/chainlink-local/lib/chainlink-ccip/chains/evm/",
    "@chainlink/contracts/=lib/chainlink-local/lib/chainlink-evm/contracts/",
]
```

---

## Design Notes

### Why npm for CCIP, not the GitHub repo

The course this project is based on was recorded against a specific Git
commit of `smartcontractkit/ccip`. The `@chainlink/contracts-ccip@1.5.0`
npm package carries the equivalent APIs and is far easier to install. **Do
not** mix the two — the GitHub repo has a different directory layout
(`chains/evm/contracts/...` vs npm's `src/v0.8/ccip/...`) and mixing the
two creates confusing resolver errors.

### Why `via_ir` is disabled

The project deliberately does **not** enable the IR pipeline. With
`via_ir = true`, the optimizer common-subexpression-eliminates multiple
`block.timestamp` reads inside a single function — which breaks tests that
call `vm.warp` between two `block.timestamp` reads. The legacy compiler
re-reads `TIMESTAMP` at each evaluation, which is the semantics the tests
rely on.

Stack-too-deep was avoided by keeping test functions small (each `_bridge`-
style helper was split into focused subfunctions), rather than by enabling
IR.

### Sticky user rates

A user's rate is set **once**, on their first `mint`. Subsequent mints
through the Vault's 2-argument path leave the rate untouched, so a later
global rate decrease does not penalize an earlier depositor. The 3-argument
mint (called only by the pool) is the single exception: it forcibly sets
the rate to the bridged value, satisfying the "rate travels with you" rule.

### The `type(uint256).max` sentinel

`burn`, `transfer`, and `transferFrom` all interpret `max` as "use the
caller's full balance". `Vault.redeem` resolves the sentinel itself before
calling `burn`, so the ETH returned to the user exactly matches the RBT
burned. See §4.2 of the HTML documentation for the full reasoning.

---

## Known Limitations

The following are intentionally **out of scope** for this project:

- **Discrete rate decrease on deposit** — the README of the course describes
  a `newRate = oldRate × oldTVL / newTVL` formula; this is not implemented.
  Adding it requires an `onlyVault` guard on `setInterestRate`.
- **Rate-limiter enablement** — all `ChainUpdate` configs pass
  `isEnabled: false`. Production deployments should set nonzero capacity and
  rate.
- **Yield on Vault balance** — the Vault holds ETH idly. Rewards must be
  funded manually or by a treasury contract.
- **Fork-based CCIP integration tests** — require archive RPC endpoints and
  are not included in the default test suite.
- **Upgradeability** — all contracts are immutable. Changes require new
  deployments and user migration.
- **Pause mechanism** — no circuit breaker on the Vault or pool.

For a full treatment of these and recommended production hardening, see the
**§10 Appendix — Known Limitations** section of
`docs/Rebase-Token-Documentation.html`.

---

## Verification Checklist

Before considering a deployment "done", verify:

- [ ] `forge build` — clean (no errors, no warnings)
- [ ] `forge test` — all 14 tests pass
- [ ] Both chains have `Deployer.s.sol` executed successfully
- [ ] `grantMintAndBurnRole(vault)` on the token succeeds (otherwise
      `deposit` reverts)
- [ ] `grantMintAndBurnRole(pool)` on the token succeeds (otherwise
      `lockOrBurn` / `releaseOrMint` revert)
- [ ] `applyChainUpdates` executed on both pools (otherwise `lockOrBurn`
      reverts with `NonExistentChain`)
- [ ] Token registered in the `TokenAdminRegistry`
      (`registerAdminViaOwner` → `acceptAdminRole` → `setPool`)
- [ ] A test bridge succeeds and the destination `balanceOf` matches

---

## License

MIT — see [LICENSE](./LICENSE) for full text.

---

## Acknowledgements

Built following the **Cyfrin Updraft Foundry Cross-Chain Rebase Token**
course, extended with:

- Foundry-native CCIP pool unit tests (no fork simulator dependency)
- A production-shaped deploy / configure / bridge script trio
- Comprehensive HTML project documentation

---

## Support

- Open an issue on the repository for bugs
- For CCIP-specific questions, consult the
  [Chainlink CCIP docs](https://docs.chain.link/ccip)
- For Foundry-specific questions, consult the
  [Foundry Book](https://book.getfoundry.sh/)
