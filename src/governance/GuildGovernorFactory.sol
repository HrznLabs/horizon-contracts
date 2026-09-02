
pragma solidity ^0.8.24;

import {GuildGovernor} from "./GuildGovernor.sol";
import {GuildTimelock} from "./GuildTimelock.sol";
import {TimelockController} from "@openzeppelin/contracts/governance/TimelockController.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";


contract GuildGovernorFactory is Ownable {





    address public xpContract;


    mapping(address => address) public guildGovernors;


    mapping(address => address) public guildTimelocks;


    uint48 public constant defaultVotingDelay = 1;
    uint32 public constant defaultVotingPeriod = 50_400;
    uint256 public constant defaultProposalThreshold = 100;
    uint256 public constant defaultQuorum = 10;
    uint256 public constant defaultTimelockDelay = 1 days;





    event GovernanceDeployed(
        address indexed guild,
        address indexed governor,
        address indexed timelock
    );







    error GovernanceAlreadyDeployed();
    error InvalidXPContract();
    error InvalidParameters();






    constructor(address _xpContract) Ownable(msg.sender) {
        if (_xpContract == address(0)) revert();
        xpContract = _xpContract;
    }









    function deployGovernanceWithParams(
        address guildDAO,
        uint48 votingDelay,
        uint32 votingPeriod,
        uint256 proposalThreshold,
        uint256 quorumPercent,
        uint256 timelockDelay
    ) public returns (address governor, address timelock) {
        if (guildGovernors[guildDAO] != address(0)) revert();
        if (quorumPercent > 100) revert();


        address[] memory proposers = new address[](1);
        address[] memory executors = new address[](1);
        executors[0] = address(0);

        GuildTimelock timelockContract = new GuildTimelock(
            timelockDelay,
            proposers,
            executors,
            address(this),
            guildDAO
        );
        timelock = address(timelockContract);


        GuildGovernor governorContract = new GuildGovernor(
            guildDAO,
            TimelockController(payable(timelock)),
            xpContract,
            votingDelay,
            votingPeriod,
            proposalThreshold,
            quorumPercent
        );
        governor = address(governorContract);


        guildGovernors[guildDAO] = governor;
        guildTimelocks[guildDAO] = timelock;


        timelockContract.grantRole(timelockContract.PROPOSER_ROLE(), governor);
        timelockContract.grantRole(timelockContract.CANCELLER_ROLE(), governor);


        timelockContract.renounceRole(timelockContract.DEFAULT_ADMIN_ROLE(), address(this));

        emit GovernanceDeployed(guildDAO, governor, timelock);

        return (governor, timelock);
    }









    function setXPContract(address newXPContract) external onlyOwner {
        if (newXPContract == address(0)) revert();
        address oldContract = xpContract;
        xpContract = newXPContract;
            }






    function hasGovernance(address guildDAO) external view returns (bool) {
        return guildGovernors[guildDAO] != address(0);
    }


    function getGovernance(address guildDAO) external view returns (address governor, address timelock) {
        return (guildGovernors[guildDAO], guildTimelocks[guildDAO]);
    }



}
