// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import { PaymentRouter } from "../../src/PaymentRouter.sol";
import { DeliveryMissionFactory } from "../../src/DeliveryMissionFactory.sol";

/**
 * @title DeliveryRouterWiring
 * @notice Deploy-time checks that a DeliveryMissionFactory's escrow clones can actually
 *         settle through their PaymentRouter.
 *
 * Why this exists (#950 review, #812 class):
 *   DeliveryEscrow clones call PaymentRouter.settleRestaurantOrder themselves
 *   (approveCompletion and, since #950, settleDispute PerformerWins/Split). The router's
 *   onlyAuthorizedSettler modifier accepts a caller only if it holds SETTLER_ROLE or
 *   `missionFactory.getMissionByEscrow(caller) > 0`. Granting SETTLER_ROLE to the FACTORY
 *   (what DeployiTake used to do) authorises nobody: the factory never calls the router.
 *   With `router.missionFactory() == address(0)` every delivery settlement reverts
 *   OnlyMissionEscrow and a PerformerWins/Split dispute can never be finalized (DDR frozen).
 *
 *   The router has a single `missionFactory` slot, so it must point at the delivery factory.
 *   That is safe only on a router dedicated to the delivery vertical (the iTake router).
 */
library DeliveryRouterWiring {
    /// @notice router.missionFactory() does not point at the delivery factory.
    error RouterNotWiredToDeliveryFactory(address router, address expected, address actual);
    /// @notice The factory was built against a different router.
    error FactoryRouterMismatch(address factory, address expectedRouter, address actualRouter);
    /// @notice Wiring is required but the broadcaster cannot call router.setMissionFactory.
    error BroadcasterNotRouterAdmin(address router, address broadcaster);

    /// @notice True when escrows created by `factory` are authorised settlers on `router`.
    function isSettlementReady(PaymentRouter router, address factory) internal view returns (bool) {
        return router.missionFactory() == factory
            && DeliveryMissionFactory(factory).paymentRouter() == address(router);
    }

    /// @notice Reverts unless escrows created by `factory` can settle on `router`.
    function assertSettlementReady(PaymentRouter router, address factory) internal view {
        address actualRouter = DeliveryMissionFactory(factory).paymentRouter();
        if (actualRouter != address(router)) {
            revert FactoryRouterMismatch(factory, address(router), actualRouter);
        }
        address actual = router.missionFactory();
        if (actual != factory) {
            revert RouterNotWiredToDeliveryFactory(address(router), factory, actual);
        }
    }
}
