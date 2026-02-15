# Horizon Protocol - Deployed Contract Addresses

## Base Sepolia Testnet (Chain ID: 84532)

### Core Contracts (v2.2 Deployment)

| Contract | Address | BaseScan |
|----------|---------|----------|
| PaymentRouter | [`0x94fb7908257ec36f701d2605b51eefed4326ddf5`](https://sepolia.basescan.org/address/0x94fb7908257ec36f701d2605b51eefed4326ddf5) | [View](https://sepolia.basescan.org/address/0x94fb7908257ec36f701d2605b51eefed4326ddf5) |
| MissionFactory | [`0xee9234954b134c39c17a75482da78e46b16f466c`](https://sepolia.basescan.org/address/0xee9234954b134c39c17a75482da78e46b16f466c) | [View](https://sepolia.basescan.org/address/0xee9234954b134c39c17a75482da78e46b16f466c) |
| MissionEscrow (Implementation) | [`0x873Ea710B6b289b0e9D6867B1630066e9721B5c9`](https://sepolia.basescan.org/address/0x873Ea710B6b289b0e9D6867B1630066e9721B5c9) | [View](https://sepolia.basescan.org/address/0x873Ea710B6b289b0e9D6867B1630066e9721B5c9) |
| GuildFactory | [`0xfeae3538a4a1801e47b6d16104aa8586edb55f00`](https://sepolia.basescan.org/address/0xfeae3538a4a1801e47b6d16104aa8586edb55f00) | [View](https://sepolia.basescan.org/address/0xfeae3538a4a1801e47b6d16104aa8586edb55f00) |
| ReputationAttestations | [`0xedae9682a0fb6fb3c18d6865461f67db7d748002`](https://sepolia.basescan.org/address/0xedae9682a0fb6fb3c18d6865461f67db7d748002) | [View](https://sepolia.basescan.org/address/0xedae9682a0fb6fb3c18d6865461f67db7d748002) |
| DisputeResolver | [`0xb00ac4278129928aecc72541b0bcd69d94c1691e`](https://sepolia.basescan.org/address/0xb00ac4278129928aecc72541b0bcd69d94c1691e) | [View](https://sepolia.basescan.org/address/0xb00ac4278129928aecc72541b0bcd69d94c1691e) |
| HorizonAchievements | [`0x568e0e3102bfa1f4045d3f62559c0f9823b469bc`](https://sepolia.basescan.org/address/0x568e0e3102bfa1f4045d3f62559c0f9823b469bc) | [View](https://sepolia.basescan.org/address/0x568e0e3102bfa1f4045d3f62559c0f9823b469bc) |

### External Dependencies

| Token | Address | BaseScan |
|-------|---------|----------|
| USDC (Circle) | [`0x036CbD53842c5426634e7929541eC2318f3dCF7e`](https://sepolia.basescan.org/address/0x036CbD53842c5426634e7929541eC2318f3dCF7e) | [View](https://sepolia.basescan.org/address/0x036CbD53842c5426634e7929541eC2318f3dCF7e) |

### Protocol Owner

| Identity | Address |
|----------|---------|
| [jollyv.eth](https://app.ens.domains/jollyv.eth) / [jollyv.base.eth](https://basenames.xyz/name/jollyv.base.eth) | [`0x2b30efBA367D669c9cd7723587346a79b67A42DB`](https://sepolia.basescan.org/address/0x2b30efBA367D669c9cd7723587346a79b67A42DB) |

---

## Base Mainnet (Chain ID: 8453)

> **Status:** Not yet deployed. Coming soon after security audit.

---

## Fee Structure

| Fee Type | Percentage | Recipient |
|----------|------------|-----------|
| Protocol Fee | 4% | Protocol Treasury |
| Labs Fee | 4% | Labs Treasury |
| Resolver Fee | 2% | Resolver Treasury |
| Guild Fee | 0-15% (variable) | Guild Treasury |
| Performer | 90% - guildFee | Performer |

### Dispute Resolution Fees

| Fee Type | Percentage | Description |
|----------|------------|-------------|
| DDR (Dynamic Dispute Reserve) | 5% | Deposited by both parties when dispute is raised |
| LPP (Loser-Pays Penalty) | 2% | Penalty redistributed to winner + resolver |
| Appeal Period | 48 hours | Time before dispute can be finalized |

---

## Verification

All contracts are verified on BaseScan. To verify the source code matches:

```bash
# Clone the repository
git clone https://github.com/horizon-labs/horizon-contracts.git
cd horizon-contracts

# Install dependencies
forge install

# Verify compilation matches
forge verify-check <address> --chain-id 84532
```

---

## Environment Variables

For application integration, use these environment variables:

```env
# Base Sepolia Testnet
NEXT_PUBLIC_PAYMENT_ROUTER_ADDRESS=0x94fb7908257ec36f701d2605b51eefed4326ddf5
NEXT_PUBLIC_MISSION_FACTORY_ADDRESS=0xee9234954b134c39c17a75482da78e46b16f466c
NEXT_PUBLIC_GUILD_FACTORY_ADDRESS=0xfeae3538a4a1801e47b6d16104aa8586edb55f00
NEXT_PUBLIC_REPUTATION_ATTESTATIONS_ADDRESS=0xedae9682a0fb6fb3c18d6865461f67db7d748002
NEXT_PUBLIC_DISPUTE_RESOLVER_ADDRESS=0xb00ac4278129928aecc72541b0bcd69d94c1691e
NEXT_PUBLIC_ACHIEVEMENTS_ADDRESS=0x568e0e3102bfa1f4045d3f62559c0f9823b469bc
NEXT_PUBLIC_USDC_ADDRESS=0x036CbD53842c5426634e7929541eC2318f3dCF7e
NEXT_PUBLIC_RPC_URL=https://sepolia.base.org
```

---

*Last updated: December 27, 2025*


