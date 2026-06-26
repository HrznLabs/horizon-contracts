## 2024-03-03 - [Storage Pointer Optimization]
**Learning:** Using storage pointers for struct manipulation is a highly effective optimization in Solidity, especially for multiple writes to the same mapping element. `PackedRating storage rating = _ratings[...]` avoids memory-to-storage copies and redundant mapping lookups.
**Action:** Always prefer storage pointers when updating multiple fields of a struct located in storage, rather than loading the whole struct into memory, modifying it, and writing it back to storage.
## 2024-06-12 - Caching State Variables in Internal View Functions
**Learning:** In Solidity, caching a frequently accessed state variable (like `missionFactory`) into a local stack variable inside internal helper functions (such as `_isFactoryEscrow`) that are called multiple times via modifiers avoids redundant secondary `SLOAD` operations, measurably reducing gas consumption without affecting logic.
**Action:** Always scan internal view helpers that retrieve state variables for multi-use patterns (e.g., checking for zero-address before making an external call on the same address). Cache the state variable to a local stack variable to save gas.
