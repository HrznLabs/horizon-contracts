## 2025-02-07 - Improved Contract Error Messages
**Learning:** Smart contract error messages are UX too. Generic errors like `InvalidRewardAmount` block users from understanding why their transaction failed. By adding parameters (e.g. min/max values) to custom errors, we enable frontends to display specific, actionable feedback.
**Action:** When working on smart contracts, always include relevant context parameters in custom errors to empower better frontend error handling.

## 2025-02-07 - Specific Authorization Errors
**Learning:** Using generic errors like `InvalidState` for authorization failures confuses users. A specific error like `NotParty` clearly communicates that the user is not authorized, distinguishing it from a state machine error.
**Action:** Replace generic `InvalidState` reverts with specific authorization errors (e.g. `NotParty`, `NotAdmin`) to improve clarity.
