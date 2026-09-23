content = open('src/DeliveryMissionFactory.sol').read()
new_content = content.replace('''    uint256 public missionCount;
    mapping(uint256 => address) public missions;''', '''    uint256 public missionCount;
    mapping(uint256 => address) public missions;
    mapping(address => uint256) public escrowToMission;''')
new_content = new_content.replace('''        // Store mission
        missions[missionId] = escrow;''', '''        // Store mission
        missions[missionId] = escrow;
        escrowToMission[escrow] = missionId;''')
new_content = new_content.replace('''    function getWaypoints(uint256 missionId)''', '''    /**
     * @notice Get mission ID by escrow address (returns 0 if not found)
     * @param escrow The escrow contract address
     * @return missionId The mission ID (0 if not a known escrow)
     */
    function getMissionByEscrow(address escrow) external view returns (uint256) {
        return escrowToMission[escrow];
    }

    function getWaypoints(uint256 missionId)''')
open('src/DeliveryMissionFactory.sol', 'w').write(new_content)
