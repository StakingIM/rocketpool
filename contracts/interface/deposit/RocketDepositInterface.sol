pragma solidity 0.5.0;

/// @title Rocket Pool deposits
contract RocketDepositInterface {
    function create(address _userID, address _groupID, string memory _durationID) payable public returns (bool);
    function refund(address _userID, address _groupID, string memory _durationID, bytes32 _depositID, address _depositorAddress) public returns (uint256);
    function withdraw(address _userID, address _groupID, bytes32 _depositID, address _minipool, address _withdrawerAddress) public returns (uint256);
}
