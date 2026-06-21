## 2024-03-03 - [Storage Pointer Optimization]
**Learning:** Using storage pointers for struct manipulation is a highly effective optimization in Solidity, especially for multiple writes to the same mapping element. `PackedRating storage rating = _ratings[...]` avoids memory-to-storage copies and redundant mapping lookups.
**Action:** Always prefer storage pointers when updating multiple fields of a struct located in storage, rather than loading the whole struct into memory, modifying it, and writing it back to storage.
## 2024-06-21 - [State Variable Caching in Finalization Logic]
**Learning:** In Solidity, caching a storage variable (like `dispute.outcome`) into a local stack variable is critical when that variable is read multiple times within a function, such as in an `if-else` chain or when passed to external calls. Even within a storage pointer reference, each read triggers a warm SLOAD which costs 100 gas.
**Action:** When working with struct storage pointers in complex finalization/distribution logic (e.g. `_distributeFunds`), proactively cache frequently accessed fields to the stack to prevent redundant SLOADs across conditional branches and event emissions.
