## 2025-02-07 - Improved Contract Error Messages
**Learning:** Smart contract error messages are UX too. Generic errors like `InvalidRewardAmount` block users from understanding why their transaction failed. By adding parameters (e.g. min/max values) to custom errors, we enable frontends to display specific, actionable feedback.
**Action:** When working on smart contracts, always include relevant context parameters in custom errors to empower better frontend error handling.

## 2025-02-08 - Documentation as Interface
**Learning:** For backend projects, the README is the UI. Static contract addresses force context switching (copy-paste), while clickable links keep developers in flow.
**Action:** Always hyperlink contract addresses to block explorers in documentation.

## 2025-02-09 - Environment Configuration Standards
**Learning:** Manual environment variable setup via `export` commands creates friction and is error-prone. Standardizing on `.env.example` significantly improves the onboarding experience (DX) and reduces setup errors.
**Action:** Always include a documented `.env.example` file for backend projects to streamline local development setup.

## 2026-02-12 - Visual Accessibility in Documentation
**Learning:** ASCII art diagrams are inaccessible to screen readers and difficult to maintain. Using Mermaid diagrams provides semantic structure and native rendering support on platforms like GitHub.
**Action:** Replace complex ASCII diagrams with Mermaid sequence or flow charts in documentation.

## 2026-02-13 - Deep Linking for Developer Efficiency
**Learning:** Developers often need to verify contract source code, not just view the address state. Linking directly to the `#code` tab on block explorers saves a click and reduces friction for reviewers and integrators.
**Action:** Append `#code` to block explorer links when the intent is to show the verified contract source.

## 2026-02-14 - Documentation as First-Time UX
**Learning:** For backend repositories, the README is the user's first interaction. Providing immediate utility (like network setup and faucet links) reduces friction and improves the "onboarding UX".
**Action:** When optimizing backend repos, look for friction points in the "Getting Started" flow and add direct links/instructions to external dependencies (faucets, RPCs).

## 2026-02-15 - Joyful Command Line Interfaces
**Learning:** Command line tools are often purely utilitarian. Adding visual cues (emojis) to `make help` or CLI outputs improves scannability and adds a touch of delight for developers.
**Action:** When creating CLI help text, use icons to categorize commands and improve visual hierarchy.

## 2026-02-27 - Contextual State Errors
**Learning:** Generic `InvalidState` errors in smart contracts are a black box for frontend developers, forcing them to guess why a transaction failed. Returning `InvalidState(CurrentState)` provides immediate context, allowing the UI to explain *why* an action is blocked (e.g., "Mission is already Submitted" vs "Mission is Expired").
**Action:** Always include the current state as a parameter in state-related custom errors.
