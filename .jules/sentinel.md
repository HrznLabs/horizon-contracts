## 2024-05-24 - [Duplicate Error Definition]
**Vulnerability:** Duplicate error definition `error NotParty();` in `src/interfaces/IMissionEscrow.sol`.
**Learning:** Found duplicate error definitions during tests.
**Prevention:** Make sure interfaces and contracts don't declare the same error/event twice.
