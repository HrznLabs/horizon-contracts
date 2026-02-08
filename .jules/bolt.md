## 2024-05-23 - Immutable Variables in Minimal Proxies
**Learning:** EIP-1167 Minimal Proxies (Clones) delegate calls to an implementation contract. Immutable variables in the implementation contract are embedded in its bytecode and are accessible to clones without storage reads. This is highly efficient for values constant across all clones (like the factory-scoped USDC address).
**Action:** When optimizing factory-spawned contracts, check if any storage variables are constant for a given factory deployment and move them to immutable variables in the implementation contract.
