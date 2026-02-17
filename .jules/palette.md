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
