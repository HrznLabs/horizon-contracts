## 2024-05-23 - Unprotected Critical Function in Proxy Implementation
**Vulnerability:** Found `settleDispute` in `MissionEscrow` (implementation contract) was completely unprotected, allowing any user to refund themselves or steal funds.
**Learning:** The error definition `NotDisputeResolver` existed in the interface but was not used in the implementation, suggesting the access control was intended but forgotten. Always verify that defined errors are actually used in logic.
**Prevention:** Use a checklist for "sensitive functions" (functions that move funds or change critical state) to ensure they have appropriate access control modifiers or checks. Verify against the interface definitions to ensure all intended restrictions are implemented.

## 2024-05-24 - State Transition Bypass via Expiration
**Vulnerability:** The `claimExpired` function in `MissionEscrow` allowed a poster to reclaim funds even if the mission was in `Disputed` state, as long as the expiration time had passed. This effectively allowed a poster to bypass the dispute resolution process.
**Learning:** State machines with time-based transitions (like expiration) must explicitly check against *all* conflicting states (like `Disputed` or `Submitted`), not just the obvious terminal states (`Completed`, `Cancelled`).
**Prevention:** When implementing time-based overrides (like "expire" or "timeout"), visualize the state machine and verify that the override does not invalidate active states that require human intervention.

## 2024-05-25 - Fail-Open Access Control in PaymentRouter
**Vulnerability:** The `onlyAuthorized` modifier in `PaymentRouter` was empty (no-op), allowing any caller to trigger `settlePayment` and drain funds if the router held any balance. Additionally, the initial fix had a "fail-open" risk where the check was skipped if `missionFactory` was not set.
**Learning:** Access control modifiers must always be "fail-closed". If a dependency (like `missionFactory`) is missing, the function should revert, not proceed without checks.
**Prevention:** When implementing access control that depends on external contract state, explicitly handle the uninitialized case by reverting. Use integration tests that verify both the "happy path" (initialized) and the "unhappy path" (uninitialized/misconfigured).
