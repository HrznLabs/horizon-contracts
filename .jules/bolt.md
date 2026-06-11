## 2024-03-03 - [Storage Pointer Optimization]
**Learning:** Using storage pointers for struct manipulation is a highly effective optimization in Solidity, especially for multiple writes to the same mapping element. `PackedRating storage rating = _ratings[...]` avoids memory-to-storage copies and redundant mapping lookups.
**Action:** Always prefer storage pointers when updating multiple fields of a struct located in storage, rather than loading the whole struct into memory, modifying it, and writing it back to storage.
