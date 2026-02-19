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

## 2024-05-26 - Late Submission Blocking Refund
**Vulnerability:** The `submitProof` function in `MissionEscrow` allowed submissions after `expiresAt`, transitioning the state to `Submitted`. This prevented the poster from calling `claimExpired` (which reverts if `Submitted`), effectively allowing a performer to block a refund indefinitely or force a dispute even after missing the deadline.
**Learning:** Time-based deadlines must be enforced on *all* relevant state transitions. If one party can act after the deadline to change the state to a "protected" one, they can hold the other party hostage.
**Prevention:** Ensure that actions that transition state from "Open/Accepted" to "Submitted/Completed" have an explicit `notExpired` check if an expiration mechanism exists.

## 2025-05-26 - Bypass of Appeal Process in DisputeResolver
**Vulnerability:** `finalizeDispute` function explicitly allowed `Appealed` state to bypass the appeal process and finalize with the original outcome, ignoring the DAO override mechanism.
**Learning:** Complex conditional logic (`else if (!appealed)`) can accidentally invert the intended security check. The comment `// Appealed disputes are finalized by DAO override` indicated the intent, but the code did the opposite.
**Prevention:** Use positive checks (`if (state == Resolved)`) rather than negative checks (`if (state != Appealed)`), and always test state transitions explicitly, especially for "stuck" or "waiting" states like appeals.

## 2024-05-26 - Dispute Resolution Deadlock
**Vulnerability:** Found `DisputeResolver` required DDR deposits from BOTH parties before allowing `resolveDispute`. If one party refused to participate, the dispute was deadlocked.
**Learning:** "Skin in the game" mechanisms must handle non-participation gracefully. Never let a refusal to participate block the resolution process.
**Prevention:** Design state machines where every state has a path forward (e.g., default judgment) even if some actors go silent.

## 2024-05-26 - Fee Bypass in Dispute Settlement
**Vulnerability:** The `settleDispute` function in `MissionEscrow` directly transferred 100% of the reward to the performer if they won, bypassing the `PaymentRouter` fees (10%). This created a perverse incentive for performers to dispute every mission.
**Learning:** Replicating logic ("simple version") instead of reusing existing secure components (`PaymentRouter`) often leads to inconsistent behavior and security gaps.
**Prevention:** Always reuse established payment routing logic for fund distribution. Avoid "short-circuiting" logic for special cases if it means bypassing standard fees or checks.
## 2025-06-15 - [Reputation System Bypass]
**Vulnerability:** The `ReputationAttestations.submitRating` function allowed any address to rate any other address for any mission ID without verifying participation or mission completion, enabling trivial reputation falsification.
**Learning:** The vulnerability existed because the contract relied on the caller to provide correct parameters (missionId, ratee) but did not validate them against the source of truth (MissionFactory/Escrow).
**Prevention:** Always cross-reference user input against authoritative registries (like MissionFactory) and verify state/participation in related contracts before allowing state changes.

## 2025-06-16 - [Unauthorized Event Emission]
**Vulnerability:** The `ReputationAttestations.recordOutcome` function was publicly accessible, allowing any address to emit `MissionOutcomeRecorded` events with arbitrary data, potentially corrupting off-chain indexers.
**Learning:** Functions intended for "trusted callers only" (like other contracts) often lack enforcement mechanisms if the system architecture doesn't provide a clear way to verify the caller (e.g., dynamic proxies).
**Prevention:** Implement strict access control by verifying the caller against a factory or registry (e.g., `MissionFactory.getMission(id) == msg.sender`) for dynamic contract interactions.
