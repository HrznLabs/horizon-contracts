## 2024-03-03 - [Storage Pointer Optimization]
**Learning:** Using storage pointers for struct manipulation is a highly effective optimization in Solidity, especially for multiple writes to the same mapping element. `PackedRating storage rating = _ratings[...]` avoids memory-to-storage copies and redundant mapping lookups.
**Action:** Always prefer storage pointers when updating multiple fields of a struct located in storage, rather than loading the whole struct into memory, modifying it, and writing it back to storage.

## 2024-03-24 - [Storage SLOAD Deferral Optimization]
**Learning:** Caching storage variables into memory outside of conditional blocks is a de-optimization if the variables are only used within those blocks, as it forces unconditional SLOAD gas usage. Similarly, reading properties from a struct storage pointer multiple times incurs multiple SLOADs.
**Action:** Defer caching storage variables inside the specific conditional blocks where they are used to avoid unnecessary SLOADs. Always cache struct properties (e.g., `dispute.poster`) into local stack variables before accessing them multiple times.
## $(date +%Y-%m-%d) - Explicit Casting of Packed Storage Variables When Caching
**Learning:** In Solidity, caching packed storage variables (like `uint96`) into local stack memory variables without explicitly casting them to `uint256` incurs hidden EVM gas overhead. The EVM performs continuous bitwise masking operations every time those variables are referenced in subsequent operations or arithmetic.
**Action:** When caching smaller packed storage variables to stack variables, immediately and explicitly cast them to `uint256` (e.g., `uint256 rewardAmount = uint256(_rewardAmount);`) to avoid repetitive EVM bitwise masking overhead and demonstrably save gas.
