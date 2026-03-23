## 2024-03-03 - [Storage Pointer Optimization]
**Learning:** Using storage pointers for struct manipulation is a highly effective optimization in Solidity, especially for multiple writes to the same mapping element. `PackedRating storage rating = _ratings[...]` avoids memory-to-storage copies and redundant mapping lookups.
**Action:** Always prefer storage pointers when updating multiple fields of a struct located in storage, rather than loading the whole struct into memory, modifying it, and writing it back to storage.
## 2024-05-19 - [Local Variable Access Optimization in Struct Initialization]
**Learning:** Initializing a struct with a member from another struct directly inside the initialization block (e.g. `lppAmount: (params.rewardAmount * LPP_RATE_BPS) / 10_000`) uses slightly more gas than assigning that member to a local variable first (e.g. `uint256 rewardAmount = params.rewardAmount;`) and using the local variable.
**Action:** When initializing a struct or repeatedly reading a struct member retrieved from memory (like `params.rewardAmount`), cache it in a local variable before using it to save gas.
