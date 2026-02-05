## 2024-05-23 - Unprotected Critical Function in Proxy Implementation
**Vulnerability:** Found `settleDispute` in `MissionEscrow` (implementation contract) was completely unprotected, allowing any user to refund themselves or steal funds.
**Learning:** The error definition `NotDisputeResolver` existed in the interface but was not used in the implementation, suggesting the access control was intended but forgotten. Always verify that defined errors are actually used in logic.
**Prevention:** Use a checklist for "sensitive functions" (functions that move funds or change critical state) to ensure they have appropriate access control modifiers or checks. Verify against the interface definitions to ensure all intended restrictions are implemented.
