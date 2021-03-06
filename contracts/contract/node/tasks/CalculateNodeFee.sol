pragma solidity 0.5.0;


import "../../../RocketBase.sol";
import "../../../interface/settings/RocketNodeSettingsInterface.sol";
import "../../../lib/SafeMath.sol";


/// @title CalculateNodeFee - calculates the node operator fee based on the median value
/// @author Jake Pospischil

contract CalculateNodeFee is RocketBase {


    /*** Libs  ******************/


    using SafeMath for uint;


    /*** Contracts **************/


    RocketNodeSettingsInterface rocketNodeSettings = RocketNodeSettingsInterface(0);


    /*** Methods ****************/


    /// @dev Constructor
    constructor(address _rocketStorageAddress) RocketBase(_rocketStorageAddress) public {
        version = 1;
    }


    /// @dev Task name
    function name() public pure returns (string memory) { return "CalculateNodeFee"; }


    /// @dev Run task
    function run(address _nodeAddress) public onlyLatestContract("rocketNodeTasks", msg.sender) returns (bool) {
        // Get contracts
        rocketNodeSettings = RocketNodeSettingsInterface(getContractAddress("rocketNodeSettings"));
        // Get current voting cycle index
        uint256 currentVotingCycle = now.div(rocketNodeSettings.getFeeVoteCycleDuration());
        // Finalise previous voting cycle if complete
        if (rocketStorage.getUint(keccak256(abi.encodePacked("nodes.fee.voting.cycle"))) < currentVotingCycle) {
            // Get vote counts
            uint256 noChangeVotes = rocketStorage.getUint(keccak256(abi.encodePacked("nodes.fee.votes", uint256(0))));
            uint256 increaseVotes = rocketStorage.getUint(keccak256(abi.encodePacked("nodes.fee.votes", uint256(1))));
            uint256 decreaseVotes = rocketStorage.getUint(keccak256(abi.encodePacked("nodes.fee.votes", uint256(2))));
            // Update fee percentage
            uint256 feePerc = rocketNodeSettings.getFeePerc();
            uint256 feeVoteCyclePercChange = rocketNodeSettings.getFeeVoteCyclePercChange();
            uint256 minFeePerc = 0 ether; // 0%
            uint256 maxFeePerc = 1 ether; // 100%
            if (increaseVotes > decreaseVotes && increaseVotes > noChangeVotes && feePerc <= maxFeePerc.sub(feeVoteCyclePercChange)) {
                rocketStorage.setUint(keccak256(abi.encodePacked("settings.node.fee.perc")), feePerc.add(feeVoteCyclePercChange));
            }
            else if (decreaseVotes > increaseVotes && decreaseVotes > noChangeVotes && feePerc >= minFeePerc.add(feeVoteCyclePercChange)) {
                rocketStorage.setUint(keccak256(abi.encodePacked("settings.node.fee.perc")), feePerc.sub(feeVoteCyclePercChange));
            }
            // Reset voting cycle
            rocketStorage.setUint(keccak256(abi.encodePacked("nodes.fee.voting.cycle")), currentVotingCycle);
            rocketStorage.setUint(keccak256(abi.encodePacked("nodes.fee.votes", uint256(0))), 0);
            rocketStorage.setUint(keccak256(abi.encodePacked("nodes.fee.votes", uint256(1))), 0);
            rocketStorage.setUint(keccak256(abi.encodePacked("nodes.fee.votes", uint256(2))), 0);
        }
        // Tally node's fee vote
        if (rocketStorage.getUint(keccak256(abi.encodePacked("node.lastCycleVoted", _nodeAddress))) < currentVotingCycle) {
            // Increment vote count for node's fee vote
            uint256 feeVote = rocketStorage.getUint(keccak256(abi.encodePacked("node.feeVote", _nodeAddress)));
            rocketStorage.setUint(keccak256(abi.encodePacked("nodes.fee.votes", feeVote)), rocketStorage.getUint(keccak256(abi.encodePacked("nodes.fee.votes", feeVote))).add(1));
            // Record last cycle voted
            rocketStorage.setUint(keccak256(abi.encodePacked("node.lastCycleVoted", _nodeAddress)), currentVotingCycle);
        }
        // Done
        return true;
    }


}
