## 2024-05-22 - Specific Authorization Errors improve DX
**Learning:** Generic 'InvalidState' errors for authorization failures confuse developers/integrators about whether the contract is in the wrong state or the user is unauthorized.
**Action:** Always check if an error condition is about "who you are" vs "what state the system is in" and use specific errors (e.g. `NotParty`, `Unauthorized`) for the former.
