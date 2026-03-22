## 2024-03-03 - [Storage Pointer Optimization]
**Learning:** Using storage pointers for struct manipulation is a highly effective optimization in Solidity, especially for multiple writes to the same mapping element. `PackedRating storage rating = _ratings[...]` avoids memory-to-storage copies and redundant mapping lookups.
**Action:** Always prefer storage pointers when updating multiple fields of a struct located in storage, rather than loading the whole struct into memory, modifying it, and writing it back to storage.

## 2025-01-20 - [Storage Pointer Caching]
**Learning:** Caching fields retrieved through storage pointers (like struct fields `dispute.poster`) into local memory variables before multiple accesses prevents multiple expensive `SLOAD` operations and reduces gas consumption. Even though it's a storage pointer, each field access triggers an SLOAD.
**Action:** Always cache struct members accessed through storage pointers if they are read more than once in a function.
