## 2024-03-03 - [Storage Pointer Optimization]
**Learning:** Using storage pointers for struct manipulation is a highly effective optimization in Solidity, especially for multiple writes to the same mapping element. `PackedRating storage rating = _ratings[...]` avoids memory-to-storage copies and redundant mapping lookups.
**Action:** Always prefer storage pointers when updating multiple fields of a struct located in storage, rather than loading the whole struct into memory, modifying it, and writing it back to storage.
## 2024-06-12 - Caching State Variables in Internal View Functions
**Learning:** In Solidity, caching a frequently accessed state variable (like `missionFactory`) into a local stack variable inside internal helper functions (such as `_isFactoryEscrow`) that are called multiple times via modifiers avoids redundant secondary `SLOAD` operations, measurably reducing gas consumption without affecting logic.
**Action:** Always scan internal view helpers that retrieve state variables for multi-use patterns (e.g., checking for zero-address before making an external call on the same address). Cache the state variable to a local stack variable to save gas.
## 2024-07-28 - Dead code removal in Revocation Flows
**Learning:** Removing redundant operations that perform state mapping lookups (like OpenZeppelin's `_revokeRole` for roles that already trigger an early revert via `hasRole`) saves gas by avoiding dead code execution and reducing execution cost.
**Action:** Review revocation and state transition functions for redundant checks and actions that can be proven unreachable via early returns or reverts. Remove the dead code to save gas.
