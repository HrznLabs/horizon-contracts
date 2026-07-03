# AGENTS.md — horizon-contracts

Context for autonomous agents (Jules, etc.). Read this before planning. **These contracts secure real value — correctness over everything.**

## Stack
- **Foundry / Solidity 0.8.24**, `via_ir = true`, EVM: Cancun. Formatter: 100 cols, 4-space tabs, double quotes.
- Reference/standalone contracts repo (no app deploy pipeline of its own). Network: Base Sepolia.

## Commands
- Build: `forge build` · Test: `forge test -vvv` · Format: `forge fmt` · Gas: `forge snapshot`
- Fuzzing is configured (10k runs in CI, 50k for security). No yarn/npm/pnpm.

## Environment setup (Jules VM) — IMPORTANT
- **Foundry is NOT preinstalled** in the Jules VM. Any task MUST install it first:
  ```
  curl -L https://foundry.paradigm.xyz | bash && ~/.foundry/bin/foundryup
  export PATH="$HOME/.foundry/bin:$PATH"
  ```

## Git & PR rules (MANDATORY)
- **Branch FROM `staging`. Open PRs against `staging`. NEVER push to `main` or `staging` directly.**
- Never bypass pre-commit hooks. Never print secret/key values.

## Agent scope
- **No UI → the UX agent (Palette) does NOT apply.** Only Bolt and Sentinel run.
- **Bolt = GAS optimization ONLY**, and only behavior-preserving changes proven by a `forge snapshot` delta. Run the full `forge test` and confirm all pass. Never alter logic, storage layout, visibility, access control, or value-moving paths to save gas.
- **Sentinel is the primary agent here, and is ADVISORY-ONLY.** Never auto-edit contract logic. For each finding: describe it, cite exact lines, propose a fix, AND add a Forge PoC test demonstrating it; label `needs-human-review`. Assume your fix may be wrong — a human auditor decides. Look for: reentrancy, access control, unchecked external calls, fee/precision math (Decimal(18,6) domain), unsafe delegatecall, front-running/MEV, signature replay.
- Agent journals: `.jules/<agent>.md` (lowercase).
