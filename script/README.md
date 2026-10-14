# Base Sepolia redeploy runbook: guild + delivery contracts

Reproducible redeploy of the two contract sets that drifted from source on Base Sepolia:

| Set               | Script                          | Why redeploy                                                                                                                                                                                                                                       |
| ----------------- | ------------------------------- | -------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| Delivery vertical | `DeployDeliveryContracts.s.sol` | Live `DeliveryMissionFactory` (`0x77DD51c6…`) is a pre-audit build: no `disputeResolver()`, no `getMissionByEscrow()`. The iTake `PaymentRouter` (`0x53940877…`) has `missionFactory() == address(0)`, so **no delivery escrow can settle** today. |
| Guilds            | `RedeployGuildFactory.s.sol`    | Live `GuildFactory` (`0xB54795f8…`) embeds the pre-#949 `GuildDAO` implementation (removeMember role revocation / last-admin guard missing).                                                                                                       |

Both scripts are **env-driven** (no hardcoded addresses), **fail fast** on a dead dependency, and
**work without a private key** so the exact broadcast can be simulated first with `--sender`.

## 0. Prerequisites

```bash
cd packages/contracts
export PATH=$HOME/.foundry/bin:$PATH        # forge >= 1.5
forge build

# Live Base Sepolia inputs (verified 2026-10-13)
export BASE_SEPOLIA_RPC_URL=https://sepolia.base.org
export PAYMENT_ROUTER=0x539408777865c7a3Ac702a350BEb4C04b8618eF2    # iTake PaymentRouter (has code, USDC accepted)
export DISPUTE_RESOLVER=0xdE37Ff10A487c852941DC842987dd8d5d8b9E855  # core DisputeResolver (has code)
export DELIVERIES_DAO=0xaB2F7787b72FcFfEA8E543375FE2db44D9C6ae53    # existing, kept (not redeployed)
export OLD_GUILD_FACTORY=0xB54795f8049De1acf729160bcD9184e50E4f267E
export ADMIN=0x2b30efBA367D669c9cd7723587346a79b67A42DB             # owner/admin of router, resolver, factories
```

Sanity checks before touching anything:

```bash
cast code $PAYMENT_ROUTER   --rpc-url $BASE_SEPOLIA_RPC_URL | wc -c   # > 3
cast code $DISPUTE_RESOLVER --rpc-url $BASE_SEPOLIA_RPC_URL | wc -c   # > 3
cast call $PAYMENT_ROUTER 'missionFactory()(address)' --rpc-url $BASE_SEPOLIA_RPC_URL           # 0x0 today
cast call $PAYMENT_ROUTER 'hasRole(bytes32,address)(bool)' 0x0000000000000000000000000000000000000000000000000000000000000000 $ADMIN --rpc-url $BASE_SEPOLIA_RPC_URL  # true
cast balance $ADMIN --rpc-url $BASE_SEPOLIA_RPC_URL --ether                                      # needs > ~0.001 ETH
```

Why the core `DisputeResolver` works for delivery escrows: `DisputeResolver.createDispute(escrow, …)`
takes any escrow address and only requires `escrow.getParams()/getRuntime()` (both inherited from
`MissionEscrow`) and `state == Disputed`; `_distributeFunds` calls `escrow.settleDispute`, which
`MissionEscrow.onlyDisputeResolver` authorises by `msg.sender == _disputeResolver`. The resolver does
**not** keep a factory/escrow allow-list, so no registration is needed on the resolver side; the
factory just has to pass the resolver address at escrow init (`setDisputeResolver`).

## 1. Dry run (no key, no broadcast) - do this first

```bash
unset DEPLOYER_PRIVATE_KEY

forge script script/DeployDeliveryContracts.s.sol \
  --rpc-url $BASE_SEPOLIA_RPC_URL --sender $ADMIN -vvvv

forge script script/RedeployGuildFactory.s.sol \
  --rpc-url $BASE_SEPOLIA_RPC_URL --sender $ADMIN -vvvv
```

Expected: `Script ran successfully`, a `=== DEPLOYMENT JSON ===` block, and
`SIMULATION COMPLETE` (printed only when `--broadcast` is absent). The delivery run must show
`broadcaster is router admin: true` and `"settlementReady": true`.

The delivery script **fails closed** (it reverts before deploying anything):

| Revert                                                           | Cause                                                                                                                                             | Fix                                                                                                                                                                     |
| ---------------------------------------------------------------- | ------------------------------------------------------------------------------------------------------------------------------------------------- | ----------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| `BroadcasterNotRouterAdmin(router, sender)`                      | `--sender`/key does not hold `DEFAULT_ADMIN_ROLE` on the router                                                                                   | use the router admin, or `ALLOW_UNWIRED_ROUTER=true` (settlement stays BROKEN until the admin runs `router.setMissionFactory`; the script prints the exact `cast send`) |
| `RouterAlreadyWired(current)`                                    | `router.missionFactory()` is already non-zero. The router has ONE slot; re-pointing orphans every escrow of `current` (they can no longer settle) | confirm that is intended, then set `ALLOW_ROUTER_REPOINT=true` (the script logs a loud WARNING naming the old factory)                                                  |
| `NoCodeAtAddress(name, addr)` / `TokenNotAccepted(router, usdc)` | dead dependency / USDC not accepted on the router                                                                                                 | fix the env                                                                                                                                                             |

