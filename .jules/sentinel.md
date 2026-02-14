## 2024-05-23 - Unprotected Critical Function in Proxy Implementation
**Vulnerability:** Found `settleDispute` in `MissionEscrow` (implementation contract) was completely unprotected, allowing any user to refund themselves or steal funds.
**Learning:** The error definition `NotDisputeResolver` existed in the interface but was not used in the implementation, suggesting the access control was intended but forgotten. Always verify that defined errors are actually used in logic.
**Prevention:** Use a checklist for "sensitive functions" (functions that move funds or change critical state) to ensure they have appropriate access control modifiers or checks. Verify against the interface definitions to ensure all intended restrictions are implemented.

## 2024-05-24 - State Transition Bypass via Expiration
**Vulnerability:** The `claimExpired` function in `MissionEscrow` allowed a poster to reclaim funds even if the mission was in `Disputed` state, as long as the expiration time had passed. This effectively allowed a poster to bypass the dispute resolution process.
**Learning:** State machines with time-based transitions (like expiration) must explicitly check against *all* conflicting states (like `Disputed` or `Submitted`), not just the obvious terminal states (`Completed`, `Cancelled`).
**Prevention:** When implementing time-based overrides (like "expire" or "timeout"), visualize the state machine and verify that the override does not invalidate active states that require human intervention.

## 2024-05-25 - Empty Access Control Modifier
**Vulnerability:** The `onlyAuthorized` modifier in `PaymentRouter` was empty, containing only a comment `// For now, allow any caller for testing`, allowing any user to drain funds via `settlePayment`.
**Learning:** Placeholder code from development/testing phases can easily slip into production if not explicitly tracked or if tests don't cover negative cases (unauthorized access).
**Prevention:** Never commit empty modifiers or "allow all" logic to the main branch. Use environment variables or build flags if testing logic differs, or better yet, mock the authorization in tests instead of weakening the production code.

## 2024-05-26 - Dispute Resolution Deadlock
**Vulnerability:** Found `DisputeResolver` required DDR deposits from BOTH parties before allowing `resolveDispute`. If one party refused to participate, the dispute was deadlocked.
**Learning:** "Skin in the game" mechanisms must handle non-participation gracefully. Never let a refusal to participate block the resolution process.
**Prevention:** Design state machines where every state has a path forward (e.g., default judgment) even if some actors go silent.
