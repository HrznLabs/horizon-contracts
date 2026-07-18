## 2024-07-18 - Missing Deadline Enforcement on Proof Submission

**Vulnerability:** Missing `notExpired` modifier on the `submitProof` functions in `MissionEscrow.sol` and `DeliveryEscrow.sol`.
**Learning:** Overridden functions in child contracts (like `DeliveryEscrow`) do not automatically inherit modifiers from their parent contract (`MissionEscrow`), meaning any critical state checks present in the parent must be explicitly re-implemented. Furthermore, a failure to apply time constraints to state transition functions allowed performers to bypass deadlines indefinitely.
**Prevention:** Always verify that time constraints (e.g., deadlines/expirations) are applied to all functions that transition a contract into a protected or locked state, ensuring actors cannot indefinitely stall refund mechanisms. Explicitly reapply necessary constraints when overriding functions.
