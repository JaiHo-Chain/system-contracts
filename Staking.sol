// SPDX-License-Identifier: MIT
pragma solidity 0.8.17;

/**
 * @dev Provides information about the current execution context, including the
 * sender of the transaction and its data. While these are generally available
 * via msg.sender and msg.data, they should not be accessed in such a direct
 * manner, since when dealing with meta-transactions the account sending and
 * paying for execution may not be the actual sender (as far as an application
 * is concerned).
 *
 * This contract is only required for intermediate, library-like contracts.
 */
abstract contract Context {
    function _msgSender() internal view virtual returns (address) {
        return msg.sender;
    }

    function _msgData() internal view virtual returns (bytes calldata) {
        return msg.data;
    }
}

/**
 * @dev Contract module which provides a basic access control mechanism, where
 * there is an account (an owner) that can be granted exclusive access to
 * specific functions.
 *
 * By default, the owner account will be the one that deploys the contract. This
 * can later be changed with {transferOwnership}.
 *
 * This module is used through inheritance. It will make available the modifier
 * `onlyOwner`, which can be applied to your functions to restrict their use to
 * the owner.
 */
abstract contract Ownable is Context {
    address private _owner;

    event OwnershipTransferred(
        address indexed previousOwner,
        address indexed newOwner
    );

    /**
     * @dev Initializes the contract setting the deployer as the initial owner.
     */
    constructor() {
        _transferOwnership(_msgSender());
    }

    /**
     * @dev Throws if called by any account other than the owner.
     */
    modifier onlyOwner() {
        _checkOwner();
        _;
    }

    /**
     * @dev Returns the address of the current owner.
     */
    function owner() public view virtual returns (address) {
        return _owner;
    }

    /**
     * @dev Throws if the sender is not the owner.
     */
    function _checkOwner() internal view virtual {
        require(owner() == _msgSender(), "Ownable: caller is not the owner");
    }

    /**
     * @dev Leaves the contract without owner. It will not be possible to call
     * `onlyOwner` functions anymore. Can only be called by the current owner.
     *
     * NOTE: Renouncing ownership will leave the contract without an owner,
     * thereby removing any functionality that is only available to the owner.
     */
    function renounceOwnership() public virtual onlyOwner {
        _transferOwnership(address(0));
    }

    /**
     * @dev Transfers ownership of the contract to a new account (`newOwner`).
     * Can only be called by the current owner.
     */
    function transferOwnership(address newOwner) public virtual onlyOwner {
        require(
            newOwner != address(0),
            "Ownable: new owner is the zero address"
        );
        _transferOwnership(newOwner);
    }

    /**
     * @dev Transfers ownership of the contract to a new account (`newOwner`).
     * Internal function without access restriction.
     */
    function _transferOwnership(address newOwner) internal virtual {
        address oldOwner = _owner;
        _owner = newOwner;
        emit OwnershipTransferred(oldOwner, newOwner);
    }
}

interface InterfaceValidator {
    enum Status {
        // validator not exist, default status
        NotExist,
        // validator created
        Created,
        // anyone has staked for the validator
        Staked,
        // validator's staked coins < MinimalStakingCoin
        Unstaked,
        // validator is jailed by system(validator have to repropose)
        Jailed
    }
    
    function getAllValidatorInfo() external view returns (uint256 totalValidatorCount,uint256 totalStakedCoins,address[] memory,InterfaceValidator.Status[] memory,uint256[] memory,string[] memory,string[] memory);
    function getStakingTime(address _staker, address _validator) external view returns(uint256);
    function validatorSpecificInfo2(address validatorAddress, address user) external view returns(uint256 totalStakedCoins, InterfaceValidator.Status status, uint256 selfStakedCoins, uint256 masterVoters, uint256 stakers, address);
}

