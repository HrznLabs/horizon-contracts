## 2026-02-09 - [MissionFactory Storage Packing]
**Learning:** `MissionFactory` uses `uint96` for `missionCount` to pack with `address disputeResolver` in a single storage slot. This saves ~20k gas on deployment and ~2.1k gas on every mission creation (due to warm slot access).
**Action:** When adding state variables to factories or frequently used contracts, always check if they can be packed with existing variables by adjusting types (e.g., `uint256` -> `uint96`).

## 2026-02-10 - [GuildFactory Storage Packing]
**Learning:** Applied `uint96` packing pattern to `GuildFactory.guildCount`, saving ~16.7k gas per guild creation. Verified that `Ownable`'s `_owner` (Slot 0) packs correctly with the subclass variable if sizes allow.
**Action:** Audit all factory contracts for `uint256` counters that can be reduced to `uint96` to share slots with addresses.

## 2026-02-12 - [Whitelist vs Blacklist State Checks]
**Learning:** In state machines, checking against a whitelist of allowed states (e.g., `Open` or `Accepted`) is safer and cheaper than blacklisting forbidden states. It automatically handles undefined or new states (e.g., `None` or future states), preventing bypasses.
**Action:** Always prefer whitelist checks for critical state transitions to save gas and improve security.

## 2026-02-14 - [NFT Storage Packing Pattern]
**Learning:** Using separate storage-optimized structs (e.g., `uint32` type IDs, `uint64` timestamps, packed booleans) while keeping the original external structs for ABI compatibility saved ~22% gas per mint (112k gas). This pattern allows massive storage savings without breaking existing integrations.
**Action:** When optimizing existing structs with large fields (e.g., `uint256`), create a parallel internal `Storage` struct with smaller types to pack data tightly, then map it back to the original struct for external views to preserve ABI.

## 2025-02-16 - ReputationAttestations Storage Packing
**Learning:** Replacing separate public mappings for related counters (count/sum) with a single private mapping to a packed struct (uint128/uint128) saves ~20k gas per write (1 SSTORE instead of 2). However, to preserve ABI compatibility, manual getter functions matching the original mapping signature must be added.
**Action:** Look for related counters in other contracts (e.g., totalRewards/totalMissions) and pack them if they fit in 256 bits, ensuring getters are preserved.
