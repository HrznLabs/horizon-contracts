# Vulnerability Advisory: DeliveryMissionFactory breaks PaymentRouter settlement authentication

## Description
The `PaymentRouter` contract expects factory-deployed escrows to be authenticated via the factory's `getMissionByEscrow(address)` function. The `MissionFactory` implements this function, but the `DeliveryMissionFactory` does not.

When a `DeliveryEscrow` attempts to settle a payment by calling `PaymentRouter.settlePayment()`, the router checks the `_isFactoryEscrow` modifier which calls `IMissionFactory(factory).getMissionByEscrow(caller)`.

Because `DeliveryMissionFactory` lacks this method, the call inside the router's `try/catch` block reverts (without bubbling up the error), returning `false` for authentication. The router then reverts with the `OnlyMissionEscrow` error. This entirely breaks payment settlement and dispute resolution for all delivery missions.

## Impact
All delivery missions deployed through `DeliveryMissionFactory` will be permanently locked during settlement. Performers cannot be paid and posters cannot be refunded via standard mechanisms or dispute resolution. Value is effectively trapped in the escrow contracts.

## Proposed Fix
Implement `getMissionByEscrow` on `DeliveryMissionFactory`. Since `DeliveryEscrow` doesn't strictly adhere to the same factory state tracking as `MissionFactory` (it relies on clone creation), the implementation can query the escrow itself and verify its authenticity against the factory's clone registry.

```solidity
    /**
     * @notice Authenticates clone for PaymentRouter
     * @param escrow Address of the escrow
     * @return missionId The ID of the mission (or 0 if not found)
     */
    function getMissionByEscrow(address escrow) external view returns (uint256) {
        try DeliveryEscrow(payable(escrow)).getMissionId() returns (uint256 mId) {
            // Verify this factory actually created this escrow address
            if (missions[mId] == escrow) {
                return mId;
            }
        } catch {}
        return 0;
    }
```

## Evidence
- `src/PaymentRouter.sol:_isFactoryEscrow` expects the factory to implement `getMissionByEscrow(address)`.
- `src/DeliveryMissionFactory.sol` lacks this function.
- `src/MissionFactory.sol` correctly implements this function.
