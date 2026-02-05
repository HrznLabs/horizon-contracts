# Horizon Protocol Smart Contracts

Smart contracts for Horizon Protocol, built with Foundry and deployed on Base.

## Overview

Horizon enables trustless, escrow-backed mission coordination:

- Missions are funded in USDC and escrowed on-chain
- Performers accept, submit proof, and receive payment on completion
- Disputes are handled with DDR/LPP economics
- Guilds curate missions and earn fees

## Contract Suite

- `MissionFactory` - deploys `MissionEscrow` clones (EIP-1167)
- `MissionEscrow` - mission lifecycle and escrow
- `PaymentRouter` - fee routing to treasuries
- `GuildFactory` / `GuildDAO` - guild governance
- `DisputeResolver` - DDR/LPP dispute flow
- `ReputationAttestations` - on-chain ratings
- `HorizonAchievements` - achievements (soulbound + tradable)

## Fee Structure (basis points)

- Protocol: 400
- Labs: 400
- Resolver: 200
- Guild: 0-1500 (router cap), `GuildDAO` enforces 1000 max at init
- Performer: 9000 minus guild fee

## Deployments

See `DEPLOYED_ADDRESSES.md` for the canonical list. Current Base Sepolia v2.2 addresses:

| Contract | Address |
| --- | --- |
| PaymentRouter | `0x94fb7908257ec36f701d2605b51eefed4326ddf5` |
| MissionFactory | `0xee9234954b134c39c17a75482da78e46b16f466c` |
| GuildFactory | `0xfeae3538a4a1801e47b6d16104aa8586edb55f00` |
| ReputationAttestations | `0xedae9682a0fb6fb3c18d6865461f67db7d748002` |
| DisputeResolver | `0xb00ac4278129928aecc72541b0bcd69d94c1691e` |
| HorizonAchievements | `0x568e0e3102bfa1f4045d3f62559c0f9823b469bc` |

USDC (Base Sepolia): `0x036CbD53842c5426634e7929541eC2318f3dCF7e`

## Prerequisites

- Foundry
- Node.js (for scripts)

## Install

```bash
git clone https://github.com/HrznLabs/horizon-contracts.git
cd horizon-contracts
forge install
```

## Build & Test

```bash
forge build
forge test -vvv
forge coverage
```

## Deploy

```bash
# Base Sepolia
forge script script/Deploy.s.sol:DeployScript --rpc-url base_sepolia --broadcast --verify

# Base Mainnet
forge script script/Deploy.s.sol:DeployScript --rpc-url base_mainnet --broadcast --verify
```

## ABIs

```bash
node scripts/export-abis.js
```

## Security Notes

- `PaymentRouter.onlyAuthorized` is currently permissive for testing. Harden it before production deployments.
- Dispute resolution uses DDR (5%) and LPP (2%) as enforced in `DisputeResolver`.

## License

MIT
