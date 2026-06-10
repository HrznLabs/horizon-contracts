## 2024-03-03 - [Storage Pointer Optimization]
**Learning:** Using storage pointers for struct manipulation is a highly effective optimization in Solidity, especially for multiple writes to the same mapping element. `PackedRating storage rating = _ratings[...]` avoids memory-to-storage copies and redundant mapping lookups.
**Action:** Always prefer storage pointers when updating multiple fields of a struct located in storage, rather than loading the whole struct into memory, modifying it, and writing it back to storage.

## 2024-03-24 - [Storage SLOAD Deferral Optimization]
**Learning:** Caching storage variables into memory outside of conditional blocks is a de-optimization if the variables are only used within those blocks, as it forces unconditional SLOAD gas usage. Similarly, reading properties from a struct storage pointer multiple times incurs multiple SLOADs.
**Action:** Defer caching storage variables inside the specific conditional blocks where they are used to avoid unnecessary SLOADs. Always cache struct properties (e.g., `dispute.poster`) into local stack variables before accessing them multiple times.
## 2026-04-10 - Explicit Casting of Packed Storage Variables When Caching
**Learning:** In Solidity, caching packed storage variables (like `uint96`) into local stack memory variables without explicitly casting them to `uint256` incurs hidden EVM gas overhead. The EVM performs continuous bitwise masking operations every time those variables are referenced in subsequent operations or arithmetic.
**Action:** When caching smaller packed storage variables to stack variables, immediately and explicitly cast them to `uint256` (e.g., `uint256 rewardAmount = uint256(_rewardAmount);`) to avoid repetitive EVM bitwise masking overhead and demonstrably save gas.
## 2024-04-10 - Use Storage Pointers for Redundant Mapping Lookups
**Learning:** Accessing a struct via a mapping lookup multiple times (e.g. `_members[member]`) inside a function like `removeMember` wastes gas due to multiple KECCAK256 operations for the storage slot evaluation.
**Action:** Declare a local storage pointer (e.g. `GuildMember storage m = _members[member];`) to cache the mapping reference. This avoids redundant mapping lookups and significantly reduces gas consumption.
## 2026-04-10 - Batched SLOADs/SSTOREs via Memory Structs
**Learning:** While storage pointers (e.g., `PackedRating storage rating = ...`) avoid memory-to-storage copy overhead for large structs spanning multiple slots, updating multiple fields of a tightly packed struct that fits entirely in a single slot (like `RatingStats`) is more gas-efficient when copied to `memory` first. Updating the `memory` struct locally and then writing the entire struct back to storage batches the `SLOAD` and `SSTORE` operations on that single slot, saving significant gas compared to in-place direct modifications which trigger repeated storage accesses. Furthermore, caching struct members to local stack variables before updating them (e.g., `uint128 c = stats.count; stats.count = c + 1;`) is a fake optimization that does not save `SLOAD` operations compared to direct modification (e.g., `stats.count++`).
**Action:** When updating multiple fields of a single-slot packed struct, copy the struct to `memory`, update the fields, and assign it back to the mapping to batch the storage slot accesses and save gas. Avoid caching values to stack variables if they are only read once.
## 2024-05-18 - [Mapping Pointer Optimization]
**Learning:** In Solidity, assigning a struct from a mapping to a storage pointer (e.g., `GuildMember storage m = _members[member]`) rather than checking `if (_members[member].isMember)` and then re-assigning the whole struct, significantly saves gas by avoiding redundant hashing of the mapping key.
**Action:** Always prefer using a storage pointer to update mappings when modifying struct fields, and add comments explaining the specific optimization rationale.
## 2024-05-19 - [Cache struct field to avoid SLOADs]
**Learning:** In Solidity, accessing a struct member multiple times via a storage pointer causes multiple `SLOAD` operations.
**Action:** When a struct field stored in a mapping is accessed multiple times within a block of code, assign it to a local stack variable to batch read and save gas. For example, instead of doing `achievement.typeId` multiple times, cache `uint32 typeId = achievement.typeId;`.

