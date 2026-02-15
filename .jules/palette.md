## 2025-02-07 - Improved Contract Error Messages
**Learning:** Smart contract error messages are UX too. Generic errors like `InvalidRewardAmount` block users from understanding why their transaction failed. By adding parameters (e.g. min/max values) to custom errors, we enable frontends to display specific, actionable feedback.
**Action:** When working on smart contracts, always include relevant context parameters in custom errors to empower better frontend error handling.

## 2025-02-08 - Documentation as Interface
**Learning:** For backend projects, the README is the UI. Static contract addresses force context switching (copy-paste), while clickable links keep developers in flow.
**Action:** Always hyperlink contract addresses to block explorers in documentation.

## 2026-02-12 - Visual Accessibility in Documentation
**Learning:** ASCII art diagrams are inaccessible to screen readers and difficult to maintain. Using Mermaid diagrams provides semantic structure and native rendering support on platforms like GitHub.
**Action:** Replace complex ASCII diagrams with Mermaid sequence or flow charts in documentation.
