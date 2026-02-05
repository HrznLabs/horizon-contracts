## 2024-05-23 - Critical Access Control Vulnerability in Escrow
**Vulnerability:** Found `settleDispute` function in `MissionEscrow.sol` was `external` and lacked any access control, allowing anyone to settle disputes and potentially steal funds.
**Learning:** Comments indicating "TODO: Add access control" are major red flags. Clone patterns make passing dependencies (like `DisputeResolver`) tricky if not planned for in the factory/initializer.
**Prevention:** Always implement access control immediately, even if using placeholders. Use `restricted` or specific role modifiers on all state-changing external functions. Review initialization logic for clones carefully to ensure all trusted parties are known.