## 2024-05-04 - Memory struct optimization de-optimization for small structs
**Learning:** While copying tightly packed single-slot structs to `memory` before updating saves gas (batching SLOAD/SSTORE), applying this pattern to extremely small structs that fit in a single storage slot (like `GuildMember` which is 17 bytes: bool + uint64 + uint64) is a de-optimization if the struct isn't updating all its members or the Solidity compiler's optimizer already efficiently caches and batches single-slot updates when accessed via a storage pointer. Copying to memory just adds `MSTORE` overhead and increases gas usage.
**Action:** Do not use the `memory` struct batching pattern for small structs that easily fit entirely within a single storage slot; just use a storage pointer.
## 2024-05-20 - [State Variable Cache Optimization]
**Learning:** In Solidity, accessing a state variable multiple times within a block of code (or modifier) causes multiple `SLOAD` operations. This happens in the `PaymentRouter`'s `onlyAuthorized` modifier where `missionFactory` is accessed to check if it's not address 0, and then again to call `IMissionFactory(missionFactory).getMission(missionId)`.
**Action:** When a state variable is accessed multiple times within a block of code or modifier, assign it to a local stack variable to batch read and save gas. For example, instead of accessing `missionFactory` multiple times, cache it using `address _missionFactory = missionFactory;`.

## $(date +%Y-%m-%d) - Single-slot Struct Storage Pointer vs Memory Copy
**Learning:** While copying multi-slot or dynamic structs to `memory` before updating can save gas by batching `SLOAD` and `SSTORE` operations, applying this pattern to extremely small structs that fit entirely in a single storage slot (like `RatingStats` with two `uint128`s) is a de-optimization. The Solidity optimizer handles single-slot updates very efficiently directly via storage pointers. In `ReputationAttestations.sol`, copying `RatingStats` to `memory` and assigning it back added `MSTORE` overhead, costing ~131 extra gas per call.
**Action:** Always use `storage` pointers for updating structs that pack into a single 32-byte slot. Only copy to `memory` when updating multiple fields across multiple slots.
## 2026-05-19 - [Dead Code Elimination]
**Learning:** In Solidity, if a function reverts early under specific conditions (e.g., if a user has a certain role), any subsequent checks or logic relying on that condition being true in the same function are dead code.
**Action:** Always verify that trailing logic blocks (like role revocation) do not redundantly check conditions that were already used to filter out execution earlier in the function.
## 2026-05-26 - [Cache state variable inside conditional to avoid redundant SLOADs]
**Learning:** Accessing a state variable multiple times within a conditional block causes multiple `SLOAD` operations. In `MissionFactory.sol`, `guildFactory` was read multiple times if a guild was provided.
**Action:** When a state variable is accessed multiple times within a conditional block, assign it to a local stack variable to batch read and save gas. Example: `address _guildFactory = guildFactory;`.
## 2024-05-24 - Single-Slot Struct Memory Copy Overhead in View Functions
**Learning:** Copying a single-slot struct (e.g., `GuildMember` packed into 17 bytes) from storage to `memory` in a `view` function before returning its fields is a gas de-optimization. The Solidity compiler handles single-slot reads efficiently via bit-masking directly from the single `SLOAD`, so caching to `memory` only adds unnecessary `MSTORE` and memory expansion overhead (~116 gas).
**Action:** Always use `storage` pointers for reading small, single-slot structs in view functions instead of defining them as `memory` copies.
## 2026-06-10 - Single-slot Struct View Optimization
**Learning:** Copying a single-slot struct (like `RatingStats`) from storage to `memory` inside a view function adds unnecessary `MSTORE`/`MLOAD` gas overhead. The Solidity compiler optimally handles reading fields from single-slot structs directly from storage via bit-masking.
**Action:** Always prefer using a `storage` pointer for small, single-slot structs in view functions to avoid `memory` expansion and copying overhead.
