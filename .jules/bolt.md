## 2026-02-09 - [MissionFactory Storage Packing]
**Learning:** `MissionFactory` uses `uint96` for `missionCount` to pack with `address disputeResolver` in a single storage slot. This saves ~20k gas on deployment and ~2.1k gas on every mission creation (due to warm slot access).
**Action:** When adding state variables to factories or frequently used contracts, always check if they can be packed with existing variables by adjusting types (e.g., `uint256` -> `uint96`).