contract Staking is Ownable {

    InterfaceValidator public valDataContract = InterfaceValidator(0x0c4F6F3E5458AC81005EEF84521373904F18e36e);//update validator contract address while deploying

    mapping(address => uint256) stakerInfo;

    uint256 public  MinimalStakingCoin = 1 ether;

    uint16 public MaxStakers = 3; 

    address[] public currentStakerSet;

    // total stake of all stakers
    uint256 public totalStake;

    uint256 public totalPenalty;

    uint64 public stakingLockPeriod = 7776000;

    uint256 public penaltyPercentage = 1000;   //10%

    mapping(address => uint) public rewardWithdrawalTime;

    mapping(address => uint) public stakeTime;

    mapping(address => uint) public valStakeTime;
    //LastRewardtime
    uint public lastRewardTime;
    //lastRewardTime => reflectionPerent
    mapping(uint => uint) public reflectionPercentSum;

    event LogUnstake(
        address indexed staker,
        uint256 amount,
        uint256 penalty,
        uint256 time
    ); 
    event LogDistributeReward(
        uint256 reward,
        uint256 time
    );
   
    event LogStake(
        address indexed staker,
        uint256 staking,
        uint256 time
    );

    event LogRemoveFromCurrentStaker(address indexed staker, uint256 time);

    event withdrawStakingRewardEv(address indexed user,uint reward,uint timeStamp);

    function stake()
        public
        payable
        returns (bool)
    {
        address payable staker = payable(msg.sender);
        uint256 staking = msg.value;

        require(staking >= MinimalStakingCoin,
            "Staking coins not enough");

        require(
            (currentStakerSet.length) < MaxStakers,
            "Can't stake slot is full"
        );
        
        // stake at first time to this contract
        if (stakerInfo[staker] == 0) {
            if(lastRewardTime == 0)
            {
                lastRewardTime = block.timestamp;
            }
            rewardWithdrawalTime[staker] = lastRewardTime;
            stakeTime[staker] = lastRewardTime;
        }
        else
        {
            withdrawStakingReward(staker);
        }

        stakerInfo[staker] = stakerInfo[staker] + (staking);

        if (!isActiveStaker(staker)) {
                currentStakerSet.push(staker);
        }

        totalStake = totalStake + (staking);

        emit LogStake(staker, staking, block.timestamp);
        return true;
    }

    function unstake() external returns (bool){ 

        address payable staker = payable(tx.origin);

        uint256 unstakeAmount = stakerInfo[staker];

        require(unstakeAmount > 0, "You don't have any stake");

        withdrawStakingReward(staker);
        
        stakerInfo[staker] = stakerInfo[staker] - (unstakeAmount);
       
        totalStake = totalStake - (unstakeAmount);

        removeStakerFromCurrrentSet(staker);

        uint256 remaining;
        uint256 penalty;

        if(block.timestamp <= (stakeTime[staker] + stakingLockPeriod) && penaltyPercentage > 0) {
            penalty = ((unstakeAmount * penaltyPercentage) / 10000);
            // send stake back to staker after deducting penalty
            remaining = unstakeAmount - penalty;
            totalPenalty = totalPenalty + penalty;
            payable(staker).transfer(remaining);
        } else {
            // send stake back to staker
            payable(staker).transfer(unstakeAmount);
        }

        rewardWithdrawalTime[staker] = 0 ;
        stakeTime[staker] = 0 ;

        emit LogUnstake(staker, unstakeAmount, penalty, block.timestamp);
        return true;
    }

    function withdrawStakingReward(address staker) public returns(bool)
    {
        uint validPercent;
        uint validValidatorPercent;
        if(rewardWithdrawalTime[staker] > 0)
        validPercent = reflectionPercentSum[lastRewardTime] - reflectionPercentSum[rewardWithdrawalTime[staker]];
        validValidatorPercent = reflectionPercentSum[lastRewardTime] - reflectionPercentSum[valStakeTime[staker]];

        (uint256 validatorsStakedCoins, , , , ,)  = valDataContract.validatorSpecificInfo2(staker,staker);

        if((validPercent + validValidatorPercent) > 0)
        {
            if(rewardWithdrawalTime[staker] > 0)
            rewardWithdrawalTime[staker] = lastRewardTime;
            if(valDataContract.getStakingTime(staker,staker) > 0)
            valStakeTime[staker] = lastRewardTime;
            uint reward = stakerInfo[staker] * validPercent / 1000000000000000000;
            uint valReward = validatorsStakedCoins * validValidatorPercent / 1000000000000000000;
            payable(staker).transfer(reward + valReward);
            emit withdrawStakingRewardEv(staker, (reward + valReward), block.timestamp);
        }
        return true;
    }


    // distributeReward distributes reward to all active stakers and validators
    function distributeReward()
        external
        payable
    {
        uint256 reward = msg.value + totalPenalty;

        (uint256 totalstakes,) = getTotalStakeOfActiveStakersExcept(address(0));

        (, ,address[] memory highestValidatorsSet, , , ,) = valDataContract.getAllValidatorInfo();
        uint256 totalValidators = highestValidatorsSet.length;
        uint256 totalValidatorsStakedCoins;

        for(uint8 i=0; i < totalValidators; i++){

        (uint256 validatorsStakedCoins, , , , ,)  = valDataContract.validatorSpecificInfo2(highestValidatorsSet[i],highestValidatorsSet[i]);
        totalValidatorsStakedCoins += validatorsStakedCoins;
        }

        require(totalstakes + totalValidatorsStakedCoins > 0, "No stakers");

        uint lastRewardHold = reflectionPercentSum[lastRewardTime];
        lastRewardTime = block.timestamp;
        
        reflectionPercentSum[lastRewardTime] = lastRewardHold + (reward * 1000000000000000000 / (totalstakes + totalValidatorsStakedCoins));
        totalPenalty = 0;
        

        emit LogDistributeReward(reward, block.timestamp);
    }

    function removeStakerFromCurrrentSet(address staker) private {
        for (
            uint256 i = 0;
            i < currentStakerSet.length;
            i++
        ) {
            if (staker == currentStakerSet[i]) {
                // remove it
                if (i != currentStakerSet.length - 1) {
                    currentStakerSet[i] = currentStakerSet[currentStakerSet
                        .length - 1];
                }

                currentStakerSet.pop();
                emit LogRemoveFromCurrentStaker(staker, block.timestamp);

                break;
            }
        }
    }

    function checkforpenalty(address staker) external view returns(bool isPenalty)
    {
         if(block.timestamp <= (stakeTime[staker] + stakingLockPeriod) && penaltyPercentage > 0) {
            isPenalty = true;
         }
    }

    function getStakingInfo(address staker)
        public
        view
        returns (
            uint256
        )
    {
        return (
            stakerInfo[staker]
        );
    }

    function getActiveStakers() public view returns (address[] memory) {
        return currentStakerSet;
    }

    function getTotalStakeOfActiveStakers()
        public
        view
        returns (uint256 total, uint256 len)
    {
        return getTotalStakeOfActiveStakersExcept(address(0));
    }

    function getTotalStakeOfActiveStakersExcept(address sta)
        private
        view
        returns (uint256 total, uint256 len)
    {
        for (uint256 i = 0; i < currentStakerSet.length; i++) {
            if (
                sta != currentStakerSet[i]
            ) {
                total = total + (stakerInfo[currentStakerSet[i]]);
                len++;
            }
        }

        return (total, len);
    }

    function isActiveStaker(address who) public view returns (bool) {
        for (uint256 i = 0; i < currentStakerSet.length; i++) {
            if (currentStakerSet[i] == who) {
                return true;
            }
        }

        return false;
    }

    function viewStakeReward(address _staker) public view returns(uint256 valReward, uint256 stakerReward){
            uint validPercent;
            uint validValidatorPercent;
            if(rewardWithdrawalTime[_staker] > 0)
            validPercent = reflectionPercentSum[lastRewardTime] - reflectionPercentSum[rewardWithdrawalTime[_staker]];
            validValidatorPercent = reflectionPercentSum[lastRewardTime] - reflectionPercentSum[valStakeTime[_staker]];

            (uint256 validatorsStakedCoins, , , , ,)  = valDataContract.validatorSpecificInfo2(_staker,_staker);

            if(validPercent + validValidatorPercent > 0)
            {
                valReward = validatorsStakedCoins * validValidatorPercent / 1000000000000000000;
                stakerReward = stakerInfo[_staker] * validPercent / 1000000000000000000;
                return (valReward, stakerReward) ;
            }
        return (0, 0);
    }

    function updateMaxStakers(
         uint16 _MaxStakers) external onlyOwner
    {
      MaxStakers = _MaxStakers;
    }
    function updateMinimalStakingCoin(uint256 _MinimalStakingCoin
        ) external onlyOwner
    {
      require(_MinimalStakingCoin > 0, 'Incorrect MinimalStakingCoin');
      MinimalStakingCoin = _MinimalStakingCoin;
    }
    function updateStakingLockPeriod(uint64 _stakingLockPeriod) external onlyOwner
    {
      stakingLockPeriod = _stakingLockPeriod * 86400;
    }

    function updatePenaltyPercentage(uint64 _penaltyPercentage) external onlyOwner
    {
        require(_penaltyPercentage < 10000, "Penalty cannot be 100%");
        penaltyPercentage = _penaltyPercentage;
    }

     /**
        admin functions
    */
    function rescueCoins() external onlyOwner{        
        payable(msg.sender).transfer(address(this).balance);
    }

    function mutateValStakeTimeMapping(address validator, uint value) external onlyValDataContract{
        value == 0 ? valStakeTime[validator] = lastRewardTime : valStakeTime[validator] = 0;
    }

     function updateValidatorDataContract(address _validatorData) external onlyOwner
    {
        require(_validatorData != address(0), "invalid contract");
         valDataContract = InterfaceValidator(_validatorData);
    }

    modifier onlyValDataContract() {
        require(msg.sender == address(valDataContract), "onlyValDataContract only");
        _;
    }
}