Negative check (dead router must abort before any deploy):

```bash
PAYMENT_ROUTER=0x535B3D7A252fa034Ed71F0C53ec0C6F784cB64E1 \
forge script script/DeployDeliveryContracts.s.sol --rpc-url $BASE_SEPOLIA_RPC_URL --sender $ADMIN
# -> revert NoCodeAtAddress("PAYMENT_ROUTER", 0x535B…)
```

## 2. Broadcast + verify

Run the delivery script first, then the guild script (independent, but keep the order so the
nonce sequence matches the dry run).

```bash
export DEPLOYER_PRIVATE_KEY=<admin key, no 0x>   # must be $ADMIN (router DEFAULT_ADMIN_ROLE)
export BASESCAN_API_KEY=<key>

forge script script/DeployDeliveryContracts.s.sol \
  --rpc-url $BASE_SEPOLIA_RPC_URL \
  --broadcast --verify --etherscan-api-key $BASESCAN_API_KEY \
  --slow -vvvv

forge script script/RedeployGuildFactory.s.sol \
  --rpc-url $BASE_SEPOLIA_RPC_URL \
  --broadcast --verify --etherscan-api-key $BASESCAN_API_KEY \
  --slow -vvvv
```

Optional flags:

- `ALLOW_UNWIRED_ROUTER=true` / `ALLOW_ROUTER_REPOINT=true`: see the revert table above.
- `DEPLOY_DELIVERIES_DAO=true` also deploys a fresh `DeliveriesDAO(USDC)` and wires it to the new factory
  (`setDeliveryFactory`) (default: keep the existing one). Since the #820 M4 residual fix, a `DeliveriesDAO`
  with no delivery factory sells no policies, and the deployed `0xaB2F…ae53` predates the fix — it must be
  redeployed with this flag before insurance is used. Changing the factory later is delayed 2 days.
  **Pre-redeploy requirement — `DeliveriesDAO` owner must be a multisig / timelock.** The delays in
  `DeliveriesDAO` only bound the permissionless drain and rate-limit owner outflows (`closePolicy` only
  for Completed/Cancelled orders — read from the factory that issued the policy — and only
  `CLAIM_WINDOW` (3 days) after `recordPolicyTerminal`; immediate `withdrawFunds` ≤ surplus and ≤
  `maxWithdrawPerPeriod`, a budget separate from claim payouts; larger withdrawals via `queueWithdraw` →
  `executeWithdraw` after 2 days). A single-key owner can still deny every claim, move one withdraw
  budget per day, queue a hostile factory that after 2 days can underwrite fake NEW policies paid within
  the claim budget, and withdraw the whole unreserved surplus after the delay. Do not fund the pool beyond test amounts until `transferOwnership(<Safe/timelock>)`
  has been executed on the new `DeliveriesDAO` (PR #963 review). Watch `WithdrawQueued` events and
  `cancelWithdraw()` (or tighten `setPayoutLimits` / `setMaxWithdrawPerPeriod`) to stop a queued withdrawal.
  Any tightening also cancels a queued factory change and every queued limit loosening. Route
  `DeliveryFactoryQueued`, `PayoutLimitsQueued`, `WithdrawLimitQueued` and `WithdrawQueued` to an alert
  — the 2-day delay only helps if someone sees it.
- `DELIVERY_MISSION_FACTORY=0x…` (with `DEPLOY_DELIVERIES_DAO=true`): **DAO-only mode**, see below.
- `USDC=0x…` overrides the Base Sepolia USDC default; the script reverts if the router does not accept it.
- Hardware wallet / keystore: leave `DEPLOYER_PRIVATE_KEY` unset and pass `--account <name> --sender $ADMIN`
  (the script then calls `vm.startBroadcast()` with no key).

### DeliveriesDAO-only redeploy (issue #969)

Ships a new `DeliveriesDAO` against the **already-live** factory without redeploying it or touching the
router (`PAYMENT_ROUTER` / `DISPUTE_RESOLVER` are not needed). The script deploys
`DeliveriesDAO(USDC)`, calls `setDeliveryFactory(DELIVERY_MISSION_FACTORY)` (first wiring is immediate),
checks it, and prints a JSON block plus the `transferOwnership` command.

**Prerequisite — ownership → multisig.** The new DAO is owned by the broadcaster. Before anyone funds
the pool beyond test amounts, transfer ownership to a Safe / timelock (`cast send <DAO>
'transferOwnership(address)' <Safe>`) and confirm `owner()`. The contract's delays only make owner
actions visible for 2 days; they do not make a single compromised key harmless.

```bash
unset PAYMENT_ROUTER DISPUTE_RESOLVER
export DEPLOY_DELIVERIES_DAO=true
export DELIVERY_MISSION_FACTORY=0xf02Cdc9eD74E2fd63Cc98ED10e78A53512e25d53   # live factory (2026-10-13)
export DELIVERIES_DAO=0xaB2F7787b72FcFfEA8E543375FE2db44D9C6ae53            # previous DAO, echoed only

# 1. dry run - expect "=== DEPLOYMENT JSON ===" and "SIMULATION COMPLETE"
forge script script/DeployDeliveryContracts.s.sol --rpc-url $BASE_SEPOLIA_RPC_URL --sender $ADMIN -vvvv

# 2. broadcast
forge script script/DeployDeliveryContracts.s.sol --rpc-url $BASE_SEPOLIA_RPC_URL \
  --broadcast --verify --etherscan-api-key $BASESCAN_API_KEY --slow -vvvv

# 3. checks, then hand over ownership
cast call <DAO> 'deliveryFactory()(address)' --rpc-url $BASE_SEPOLIA_RPC_URL   # == $DELIVERY_MISSION_FACTORY
cast send <DAO> 'transferOwnership(address)' <Safe/timelock> --rpc-url $BASE_SEPOLIA_RPC_URL --account <deployer>
cast call <DAO> 'owner()(address)' --rpc-url $BASE_SEPOLIA_RPC_URL             # == Safe/timelock
```

`DELIVERY_MISSION_FACTORY` without `DEPLOY_DELIVERIES_DAO=true` reverts `DaoOnlyModeRequiresDeployFlag`;
an address without code reverts `NoCodeAtAddress`, and a contract that is not a `DeliveryMissionFactory`
(no `deliveryEscrowImplementation()`) reverts before anything is broadcast. Then update the
`DeliveriesDAO` address in the consumers listed in section 4.

If `--verify` fails (foundry.toml still points at the Basescan v1 API URL, which Etherscan has
deprecated), verify afterwards:

```bash
forge verify-contract <DeliveryMissionFactory> src/DeliveryMissionFactory.sol:DeliveryMissionFactory \
  --chain 84532 --etherscan-api-key $BASESCAN_API_KEY \
  --constructor-args $(cast abi-encode 'constructor(address)' $PAYMENT_ROUTER) --watch
forge verify-contract <DeliveryEscrowImpl> src/DeliveryEscrow.sol:DeliveryEscrow --chain 84532 --etherscan-api-key $BASESCAN_API_KEY --watch
forge verify-contract <GuildFactory>  src/GuildFactory.sol:GuildFactory --chain 84532 --etherscan-api-key $BASESCAN_API_KEY --watch
forge verify-contract <GuildDAOImpl>  src/GuildDAO.sol:GuildDAO         --chain 84532 --etherscan-api-key $BASESCAN_API_KEY --watch
```

## 3. Post-broadcast wiring checks

The delivery script already calls `factory.setDisputeResolver` and `router.setMissionFactory`
(the broadcaster must be the router admin, see above) and asserts `settlementReady`. Confirm on-chain:

```bash
NEW_DMF=<DeliveryMissionFactory from the JSON block>
cast call $PAYMENT_ROUTER 'missionFactory()(address)'  --rpc-url $BASE_SEPOLIA_RPC_URL   # == $NEW_DMF
cast call $NEW_DMF 'disputeResolver()(address)'        --rpc-url $BASE_SEPOLIA_RPC_URL   # == $DISPUTE_RESOLVER
cast call $NEW_DMF 'paymentRouter()(address)'          --rpc-url $BASE_SEPOLIA_RPC_URL   # == $PAYMENT_ROUTER
cast call $NEW_DMF 'owner()(address)'                  --rpc-url $BASE_SEPOLIA_RPC_URL   # == $ADMIN
```

Only if the script printed `ACTION REQUIRED` (sender was not router admin):

```bash
cast send $PAYMENT_ROUTER 'setMissionFactory(address)' $NEW_DMF \
  --rpc-url $BASE_SEPOLIA_RPC_URL --account <admin>
```

Guild clones are **not** upgraded: `iTakeMetaDAO`, `AtobaDAO`, `LisboaCafe` and the `DeliveriesDAO`
guild roles were cloned from the old factory and keep the old `GuildDAO` implementation. Recreate
them through the new factory (`createMetaDAO` / `createSubDAO`) if they need the #949 fix; that
yields new addresses and is a separate, deliberate step.

## 4. Consumers to update after broadcast

> Done for the 2026-10-13 run (see "Last executed" below), except the rows for Railway env, `horizon-sdk` and `horizon-contracts` which live outside this repo.

Replace the old addresses (`GuildFactory 0xB54795f8…`, `DeliveryMissionFactory 0x77DD51c6…`,
`DeliveryEscrowImpl 0x21Fd1D6f…`) with the new ones in:

| File                                                           | Keys                                                                                                                                                           |
| -------------------------------------------------------------- | -------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| `packages/contracts/deployments/base-sepolia.json`             | `GuildFactory`, `DeliveryMissionFactory`, `DeliveryEscrowImpl`, `deployedAt`                                                                                   |
| `packages/shared/src/constants/index.ts`                       | `BASE_SEPOLIA.ITAKE_GUILD_FACTORY`, `DELIVERY_MISSION_FACTORY`, `DELIVERY_ESCROW_IMPL`                                                                         |
| `packages/subgraph/subgraph.yaml`                              | `GuildFactory` data source `address` (line ~87) + `startBlock` (= deploy block)                                                                                |
| `packages/service/goldsky/pipeline.yaml`                       | `horizon_events` address list: replace `0xb54795f8…` with the new GuildFactory (lower-case); add the new DeliveryMissionFactory if delivery events are indexed |
| `packages/service/.env.example` + Railway env (staging + prod) | `GUILD_FACTORY_ADDRESS`, `DELIVERY_MISSION_FACTORY_ADDRESS`                                                                                                    |
| `horizon-sdk/src/constants.ts` (separate repo)                 | `iTakeGuildFactory`, `deliveryMissionFactory`, `deliveryEscrowImpl` (then publish `horizon-protocol-sdk`)                                                      |
| `horizon-contracts/DEPLOYED_ADDRESSES.md` (mirror repo)        | same three entries                                                                                                                                             |
| `docs/DELIVERY_MIGRATION_CHECKLIST.md`                         | mark superseded by this runbook                                                                                                                                |

Then: `cd packages/shared && yarn build`, redeploy the subgraph/Goldsky pipeline, restart the
service so the indexer picks up the new factory addresses.

## Last executed: 2026-10-13

Broadcast on Base Sepolia (chainId 84532) by deployer/admin `0x2b30efBA367D669c9cd7723587346a79b67A42DB`; all contracts verified on Basescan.

| Contract                                       | New address                                  | Replaces                                     | Block    | Tx                                                                   |
| ---------------------------------------------- | -------------------------------------------- | -------------------------------------------- | -------- | -------------------------------------------------------------------- |
| `DeliveryMissionFactory`                       | `0xf02Cdc9eD74E2fd63Cc98ED10e78A53512e25d53` | `0x77DD51c63A3fEE0442f4383B5a9D91d470BD04F5` | 48074534 | `0xb1144bad7ead64a40b74a7dae35786ca038fc0bd5431f670a0b1d0294fcc4e84` |
| `DeliveryEscrow` impl (created by the factory) | `0x0A2F4Eeed28D630f0592068054e974991eBFe08B` | `0x21Fd1D6f66BFf3B084FdA428C75b659A46446f4b` | 48074534 | same tx as the factory                                               |
| `GuildFactory`                                 | `0xB3720D5f3Ff1A6385aC0C1f54f88536F68a967F3` | `0xB54795f8049De1acf729160bcD9184e50E4f267E` | 48074577 | `0xb659e938fc30904f52658e7d7f9d3efa996188a4d5b72224d843def420b4244c` |
| `GuildDAO` impl (created by the factory)       | `0x456D4c04F9001fDE8cdc306dd6b07a79655BB131` | `0x4E798699D370235AFCCAC53c2923414dD7B839ed` | 48074577 | same tx as the factory                                               |

Wiring transactions (delivery run):

| Call                                                                                                                 | Block    | Tx                                                                   |
| -------------------------------------------------------------------------------------------------------------------- | -------- | -------------------------------------------------------------------- |
| `DeliveryMissionFactory.setDisputeResolver(0xdE37Ff10A487c852941DC842987dd8d5d8b9E855)`                              | 48074535 | `0xef78cab1e571969107b8f0e1b0c9a3698c708352cdde46411d4c79be76fe28f8` |
| iTake `PaymentRouter` (`0x539408777865c7a3Ac702a350BEb4C04b8618eF2`) `.setMissionFactory(newDeliveryMissionFactory)` | 48074536 | `0x1b35b62ac11612644c89a3b17d9771532dceda75239636090b663e68675ced2c` |

`DeliveriesDAO` (`0xaB2F7787b72FcFfEA8E543375FE2db44D9C6ae53`) was kept unchanged. Existing guild clones
(`iTakeMetaDAO`, `AtobaDAO`, `LisboaCafe`) were cloned from the old factory and still run the old `GuildDAO`
implementation. The consumers listed in section 4 were updated in the same PR as this entry.

---

# Base Sepolia redeploy runbook: core set + DisputeResolver + PauseRegistry

**Status: broadcast 2026-10-14** (see "Last executed: 2026-10-14" at the end of this file). Everything below was
first dry-run against a Base Sepolia fork with `--sender 0x2b30…42DB` and no `--broadcast`.

| Script                                    | Deploys / wires                                                                                                                                                                                                                                              |
| ----------------------------------------- | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------ |
| `DeployDisputeResolver.s.sol` (run first) | new `DisputeResolver`; `DeliveryMissionFactory.setDisputeResolver(new)` (and `MissionFactory.setDisputeResolver(new)` when `MISSION_FACTORY` is given)                                                                                                       |
| `RedeployCore.s.sol` (run second)         | new `PaymentRouter` (USDC + EURC, treasuries and performer floor carried over) + new `MissionFactory` (constructor deploys the `MissionEscrow` impl) + `PauseRegistry`; `router.setMissionFactory`, `factory.setDisputeResolver`, `factory.setPauseRegistry` |
| `scripts/compare-live-bytecode.py`        | read-only drift report: every address in `CONTRACTS.BASE_SEPOLIA` vs the compiled artifact                                                                                                                                                                   |
| `test/RedeployScripts.t.sol`              | 12 tests: both scripts, handover, fail-closed paths, and a full mission settling through the new set                                                                                                                                                         |

## Decisions (Ruben, final)

1. **Core**: fresh, coherently wired set. The old core router `0x3013db6C…` and factory `0x6d97964E…` (0 missions) are left **orphaned and untouched**; the script only reads them to carry config over and never calls a setter on them. The router's single `missionFactory` slot is **not** re-pointed.
2. **Token stack skipped**: `sHRZNVault`, `FeeDistributor`, `BuybackExecutor`, `TeamVesting`, `AdvisorVesting` (and `HorizonGovernor`/`GovernorTimelock`/`HorizonToken`, which are current) stay as deployed. HRZN is deferred, `FeeDistributor` is not in the fee path (`PaymentRouter` pays treasuries directly) and the vault has `totalSupply() == 0`. The stale vault still carries audit C1 (`requestUnstake` always reverts, #817), which is irrelevant while nobody can deposit value worth protecting on testnet. **Do not announce staking on Sepolia until the token stack is redeployed.**
3. **PauseRegistry** is deployed for the first time and wired into the new `MissionFactory` (`setPauseRegistry`). `MissionEscrow` clones read it from the factory at init, so the factory is the only wiring point. The iTake `PaymentRouter` has no registry hook and `DeliveryMissionFactory` has **no `setPauseRegistry` setter** (it hard-codes `address(0)` into its escrows), so neither can be wired without a contract change. `PaymentRouter` keeps its own `Pausable`.
4. The new `DisputeResolver` is also set on the live `DeliveryMissionFactory` `0xf02Cdc9e…`. **Existing escrows keep the resolver they were initialised with** (`MissionEscrow` stores it at init), so disputes on already created delivery escrows still go to the old resolver `0xdE37Ff10…`; only escrows created after the switch use the new one.

## 0. Prerequisites

```bash
cd packages/contracts
export PATH=$HOME/.foundry/bin:$PATH
forge build
export BASE_SEPOLIA_RPC_URL=https://sepolia.base.org
export ADMIN=0x2b30efBA367D669c9cd7723587346a79b67A42DB      # owner/admin of everything below
export OLD_PAYMENT_ROUTER=0x3013db6C92EF956f86EBC0aDFECe70b80FA73600
export OLD_MISSION_FACTORY=0x6d97964E9BE016A8AABA2f99F0bA419464Fb88D9
export OLD_DISPUTE_RESOLVER=0xdE37Ff10A487c852941DC842987dd8d5d8b9E855
export DELIVERY_MISSION_FACTORY=0xf02Cdc9eD74E2fd63Cc98ED10e78A53512e25d53

cast balance $ADMIN --rpc-url $BASE_SEPOLIA_RPC_URL --ether           # ~0.022 ETH; the whole run needs < 0.0001 ETH at today's 0.006 gwei
cast call $DELIVERY_MISSION_FACTORY 'owner()(address)' --rpc-url $BASE_SEPOLIA_RPC_URL   # == $ADMIN
cast call $OLD_MISSION_FACTORY 'missionCount()(uint256)' --rpc-url $BASE_SEPOLIA_RPC_URL # 0 -> safe to orphan
python3 scripts/compare-live-bytecode.py                              # drift table (see PR body)
```

Note on EURC: the live core router does **not** accept EURC (`acceptedTokens(EURC) == false`); the new router does (`setAcceptedToken(EURC, true)`), as intended. Fees are constants in `PaymentRouter` (250/250/200 bps), so there is nothing to carry over; treasuries (all `$ADMIN` today) and `performerFloorBPS` (9000) are read from `OLD_PAYMENT_ROUTER`. `guildTreasuries` are not carried over (none are set on the old core router, checked for the three known guilds).

## 1. Dry run (no key, no broadcast) - do this first

```bash
unset DEPLOYER_PRIVATE_KEY

# step 1: new resolver + re-point the delivery factory
OLD_DISPUTE_RESOLVER=$OLD_DISPUTE_RESOLVER DELIVERY_MISSION_FACTORY=$DELIVERY_MISSION_FACTORY \
forge script script/DeployDisputeResolver.s.sol --rpc-url $BASE_SEPOLIA_RPC_URL --sender $ADMIN -vvvv

# step 2: core set. The new resolver does not exist on-chain yet, so for the SIMULATION use the old one as a
# stand-in (the script prints a WARNING saying so). Never broadcast with the old resolver.
DISPUTE_RESOLVER=$OLD_DISPUTE_RESOLVER OLD_PAYMENT_ROUTER=$OLD_PAYMENT_ROUTER OLD_MISSION_FACTORY=$OLD_MISSION_FACTORY \
forge script script/RedeployCore.s.sol --rpc-url $BASE_SEPOLIA_RPC_URL --sender $ADMIN -vvvv
```

Expected: `Script ran successfully`, a `=== DEPLOYMENT JSON ===` block and `SIMULATION COMPLETE` (printed only without `--broadcast`). Simulated addresses depend on the sender nonce, so the real ones differ. Dry-run gas (forge estimate): resolver script ~2.77M, core script ~6.80M, total ~9.6M gas = ~0.0001 ETH at 0.006 gwei (affordable with the 0.022 ETH balance up to ~2 gwei).

`RedeployCore` fails closed (reverts before deploying anything):

| Revert                        | Cause                                                                                | Fix                                                                                                                               |
| ----------------------------- | ------------------------------------------------------------------------------------ | --------------------------------------------------------------------------------------------------------------------------------- |
| `DisputeResolverRequired()`   | `DISPUTE_RESOLVER` unset                                                             | run step 1 first and export its address, or `ALLOW_NO_DISPUTE_RESOLVER=true` (disputes revert until `factory.setDisputeResolver`) |
| `NoCodeAtAddress(name, addr)` | USDC / EURC / resolver / `PAUSE_REGISTRY` / `OLD_*` has no code                      | fix the env                                                                                                                       |
| `RouterAlreadyWired(current)` | the freshly deployed router is not unwired (defensive; cannot happen on a clean run) | investigate; never re-point an existing router (one factory slot, orphans the old factory's escrows)                              |

`DeployDisputeResolver` reverts `BroadcasterNotOwner(name, factory, owner, sender)` unless the sender owns each factory it is asked to re-point (`ALLOW_UNWIRED_FACTORIES=true` prints the `cast send` for the owner instead).

## 2. Broadcast + verify (needs Ruben's go-ahead)

```bash
export DEPLOYER_PRIVATE_KEY=<0x2b30 key, no 0x>     # or --account <keystore> --sender $ADMIN with the var unset
export BASESCAN_API_KEY=<key>

# step 1
forge script script/DeployDisputeResolver.s.sol --rpc-url $BASE_SEPOLIA_RPC_URL \
  --broadcast --verify --etherscan-api-key $BASESCAN_API_KEY --slow -vvvv
export DISPUTE_RESOLVER=<DisputeResolver from the JSON block>

# step 2 (DEPLOY_PAUSE_REGISTRY defaults to true; PAUSE_REGISTRY=0x… reuses one)
forge script script/RedeployCore.s.sol --rpc-url $BASE_SEPOLIA_RPC_URL \
  --broadcast --verify --etherscan-api-key $BASESCAN_API_KEY --slow -vvvv
```

Alternative order (core first, resolver second): run step 2 with `ALLOW_NO_DISPUTE_RESOLVER=true`, then step 1 with `MISSION_FACTORY=<new factory>` so it re-points both factories. Either order ends in the same state.

Manual `--verify` fallback (if the v1 Basescan URL in `foundry.toml` is rejected):

```bash
forge verify-contract <PaymentRouter>  src/PaymentRouter.sol:PaymentRouter --chain 84532 --etherscan-api-key $BASESCAN_API_KEY \
  --constructor-args $(cast abi-encode 'constructor(address,address,address,address,address)' $USDC $ADMIN $ADMIN $ADMIN $ADMIN) --watch
forge verify-contract <MissionFactory> src/MissionFactory.sol:MissionFactory --chain 84532 --etherscan-api-key $BASESCAN_API_KEY \
  --constructor-args $(cast abi-encode 'constructor(address)' <PaymentRouter>) --watch
forge verify-contract <MissionEscrowImpl> src/MissionEscrow.sol:MissionEscrow --chain 84532 --etherscan-api-key $BASESCAN_API_KEY --watch
forge verify-contract <PauseRegistry>  src/PauseRegistry.sol:PauseRegistry --chain 84532 --etherscan-api-key $BASESCAN_API_KEY \
  --constructor-args $(cast abi-encode 'constructor(address)' $ADMIN) --watch
forge verify-contract <DisputeResolver> src/DisputeResolver.sol:DisputeResolver --chain 84532 --etherscan-api-key $BASESCAN_API_KEY \
  --constructor-args $(cast abi-encode 'constructor(address,address,address,address,address)' $USDC $ADMIN $ADMIN $ADMIN $ADMIN) --watch
```

## 3. Post-broadcast checks

```bash
NEW_ROUTER=<PaymentRouter>; NEW_FACTORY=<MissionFactory>; NEW_REG=<PauseRegistry>
cast call $NEW_ROUTER  'missionFactory()(address)'        --rpc-url $BASE_SEPOLIA_RPC_URL   # == $NEW_FACTORY
cast call $NEW_FACTORY 'paymentRouter()(address)'         --rpc-url $BASE_SEPOLIA_RPC_URL   # == $NEW_ROUTER
cast call $NEW_FACTORY 'disputeResolver()(address)'       --rpc-url $BASE_SEPOLIA_RPC_URL   # == $DISPUTE_RESOLVER
cast call $NEW_FACTORY 'pauseRegistry()(address)'         --rpc-url $BASE_SEPOLIA_RPC_URL   # == $NEW_REG
cast call $NEW_FACTORY 'owner()(address)'                 --rpc-url $BASE_SEPOLIA_RPC_URL   # == $ADMIN
cast call $NEW_ROUTER  'acceptedTokens(address)(bool)' 0x808456652fdb597867f38412077A9182bf77359F --rpc-url $BASE_SEPOLIA_RPC_URL   # true (EURC)
cast call $DELIVERY_MISSION_FACTORY 'disputeResolver()(address)' --rpc-url $BASE_SEPOLIA_RPC_URL   # == $DISPUTE_RESOLVER
```

The scripts assert all of the above themselves (`require(...)` after `stopBroadcast`) and report `"settlementReady": true`.
Run one real mission end to end on the new factory before announcing (create, accept, submit, approve) and check the performer receives >= 90%.

## 4. What this does NOT change (read before announcing)

- Old core router/factory stay live (0 missions) and old escrows keep their old resolver; nothing is migrated.
- Stale and intentionally **not** redeployed: `HorizonAchievements` (batch-mint supply-cap validation, June 2026 audit), `ReputationOracle`, `DeliveriesDAO` (#820 mediums), and the whole token stack (decision 2). `GuildFactory`, `DeliveryMissionFactory` and `DeliveryEscrow` are current. See the drift table in the PR.
- `DeliveryMissionFactory` and the iTake router cannot take a `PauseRegistry` (no setter / no hook); the registry only protects the new core factory and its escrow clones.
- Sepolia DisputeResolver DAOs and treasuries are all `$ADMIN` (single EOA).

## 5. Consumers to update after broadcast

| Where                                                            | What                                                                                                                                                                                                                                                                                                                                                                                                                            |
| ---------------------------------------------------------------- | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| `packages/shared/src/constants/index.ts` (`BASE_SEPOLIA`)        | `MISSION_FACTORY`, `PAYMENT_ROUTER`, `MISSION_ESCROW_IMPL`, `DISPUTE_RESOLVER`, `PAUSE_REGISTRY` (currently `''`); update the "Last deployed" comment. Then `cd packages/shared && yarn build`.                                                                                                                                                                                                                                 |
| `packages/contracts/deployments/base-sepolia.json`               | add `MissionFactory`, `PaymentRouter` (core), `MissionEscrowImpl`, `DisputeResolver`, `PauseRegistry`; move the old core addresses under `previous`; bump `deployedAt`                                                                                                                                                                                                                                                          |
| `horizon-sdk/src/constants.ts` (separate repo)                   | the same five keys, then publish `horizon-protocol-sdk`                                                                                                                                                                                                                                                                                                                                                                         |
| `horizon-contracts/DEPLOYED_ADDRESSES.md` (mirror repo)          | same entries (also fix the stale 4%/4% fee note)                                                                                                                                                                                                                                                                                                                                                                                |
| Railway env, staging + prod (`packages/service`)                 | `MISSION_FACTORY_ADDRESS` (new factory), `RESOLVER_CONTRACT_ADDRESS` (new resolver), `PAUSE_REGISTRY_CONTRACT_ADDRESS` (new registry). **`PAYMENT_ROUTER_ADDRESS` is a single variable and currently holds the iTake router `0x5394…`; decide deliberately whether the indexer should follow the new core router (the iTake/delivery events then need their own variable) before changing it.** Restart the service afterwards. |
| `packages/service/goldsky/pipeline.yaml`                         | add the new `MissionFactory` and `PaymentRouter` (lower-case) to the `horizon_events` address list; the old 6d97/3013 are not listed today                                                                                                                                                                                                                                                                                      |
| `packages/subgraph/subgraph.yaml`                                | `MissionFactory`, `MissionEscrow` and `DisputeResolver` data sources still hold the placeholders `0x…0001/2/3`: set the real addresses and `startBlock` (deploy block); redeploy the subgraph                                                                                                                                                                                                                                   |
| `packages/service/.env.example`, `docs/environment-variables.md` | no change needed unless the router variable is split                                                                                                                                                                                                                                                                                                                                                                            |
| mobile / miniapp / dashboard                                     | they read the shared constants; rebuild after the shared package is published. Existing missions on the old factory will no longer be listed by contract-address-based reads.                                                                                                                                                                                                                                                   |

## Last executed: 2026-10-14

Broadcast on Base Sepolia (chainId 84532) by deployer/admin `0x2b30efBA367D669c9cd7723587346a79b67A42DB` from commit `fd8a574`; all contracts being verified on Basescan. On-chain wiring was re-checked after the run: `router.missionFactory() == factory`, `factory.paymentRouter() == router`, `factory.disputeResolver() == new resolver`, `factory.pauseRegistry() == new registry`, `DeliveryMissionFactory.disputeResolver() == new resolver`.

**The token stack was intentionally skipped** (`sHRZNVault`, `FeeDistributor`, `BuybackExecutor`, `TeamVesting`, `AdvisorVesting`; `HorizonToken`, `HorizonGovernor`, `GovernorTimelock` unchanged). See decision 2 above. Do not announce staking on Sepolia until it is redeployed.

Step 1, `DeployDisputeResolver.s.sol`:

| Contract / call                                                     | Address / argument                           | Replaces                                     | Block    | Tx                                                                   |
| ------------------------------------------------------------------- | -------------------------------------------- | -------------------------------------------- | -------- | -------------------------------------------------------------------- |
| `DisputeResolver`                                                   | `0x073A3674FB09177fcD6615bD920Ca1Fc52Fbd156` | `0xdE37Ff10A487c852941DC842987dd8d5d8b9E855` | 48092206 | `0x592514c2f05d3993816c653fdbcc5723340b513e686cf3fc115cd2d871137ca8` |
| `DeliveryMissionFactory` (`0xf02Cdc9e…`) `.setDisputeResolver(new)` | `0x073A3674…2Fbd156`                         | n/a                                          | 48092207 | `0xc206584f489337d211c64bbbcad6fc16580ad1b379206db26fa3b7555c48aa9a` |

Step 2, `RedeployCore.s.sol`:

| Contract / call                                           | Address / argument                           | Replaces                                     | Block    | Tx                                                                   |
| --------------------------------------------------------- | -------------------------------------------- | -------------------------------------------- | -------- | -------------------------------------------------------------------- |
| `PaymentRouter`                                           | `0x3a84718A90E03621526748A1721f10D32BEaf903` | `0x3013db6C92EF956f86EBC0aDFECe70b80FA73600` | 48092222 | `0xacac473501c74a81f8fb957220c360f91a4e12f0415bccca7f908bcbb7f053df` |
| `PaymentRouter.setAcceptedToken(EURC, true)`              | `0x808456652fdb597867f38412077A9182bf77359F` | n/a                                          | 48092223 | `0x5d62d701c2cd9b83f810879a903536c76a68cc8a4550133fd33f06342a578b33` |
| `MissionFactory`                                          | `0x8D780F03206E6433c2e5F7E0aB40244Ee051a271` | `0x6d97964E9BE016A8AABA2f99F0bA419464Fb88D9` | 48092224 | `0xdda500bbcf1016ba1c1fa73e8d393250ba3d8f4c6dbb1ebe5bb71373ea6bbacd` |
| `MissionEscrow` impl (created by the factory constructor) | `0x9aBe058635D961191571140948774cD829847406` | `0x3b02a7eac30Bc4a800Eebd69Fed75c818dB92099` | 48092224 | same tx as the factory                                               |
| `PaymentRouter.setMissionFactory(new factory)`            | `0x8D780F03…4Ee051a271`                      | n/a                                          | 48092225 | `0x5ca37026b8e0b81382a4605734c9a0b4818e9b4b6d99ad54d85b3f48a7a42ec1` |
| `MissionFactory.setDisputeResolver(new resolver)`         | `0x073A3674…2Fbd156`                         | n/a                                          | 48092226 | `0xd5580424f34474c036c0c57863c79b5428439ed152dfd5dece9651298d6afc3e` |
| `PauseRegistry` (first deployment)                        | `0x05Ec569d16Ac6b7B5dEB8B815976512CED645A87` | n/a                                          | 48092227 | `0x627ba0ecc597ceb6a4ab524d8955017f547f3d7108e6fa66502216aebb78f61c` |
| `MissionFactory.setPauseRegistry(new registry)`           | `0x05Ec569d…D645A87`                         | n/a                                          | 48092228 | `0x6ee5130e68acae03ab1cda9e80d291bce4ca86bf047e949bb8afe0f5310b43ff` |

Consumers updated in the same PR as this entry: `packages/shared/src/constants/index.ts`, `packages/contracts/deployments/base-sepolia.json` (the former `PaymentRouter` key, the iTake router `0x5394…`, is now `iTakePaymentRouter`; `PaymentRouter` is the core router), `packages/service/.env.example`, `packages/service/goldsky/pipeline.yaml`, `packages/subgraph/subgraph.yaml`, `packages/contracts/.env.example`, `docs/deploy/governance-and-pause.md`. The subgraph `PaymentRouter` data source now follows the core router, so iTake router (delivery) payment events are no longer indexed by the subgraph. Still to do outside this repo: Railway env (staging + prod), `horizon-contracts/DEPLOYED_ADDRESSES.md`, publish `horizon-protocol-sdk` 0.3.1, redeploy the subgraph and the Goldsky pipeline. The older sections of this file (the 2026-10-13 runbook and its env examples) keep the addresses that were current when they were written.
