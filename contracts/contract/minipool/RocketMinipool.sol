pragma solidity 0.5.0;


// Interfaces
import "../../interface/RocketPoolInterface.sol";
import "../../interface/RocketStorageInterface.sol";
import "../../interface/settings/RocketGroupSettingsInterface.sol";
import "../../interface/settings/RocketMinipoolSettingsInterface.sol";
import "../../interface/casper/DepositInterface.sol";
import "../../interface/group/RocketGroupContractInterface.sol";
import "../../interface/token/ERC20.sol";
import "../../interface/utils/pubsub/PublisherInterface.sol";
// Libraries
import "../../lib/SafeMath.sol";


/// @title A minipool under the main RocketPool, all major logic is contained within the RocketMinipoolDelegate contract which is upgradable when minipools are deployed
/// @author David Rugendyke

contract RocketMinipool {

    /*** Libs  *****************/

    using SafeMath for uint;


    /**** Properties ***********/

    // General
    uint8   public version = 1;                                 // Version of this contract
    Status  private status;                                     // The current status of this pool, statuses are declared via Enum in the minipool settings
    Node    private node;                                       // Node this minipool is attached to, its creator 
    Staking private staking;                                    // Staking properties of the minipool to track
    uint256 private userDepositCapacity;                        // Total capacity for user deposits
    uint256 private userDepositTotal;                           // Total value of all assigned user deposits

    // Users
    mapping (address => User) private users;                    // Users in this pool
    mapping (address => address) private usersBackupAddress;    // Users backup withdrawal address => users current address in this pool, need these in a mapping so we can do a reverse lookup using the backup address
    address[] private userAddresses;                            // Users in this pool addresses for iteration
    


    /*** Contracts **************/

    ERC20 rplContract = ERC20(0);                                                                   // The address of our RPL ERC20 token contract
    DepositInterface casperDeposit = DepositInterface(0);                                           // Interface of the Casper deposit contract
    RocketGroupContractInterface rocketGroupContract = RocketGroupContractInterface(0);             // The users group contract that they belong too
    RocketGroupSettingsInterface rocketGroupSettings = RocketGroupSettingsInterface(0);             // The settings for groups
    RocketPoolInterface rocketPool = RocketPoolInterface(0);                                        // The main pool manager
    RocketMinipoolSettingsInterface rocketMinipoolSettings = RocketMinipoolSettingsInterface(0);    // The main settings contract most global parameters are maintained
    RocketStorageInterface rocketStorage = RocketStorageInterface(0);                               // The main Rocket Pool storage contract where primary persistant storage is maintained
    PublisherInterface publisher = PublisherInterface(0);                                           // Main pubsub system event publisher

    
    /*** Structs ***************/

    struct Status {
        uint8   current;                                        // The current status code, see RocketMinipoolSettings for more information
        uint8   previous;                                       // The previous status code
        uint256 time;                                           // The time the status last changed
        uint256 block;                                          // The block number the status last changed
    }

    struct Node {
        address owner;                                          // Etherbase address of the node which owns this minipool
        address contractAddress;                                // The nodes Rocket Pool contract
        uint256 depositEther;                                   // The nodes required ether contribution
        uint256 depositRPL;                                     // The nodes required RPL contribution
        bool    trusted;                                        // Was the node trusted at the time of minipool creation?
        bool    depositExists;                                  // The node operator's deposit exists
        uint256 balance;                                        // The node operator's ether balance
    }

    struct Staking {
        string  id;                                             // Duration ID
        uint256 duration;                                       // Duration in blocks
        uint256 balanceStart;                                   // Ether balance of this minipool when it begins staking
        uint256 balanceEnd;                                     // Ether balance of this minipool when it completes staking
        bytes   depositInput;                                   // DepositInput data to be submitted to the casper deposit contract
    }

    struct User {
        address user;                                           // Address of the user
        address backup;                                         // The backup address of the user
        address groupID;                                        // Address ID of the users group
        uint256 balance;                                        // Chunk balance deposited
        int256  rewards;                                        // Rewards received after Casper
        uint256 depositTokens;                                  // Rocket Pool deposit tokens withdrawn by the user on this minipool
        uint256 feeRP;                                          // Rocket Pools fee
        uint256 feeGroup;                                       // Group fee
        uint256 created;                                        // Creation timestamp
        bool    exists;                                         // User exists?
        uint256 addressIndex;                                   // User's index in the address list
    }


      
    /*** Events ****************/

    event DepositReceived (
        address indexed _fromAddress,                           // From address
        uint256 amount,                                         // Amount of the deposit
        uint256 created                                         // Creation timestamp
    );



    /*** Modifiers *************/


    /// @dev Only the node owner which this minipool belongs to
    /// @param _nodeOwner The node owner address.
    modifier isNodeOwner(address _nodeOwner) {
        require(_nodeOwner != address(0x0) && _nodeOwner == node.owner, "Incorrect node owner address passed.");
        _;
    }

    /// @dev Only the node contract which this minipool belongs to
    /// @param _nodeContract The node contract address
    modifier isNodeContract(address _nodeContract) {
        require(_nodeContract != address(0x0) && _nodeContract == node.contractAddress, "Incorrect node contract address passed.");
        _;
    }

    /// @dev Only registered users with this pool
    /// @param _user The users address.
    modifier isPoolUser(address _user) {
        require(_user != address(0x0) && users[_user].exists != false);
        _;
    }

    /// @dev Only allow access from the latest version of the specified Rocket Pool contract
    modifier onlyLatestContract(string memory _contract) {
        require(msg.sender == getContractAddress(_contract), "Only the latest specified Rocket Pool contract can access this method.");
        _;
    }



    /*** Methods *************/
   
    /// @dev minipool constructor
    /// @param _rocketStorageAddress Address of Rocket Pools storage.
    /// @param _nodeOwner The address of the nodes etherbase account that owns this minipool.
    /// @param _durationID Staking duration ID (eg 3m, 6m etc)
    /// @param _depositInput The validator depositInput data to be submitted to the casper deposit contract
    /// @param _depositEther Ether amount deposited by the node owner
    /// @param _depositRPL RPL amount deposited by the node owner
    /// @param _trusted Is the node trusted at the time of minipool creation?
    constructor(address _rocketStorageAddress, address _nodeOwner, string memory _durationID, bytes memory _depositInput, uint256 _depositEther, uint256 _depositRPL, bool _trusted) public {
        // Update the storage contract address
        rocketStorage = RocketStorageInterface(_rocketStorageAddress);
        // Get minipool settings
        rocketMinipoolSettings = RocketMinipoolSettingsInterface(getContractAddress("rocketMinipoolSettings"));
        // Set the address of the casper deposit contract
        casperDeposit = DepositInterface(getContractAddress("casperDeposit"));
        // Add the RPL contract address
        rplContract = ERC20(getContractAddress("rocketPoolToken"));
        // Set the initial status
        status.current = 0;
        status.time = now;
        status.block = block.number;
        // Set the node owner and contract address
        node.owner = _nodeOwner;
        node.depositEther = _depositEther;
        node.depositRPL = _depositRPL;
        node.trusted = _trusted;
        node.contractAddress = rocketStorage.getAddress(keccak256(abi.encodePacked("node.contract", _nodeOwner)));
        // Set the initial staking properties
        staking.id = _durationID;
        staking.duration = rocketMinipoolSettings.getMinipoolStakingDuration(_durationID);
        staking.depositInput = _depositInput;
        // Set the user deposit capacity
        userDepositCapacity = rocketMinipoolSettings.getMinipoolLaunchAmount().sub(_depositEther);
    }


    // Payable
    
    /// @dev Fallback function where our deposit + rewards will be received after requesting withdrawal from Casper
    function() external payable { 
        // Log the deposit received
        emit DepositReceived(msg.sender, msg.value, now);       
    }


    // Utility Methods

    /// @dev Get the the contracts address - This method should be called before interacting with any RP contracts to ensure the latest address is used
    function getContractAddress(string memory _contractName) private view returns(address) { 
        // Get the current API contract address 
        return rocketStorage.getAddress(keccak256(abi.encodePacked("contract.name", _contractName)));
    }


    /*
    /// @dev Use inline assembly to read the boolean value back from a delegatecall method in the minipooldelegate contract
    function getDelegateBoolean(string memory _signatureMethod) public returns (bool) {
        bytes4 signature = getDelegateSignature(_signatureMethod);
        address minipoolDelegate = getContractAddress("rocketMinipoolDelegate");
        bool response = false;
        assembly {
            let returnSize := 32
            let mem := mload(0x40)
            mstore(mem, signature)
            let err := delegatecall(sub(gas, 10000), minipoolDelegate, mem, 0x04, mem, returnSize)
            response := mload(mem)
        }
        return response; 
    }
    */
   
    

    /*** NODE ***********************************************/

    // Getters

    /// @dev Gets the node contract address
    function getNodeOwner() public view returns(address) {
        return node.owner;
    }

    /// @dev Gets the node contract address
    function getNodeContract() public view returns(address) {
        return node.contractAddress;
    }

    /// @dev Gets the amount of ether the node owner must deposit
    function getNodeDepositEther() public view returns(uint256) {
        return node.depositEther;
    }
    
    /// @dev Gets the amount of RPL the node owner must deposit
    function getNodeDepositRPL() public view returns(uint256) {
        return node.depositRPL;
    }

    /// @dev Gets the node's trusted status (at the time of minipool creation)
    function getNodeTrusted() public view returns(bool) {
        return node.trusted;
    }

    /// @dev Gets whether the node operator's deposit currently exists
    function getNodeDepositExists() public view returns(bool) {
        return node.depositExists;
    }

    /// @dev Gets the node operator's ether balance
    function getNodeBalance() public view returns(uint256) {
        return node.balance;
    }


    // Methods

    /// @dev Set the ether / rpl deposit and check it
    function nodeDeposit() public payable isNodeContract(msg.sender) returns(bool) {
        // Will throw if conditions are not met in delegate
        (bool success,) = getContractAddress("rocketMinipoolDelegate").delegatecall(abi.encodeWithSignature("nodeDeposit()"));
        require(success, "Delegate call failed.");
        // Success
        return true;
    }

    /// @dev Withdraw ether / rpl deposit from the minipool if initialised, timed out or withdrawn
    function nodeWithdraw() public isNodeContract(msg.sender) returns(bool) {
        // Will throw if conditions are not met in delegate
        (bool success,) = getContractAddress("rocketMinipoolDelegate").delegatecall(abi.encodeWithSignature("nodeWithdraw()"));
        require(success, "Delegate call failed.");
        // Success
        return true;
    }


    /*** USERS ***********************************************/

    // Getters

    /// @dev Returns the user count for this pool
    function getUserCount() public view returns(uint256) {
        return userAddresses.length;
    }

    /// @dev Returns the true if the user is in this pool
    function getUserExists(address _user) public view returns(bool) {
        return users[_user].exists;
    }

    /// @dev Returns the users original address specified for withdrawals
    function getUserAddressFromBackupAddress(address _userBackupAddress) public view returns(address) {
        return usersBackupAddress[_userBackupAddress];
    }

    /// @dev Returns the true if the user has a backup address specified for withdrawals
    function getUserBackupAddressExists(address _userBackupAddress) public view returns(bool) {
        return usersBackupAddress[_userBackupAddress] != address(0x0) ? true : false;
    }

    /// @dev Returns the true if the user has a backup address specified for withdrawals and that maps correctly to their original user address
    function getUserBackupAddressOK(address _user, address _userBackupAddress) public view isPoolUser(_user) returns(bool) {
        return usersBackupAddress[_userBackupAddress] == _user ? true : false;
    }

    /// @dev Returns the true if the user has a deposit in this mini pool
    function getUserHasDeposit(address _user) public view returns(bool) {
        return users[_user].exists && users[_user].balance > 0 ? true : false;
    }

    /// @dev Returns the amount of the users deposit
    function getUserDeposit(address _user) public view isPoolUser(_user) returns(uint256) {
        return users[_user].balance;
    }

    /// @dev Returns the amount of the deposit tokens the user has taken out
    function getUserDepositTokens(address _user) public view isPoolUser(_user) returns(uint256) {
        return users[_user].depositTokens;
    }


    // Methods

    /// @dev Deposit a users ether to this contract. Will register the user if they don't exist in this contract already.
    /// @param _user New user address
    /// @param _groupID The 3rd party group the user belongs too
    function deposit(address _user, address _groupID) public payable onlyLatestContract("rocketDepositQueue") returns(bool) {
        // Will throw if conditions are not met in delegate or call fails
        (bool success,) = getContractAddress("rocketMinipoolDelegate").delegatecall(abi.encodeWithSignature("deposit(address,address)", _user, _groupID));
        require(success, "Delegate call failed.");
        // Success
        return true;
    }


    /// @dev Withdraw a user's deposit and remove them from this contract.
    /// @param _user User address
    /// @param _groupID The 3rd party group the user belongs to
    /// @param _withdrawalAddress The address to withdraw the user's deposit to
    function withdraw(address _user, address _groupID, address _withdrawalAddress) public onlyLatestContract("rocketDeposit") returns(bool) {
        // Will throw if conditions are not met in delegate or call fails
        (bool success,) = getContractAddress("rocketMinipoolDelegate").delegatecall(abi.encodeWithSignature("withdraw(address,address,address)", _user, _groupID, _withdrawalAddress));
        require(success, "Delegate call failed.");
        // Success
        return true;
    }



    /*** MINIPOOL  ******************************************/


    // Getters

    /// @dev Gets the current status of the minipool
    function getStatus() public view returns(uint8) {
        return status.current;
    }

    // @dev Get the last time the status changed
    function getStatusChangedTime() public view returns(uint256) {
        return status.time;
    }

    // @dev Get the last block no where the status changed
    function getStatusChangedBlock() public view returns(uint256) {
        return status.block;
    }

    /// @dev Returns the current staking duration ID
    function getStakingDurationID() public view returns (string memory) {
        return staking.id;
    }

    /// @dev Returns the current staking duration in blocks
    function getStakingDuration() public view returns(uint256) {
        return staking.duration;
    }

    /// @dev Returns the minipool's deposit input data to be submitted to casper
    function getDepositInput() public view returns (bytes memory) {
        return staking.depositInput;
    }

    /// @dev Gets the total user deposit capacity
    function getUserDepositCapacity() public view returns(uint256) {
        return userDepositCapacity;
    }

    /// @dev Gets the total value of all assigned user deposits
    function getUserDepositTotal() public view returns(uint256) {
        return userDepositTotal;
    }
    
    
    // Methods

    /// @dev Sets the status of the pool based on its current parameters 
    function updateStatus() public returns(bool) {
        // Will update the status of the pool if conditions are correct
        (bool success,) = getContractAddress("rocketMinipoolDelegate").delegatecall(abi.encodeWithSignature("updateStatus()"));
        require(success, "Delegate call failed.");
        // Success
        return true;
    }

}