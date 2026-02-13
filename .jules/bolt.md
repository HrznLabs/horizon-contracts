## 2026-02-09 - [MissionFactory Storage Packing]
**Learning:** `MissionFactory` uses `uint96` for `missionCount` to pack with `address disputeResolver` in a single storage slot. This saves ~20k gas on deployment and ~2.1k gas on every mission creation (due to warm slot access).
**Action:** When adding state variables to factories or frequently used contracts, always check if they can be packed with existing variables by adjusting types (e.g., `uint256` -> `uint96`).

## 2026-02-10 - [GuildFactory Storage Packing]
**Learning:** Applied  packing pattern to , saving ~16.7k gas per guild creation. Verified that 's  (Slot 0) packs correctly with the subclass variable if sizes allow.
**Action:** Audit all factory contracts for  counters that can be reduced to  to share slots with addresses.

## 2026-02-10 - [GuildFactory Storage Packing]
**Learning:** Applied `uint96` packing pattern to `GuildFactory.guildCount`, saving ~16.7k gas per guild creation. Verified that `Ownable`'s `_owner` (Slot 0) packs correctly with the subclass variable if sizes allow.
**Action:** Audit all factory contracts for `uint256` counters that can be reduced to `uint96` to share slots with addresses.
