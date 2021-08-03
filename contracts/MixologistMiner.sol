// SPDX-License-Identifier: GPL-3.0-or-later
pragma solidity =0.7.3;

import "./libraries/SafeMath.sol";
import "./libraries/ExtendedMath.sol";
import "./libraries/SafeERC20.sol";
import "./interfaces/IERC20.sol";
import "./interfaces/Ownable.sol";
import "./interfaces/ReentrancyGuard.sol";
import "./interfaces/IReferral.sol";
import "./DaikiToken.sol";

/**
 * @title Daikiri Finance's Yield Farming Contract
 * @notice MixologistMiner rewards token stakers and proof-of-work miners with $DAIKI.
 * @author daikiri.finance
 */
contract MixologistMiner is Ownable, ReentrancyGuard {
    using SafeMath for uint256;
    using ExtendedMath for uint256;
    using SafeERC20 for IERC20;

    // Info of each user.
    struct UserInfo {
        uint256 amount; // How many LP tokens the user has provided.
        uint256 rewardDebt; // Reward debt. See explanation below.
        uint256 rewardLockedUp; // Reward locked up
        uint256 nextHarvestUntil; // When can the user harvest again
        //
        // We do some fancy math here. Basically, any point in time, the amount of $REWARD_TOKENs
        // entitled to a user but is pending to be distributed is:
        //
        //   pending reward = (user.amount * pool.accRewardTokenPerShare) - user.rewardDebt
        //
        // Whenever a user deposits or withdraws LP tokens to a pool. Here's what happens:
        //   1. The pool's `accRewardTokenPerShare` (and `lastRewardBlock`) gets updated.
        //   2. User receives the pending reward sent to his/her address.
        //   3. User's `amount` gets updated.
        //   4. User's `rewardDebt` gets updated.
    }

    // Info of each pool.
    struct PoolInfo {
        IERC20 stakingToken; // Address of LP token contract.
        uint256 allocPoint; // How many allocation points assigned to this pool. REWARD_TOKENs to distribute per block.
        uint256 lastRewardBlock; // Last block number that REWARD_TOKENs distribution occurs.
        uint256 accRewardTokenPerShare; // Accumulated REWARD_TOKENs per share, times PRECISION_FACTOR. See below.
        uint256 harvestInterval; // Harvest interval in seconds
    }

    // The REWARD_TOKEN TOKEN!
    DaikiToken public rewardToken;

    // The collateral token for mining
    IERC20 public collateralToken;

    // The required collateral amount for miners
    uint256 public requiredCollateralAmount;

    // Precission factor
    uint256 public PRECISION_FACTOR;

    // Mining reward
    uint256 public miningReward;

    // DAO address
    address public daoAddress;
    // REWARD_TOKEN tokens created per block.
    uint256 public rewardTokenPerBlock;
    // Max harvest interval: 6 hrs
    uint256 public constant MAXIMUM_HARVEST_INTERVAL = 21600; // 6 hrs

    // Maximum emission rate
    uint256 public immutable MAX_EMISSION_RATE;
    uint256 public immutable MAX_MINING_REWARD;

    // Info of each pool.
    PoolInfo[] public poolInfo;
    // Info of each user that stakes LP tokens.
    mapping(uint256 => mapping(address => UserInfo)) public userInfo;
    // Total allocation points. Must be the sum of all allocation points in all pools.
    uint256 public totalAllocPoint = 0;
    // The block number when REWARD_TOKEN mining starts.
    uint256 public startBlock;
    // Total locked up rewards
    uint256 public totalLockedUpRewards;

    // REWARD_TOKEN referral contract address.
    IReferral public immutable referral;
    // Referral commission rate in basis points.
    uint16 public referralCommissionRate = 200;
    // Max referral commission rate: 5%.
    uint16 public constant MAXIMUM_REFERRAL_COMMISSION_RATE = 500;

    mapping(IERC20 => bool) public poolExistence;

    /**
     * @notice Deploy Mixologist
     * @param _rewardToken The address of the reward token
     * @param _startBlock The number when $REWARD_TOKEN mining starts
     * @param _daoAddress DAO address
     * @param _rewardTokenPerBlock The number of $REWARD_TOKENs created every block
     */
    constructor(
        DaikiToken _rewardToken,
        uint256 _startBlock,
        address _daoAddress,
        uint256 _rewardTokenPerBlock,
        uint256 _miningReward,
        uint256 _maxEmissionRate,
        uint256 _maxMiningReward,
        IReferral _referral,
        IERC20 _collateralToken,
        uint256 _requiredCollateralAmount
    ) Ownable() {
        rewardToken = _rewardToken;
        startBlock = _startBlock;
        daoAddress = _daoAddress;
        rewardTokenPerBlock = _rewardTokenPerBlock;
        miningReward = _miningReward;
        MAX_EMISSION_RATE = _maxEmissionRate;
        MAX_MINING_REWARD = _maxMiningReward;
        referral = _referral;
        collateralToken = _collateralToken;
        requiredCollateralAmount = _requiredCollateralAmount;

        uint256 decimalsRewardToken = uint256(rewardToken.decimals());
        require(
            decimalsRewardToken < 30,
            "Mixologist::constructor:invalid-decimals"
        );

        PRECISION_FACTOR = uint256(10**(uint256(30).sub(decimalsRewardToken)));

        _initialize_mining();
    }

    /* MODIFIERS */
    modifier nonDuplicated(IERC20 _stakingToken) {
        require(
            poolExistence[_stakingToken] == false,
            "nonDuplicated: duplicated"
        );
        _;
    }

    /** METHODS */

    function poolLength() external view returns (uint256) {
        return poolInfo.length;
    }

    // Add a new lp to the pool. Can only be called by the owner.
    function add(
        uint256 _allocPoint,
        IERC20 _stakingToken,
        uint256 _harvestInterval
    ) external onlyOwner nonDuplicated(_stakingToken) {
        // Prevent EOA or non-token contract to be added
        require(_stakingToken.balanceOf(address(this)) >= 0);
        require(
            _harvestInterval <= MAXIMUM_HARVEST_INTERVAL,
            "add: invalid harvest interval"
        );
        uint256 lastRewardBlock = block.number > startBlock
            ? block.number
            : startBlock;
        totalAllocPoint = totalAllocPoint.add(_allocPoint);
        poolExistence[_stakingToken] = true;
        poolInfo.push(
            PoolInfo({
                stakingToken: _stakingToken,
                allocPoint: _allocPoint,
                lastRewardBlock: lastRewardBlock,
                accRewardTokenPerShare: 0,
                harvestInterval: _harvestInterval
            })
        );
        emit Add(_allocPoint, address(_stakingToken), _harvestInterval);
    }

    // Update the given pool's REWARD_TOKEN allocation point. Can only be called by the owner.
    function set(
        uint256 _pid,
        uint256 _allocPoint,
        uint256 _harvestInterval
    ) external onlyOwner {
        require(
            _harvestInterval <= MAXIMUM_HARVEST_INTERVAL,
            "set: invalid harvest interval"
        );
        totalAllocPoint = totalAllocPoint.sub(poolInfo[_pid].allocPoint).add(
            _allocPoint
        );
        poolInfo[_pid].allocPoint = _allocPoint;
        poolInfo[_pid].harvestInterval = _harvestInterval;
        emit Set(_pid, _allocPoint, _harvestInterval);
    }

    // Return reward multiplier over the given _from to _to block.
    function getMultiplier(uint256 _from, uint256 _to)
        public
        pure
        returns (uint256)
    {
        return _to.sub(_from);
    }

    // View function to see pending REWARD_TOKENs on frontend.
    function pendingRewardToken(uint256 _pid, address _user)
        external
        view
        returns (uint256)
    {
        PoolInfo storage pool = poolInfo[_pid];
        UserInfo storage user = userInfo[_pid][_user];
        uint256 accRewardTokenPerShare = pool.accRewardTokenPerShare;
        uint256 stakedTokenSupply = pool.stakingToken.balanceOf(address(this));
        if (
            block.number > pool.lastRewardBlock &&
            stakedTokenSupply != 0 &&
            totalAllocPoint > 0
        ) {
            uint256 multiplier = getMultiplier(
                pool.lastRewardBlock,
                block.number
            );
            uint256 rewardTokenReward = multiplier
                .mul(rewardTokenPerBlock)
                .mul(pool.allocPoint)
                .div(totalAllocPoint);
            accRewardTokenPerShare = accRewardTokenPerShare.add(
                rewardTokenReward.mul(PRECISION_FACTOR).div(stakedTokenSupply)
            );
        }
        uint256 pending = user
            .amount
            .mul(accRewardTokenPerShare)
            .div(PRECISION_FACTOR)
            .sub(user.rewardDebt);
        return pending.add(user.rewardLockedUp);
    }

    // View function to see if user can harvest REWARD_TOKENs
    function canHarvest(uint256 _pid, address _user)
        public
        view
        returns (bool)
    {
        UserInfo storage user = userInfo[_pid][_user];
        return block.timestamp >= user.nextHarvestUntil;
    }

    // Update reward variables for all pools. Be careful of gas spending!
    function massUpdatePools() public {
        uint256 length = poolInfo.length;
        for (uint256 pid = 0; pid < length; ++pid) {
            updatePool(pid);
        }
    }

    // Update reward variables of the given pool to be up-to-date.
    function updatePool(uint256 _pid) public {
        PoolInfo storage pool = poolInfo[_pid];
        if (block.number <= pool.lastRewardBlock) {
            return;
        }
        uint256 stakedTokenSupply = pool.stakingToken.balanceOf(address(this));
        if (stakedTokenSupply == 0 || pool.allocPoint == 0) {
            pool.lastRewardBlock = block.number;
            return;
        }
        uint256 multiplier = getMultiplier(pool.lastRewardBlock, block.number);
        uint256 rewardTokenReward = multiplier
            .mul(rewardTokenPerBlock)
            .mul(pool.allocPoint)
            .div(totalAllocPoint);
        rewardToken.mint(daoAddress, rewardTokenReward.div(10));
        rewardToken.mint(address(this), rewardTokenReward);
        pool.accRewardTokenPerShare = pool.accRewardTokenPerShare.add(
            rewardTokenReward.mul(PRECISION_FACTOR).div(stakedTokenSupply)
        );
        pool.lastRewardBlock = block.number;
    }

    // Deposit LP tokens to Mixologist for REWARD_TOKEN allocation.
    function deposit(
        uint256 _pid,
        uint256 _amount,
        address _referrer
    ) external nonReentrant {
        PoolInfo storage pool = poolInfo[_pid];
        UserInfo storage user = userInfo[_pid][msg.sender];
        updatePool(_pid);
        if (
            _amount > 0 &&
            address(referral) != address(0) &&
            _referrer != address(0) &&
            _referrer != msg.sender
        ) {
            referral.recordReferral(msg.sender, _referrer);
        }
        payOrLockupPendingRewardToken(_pid);
        if (_amount > 0) {
            uint256 balanceBefore = pool.stakingToken.balanceOf(address(this));
            pool.stakingToken.safeTransferFrom(
                address(msg.sender),
                address(this),
                _amount
            );
            _amount = pool.stakingToken.balanceOf(address(this)).sub(
                balanceBefore
            );
            user.amount = user.amount.add(_amount);
        }
        user.rewardDebt = user.amount.mul(pool.accRewardTokenPerShare).div(
            PRECISION_FACTOR
        );
        emit Deposit(msg.sender, _pid, _amount);
    }

    // Withdraw LP tokens from Mixologist.
    function withdraw(uint256 _pid, uint256 _amount) external nonReentrant {
        PoolInfo storage pool = poolInfo[_pid];
        UserInfo storage user = userInfo[_pid][msg.sender];
        require(user.amount >= _amount, "withdraw: not good");
        updatePool(_pid);
        payOrLockupPendingRewardToken(_pid);
        if (_amount > 0) {
            user.amount = user.amount.sub(_amount);
            pool.stakingToken.safeTransfer(address(msg.sender), _amount);
        }
        user.rewardDebt = user.amount.mul(pool.accRewardTokenPerShare).div(
            PRECISION_FACTOR
        );
        emit Withdraw(msg.sender, _pid, _amount);
    }

    // Withdraw without caring about rewards. EMERGENCY ONLY.
    function emergencyWithdraw(uint256 _pid) external nonReentrant {
        PoolInfo storage pool = poolInfo[_pid];
        UserInfo storage user = userInfo[_pid][msg.sender];
        uint256 amount = user.amount;
        user.amount = 0;
        user.rewardDebt = 0;
        user.rewardLockedUp = 0;
        user.nextHarvestUntil = 0;
        pool.stakingToken.safeTransfer(address(msg.sender), amount);
        emit EmergencyWithdraw(msg.sender, _pid, amount);
    }

    // Pay or lockup pending REWARD_TOKENs
    function payOrLockupPendingRewardToken(uint256 _pid) internal {
        PoolInfo storage pool = poolInfo[_pid];
        UserInfo storage user = userInfo[_pid][msg.sender];

        if (user.nextHarvestUntil == 0) {
            user.nextHarvestUntil = block.timestamp.add(pool.harvestInterval);
        }

        uint256 pending = user
            .amount
            .mul(pool.accRewardTokenPerShare)
            .div(PRECISION_FACTOR)
            .sub(user.rewardDebt);

        if (canHarvest(_pid, msg.sender)) {
            if (pending > 0 || user.rewardLockedUp > 0) {
                uint256 totalRewards = pending.add(user.rewardLockedUp);

                // reset lockup
                totalLockedUpRewards = totalLockedUpRewards.sub(
                    user.rewardLockedUp
                );
                user.rewardLockedUp = 0;
                user.nextHarvestUntil = block.timestamp.add(
                    pool.harvestInterval
                );

                // send rewards
                safeRewardTokenTransfer(msg.sender, totalRewards);
                payReferralCommission(msg.sender, totalRewards);
            }
        } else if (pending > 0) {
            user.rewardLockedUp = user.rewardLockedUp.add(pending);
            totalLockedUpRewards = totalLockedUpRewards.add(pending);
            emit RewardLockedUp(msg.sender, _pid, pending);
        }
    }

    // Safe rewardToken transfer function, just in case if rounding error causes pool to not have enough REWARD_TOKEN.
    function safeRewardTokenTransfer(address _to, uint256 _amount) internal {
        uint256 rewardTokenBalance = rewardToken.balanceOf(address(this));
        bool transferSuccess = false;
        if (_amount > rewardTokenBalance) {
            transferSuccess = rewardToken.transfer(_to, rewardTokenBalance);
        } else {
            transferSuccess = rewardToken.transfer(_to, _amount);
        }
        require(transferSuccess, "safeRewardTokenTransfer: Transfer failed");
    }

    // Update dao address by the previous dao.
    function setDaoAddress(address _daoAddress) external onlyOwner {
        daoAddress = _daoAddress;
        emit SetDaoAddress(msg.sender, _daoAddress);
    }

    function updateEmissionRate(uint256 _rewardTokenPerBlock)
        external
        onlyOwner
    {
        require(
            _rewardTokenPerBlock <= MAX_EMISSION_RATE,
            "updateEmissionRate: Too high emission"
        );
        massUpdatePools();
        rewardTokenPerBlock = _rewardTokenPerBlock;
        emit UpdateEmissionRate(msg.sender, _rewardTokenPerBlock);
    }

    // Update referral commission rate by the owner
    function setReferralCommissionRate(uint16 _referralCommissionRate)
        external
        onlyOwner
    {
        require(
            _referralCommissionRate <= MAXIMUM_REFERRAL_COMMISSION_RATE,
            "setReferralCommissionRate: invalid referral commission rate basis points"
        );
        referralCommissionRate = _referralCommissionRate;
    }

    // Pay referral commission to the referrer who referred this user.
    function payReferralCommission(address _user, uint256 _pending) internal {
        if (address(referral) != address(0) && referralCommissionRate > 0) {
            address referrer = referral.getReferrer(_user);
            uint256 commissionAmount = _pending.mul(referralCommissionRate).div(
                10000
            );

            if (referrer != address(0) && commissionAmount > 0) {
                rewardToken.mint(referrer, commissionAmount);
                emit ReferralCommissionPaid(_user, referrer, commissionAmount);
            }
        }
    }

    // Only update before start of farm
    function updateStartBlock(uint256 _startBlock) external onlyOwner {
        require(startBlock > block.number, "Farm already started");
        uint256 length = poolInfo.length;

        for (uint256 pid = 0; pid < length; ++pid) {
            PoolInfo storage pool = poolInfo[pid];
            pool.lastRewardBlock = _startBlock;
        }

        startBlock = _startBlock;

        emit UpdateStartBlock(_startBlock);
    }

    /* EVENTS */
    event Deposit(address indexed user, uint256 indexed pid, uint256 amount);
    event Withdraw(address indexed user, uint256 indexed pid, uint256 amount);
    event EmergencyWithdraw(
        address indexed user,
        uint256 indexed pid,
        uint256 amount
    );
    event SetDaoAddress(address indexed user, address indexed newAddress);
    event SetReferralAddress(
        address indexed user,
        IReferral indexed newAddress
    );
    event UpdateEmissionRate(address indexed user, uint256 rewardTokenPerBlock);
    event ReferralCommissionPaid(
        address indexed user,
        address indexed referrer,
        uint256 commissionAmount
    );
    event RewardLockedUp(
        address indexed user,
        uint256 indexed pid,
        uint256 amountLockedUp
    );
    event Add(
        uint256 allocPoint,
        address stakingToken,
        uint256 harvestInterval
    );
    event Set(uint256 pid, uint256 allocPoint, uint256 harvestInterval);
    event UpdateStartBlock(uint256 startBlock);

    /* PoW MINING */

    uint256 public latestDifficultyPeriodStarted;

    // number of 'blocks' mined
    uint256 public epochCount;

    uint256 public constant _BLOCKS_PER_READJUSTMENT = 1024;

    // a little number
    uint256 public constant _MINIMUM_TARGET = 2**16;

    // a big number is easier ; just find a solution that is smaller
    // uint256 public _MAXIMUM_TARGET = 2**224; bitcoin uses 224
    uint256 public constant _MAXIMUM_TARGET = 2**234;

    uint256 public miningTarget;

    bytes32 public challengeNumber; // generate a new one when reward is minted

    // uint256 public rewardEra;
    // uint256 public maxSupplyEra;

    address public lastRewardTo;
    uint256 public lastRewardAmount;
    uint256 public lastRewardEthBlockNumber; // maintain name for compatibility with existing miners

    mapping(bytes32 => bytes32) solutionForChallenge;

    uint256 public tokensMined;

    function _initialize_mining() private {
        miningTarget = _MAXIMUM_TARGET;
        latestDifficultyPeriodStarted = block.number;
        _startNewMiningEpoch();
    }

    /**
     * @dev Called `mint` to maintain compatibility with existing miners
     */
    function mint(uint256 nonce, bytes32 challenge_digest)
        public
        returns (bool success)
    {
        require(block.number >= startBlock, "Mining has not started");

        // The PoW must contain work that includes a recent block hash (challenge number) and the msg.sender's address
        // to prevent MITM attacks.
        bytes32 digest = keccak256(
            abi.encodePacked(challengeNumber, msg.sender, nonce)
        );

        // The challenge digest must match the expected
        if (digest != challenge_digest)
            revert("MixologistMiner::mint:challenge-digest-mismatch");

        // The digest must be smaller than the target
        if (uint256(digest) > miningTarget)
            revert("MixologistMiner::mint:digest-smaller-than-target");

        // Only allow one reward for each challenge
        bytes32 solution = solutionForChallenge[challengeNumber];
        solutionForChallenge[challengeNumber] = digest;

        // prevent the same answer from awarding twice
        if (solution != 0x0) {
            _startNewMiningEpoch();
            return false;
        }

        // Check required collateral
        uint256 collateral_amount = collateralToken.balanceOf(msg.sender);
        require(
            collateral_amount >= requiredCollateralAmount,
            "MixologistMiner::mint:insufficient-collateral"
        );

        // Get Reward Amount
        uint256 reward_amount = getMiningReward();

        // Mint new tokens
        rewardToken.mint(msg.sender, reward_amount);

        // Update total amount of `mined` tokens
        tokensMined = tokensMined.add(reward_amount);

        // Set readonly diagnostic data
        lastRewardTo = msg.sender;
        lastRewardAmount = reward_amount;
        lastRewardEthBlockNumber = block.number; // maintain name for compatibility with existing miners

        _startNewMiningEpoch();

        emit Mined(msg.sender, reward_amount, epochCount, challengeNumber);

        return true;
    }

    // A new 'block' to be mined
    function _startNewMiningEpoch() internal {
        epochCount = epochCount.add(1);

        // every so often, readjust difficulty. Don't readjust when deploying
        if (epochCount % _BLOCKS_PER_READJUSTMENT == 0) {
            _reAdjustDifficulty();
        }

        // Make the latest block hash a part of the next challenge for PoW to prevent pre-mining future blocks
        // do this last since this is a protection mechanism in the mint() function
        challengeNumber = keccak256(
            abi.encodePacked(
                challengeNumber,
                address(this),
                blockhash(block.number - 1)
            )
        );
    }

    // https://en.bitcoin.it/wiki/Difficulty#What_is_the_formula_for_difficulty.3F
    // as of 2017 the bitcoin difficulty was up to 17 zeroes, it was only 8 in the early days

    // Readjust the target by 5 percent
    function _reAdjustDifficulty() internal {
        uint256 ethBlocksSinceLastDifficultyPeriod = block.number -
            latestDifficultyPeriodStarted;
        // assume 360 ethereum blocks per hour

        // we want miners to spend 10 minutes to mine each 'block', about 60 ethereum blocks = one 0xbitcoin epoch
        uint256 epochsMined = _BLOCKS_PER_READJUSTMENT; // 256

        uint256 targetEthBlocksPerDiffPeriod = epochsMined * 60; // should be 60 times slower than ethereum

        // if there were less eth blocks passed in time than expected
        if (ethBlocksSinceLastDifficultyPeriod < targetEthBlocksPerDiffPeriod) {
            uint256 excess_block_pct = (targetEthBlocksPerDiffPeriod.mul(100))
                .div(ethBlocksSinceLastDifficultyPeriod);

            uint256 excess_block_pct_extra = excess_block_pct
                .sub(100)
                .limitLessThan(1000);
            // If there were 5% more blocks  mined than expected then this is 5. If there were 100% more blocks mined than expected then this is 100.

            // Make it harder
            miningTarget = miningTarget.sub(
                miningTarget.div(2000).mul(excess_block_pct_extra)
            ); // by up to 50%
        } else {
            uint256 shortage_block_pct = (
                ethBlocksSinceLastDifficultyPeriod.mul(100)
            ).div(targetEthBlocksPerDiffPeriod);

            uint256 shortage_block_pct_extra = shortage_block_pct
                .sub(100)
                .limitLessThan(1000); // always between 0 and 1000

            // Make it easier
            miningTarget = miningTarget.add(miningTarget.div(2000)).mul(
                shortage_block_pct_extra
            ); // by up to 50%
        }

        latestDifficultyPeriodStarted = block.number;

        if (miningTarget < _MINIMUM_TARGET) // very difficult
        {
            miningTarget = _MINIMUM_TARGET;
        }

        if (miningTarget > _MAXIMUM_TARGET) // very easy
        {
            miningTarget = _MAXIMUM_TARGET;
        }
    }

    // This is a recent block hash, used to prevent pre-mining future blocks
    function getChallengeNumber() public view returns (bytes32) {
        return challengeNumber;
    }

    // The number of zeroes the digest of the PoW solution requires. Auto adjusts
    function getMiningDifficulty() public view returns (uint256) {
        return _MAXIMUM_TARGET.div(miningTarget);
    }

    function getMiningTarget() public view returns (uint256) {
        return miningTarget;
    }

    function getMiningReward() public view returns (uint256) {
        return miningReward;
    }

    // Help debug mining software
    function getMintDigest(
        uint256 nonce,
        bytes32 challenge_digest,
        bytes32 challenge_number
    ) public view returns (bytes32 digesttest) {
        bytes32 digest = keccak256(
            abi.encodePacked(challenge_number, msg.sender, nonce)
        );
        return digest;
    }

    // Help debug mining software
    function checkMintSolution(
        uint256 nonce,
        bytes32 challenge_digest,
        bytes32 challenge_number,
        uint256 testTarget
    ) public view returns (bool success) {
        bytes32 digest = keccak256(
            abi.encodePacked(challenge_number, msg.sender, nonce)
        );

        if (uint256(digest) > testTarget) revert();

        return (digest == challenge_digest);
    }

    function changeMiningReward(uint256 _miningReward) external onlyOwner {
        require(
            _miningReward <= MAX_MINING_REWARD,
            "changeMiningReward: Too high reward"
        );
        uint256 oldMiningReward = miningReward;
        miningReward = _miningReward;
        emit MiningRewardChanged(
            address(rewardToken),
            miningReward,
            oldMiningReward
        );
    }

    function changeRequiredCollateralAmount(uint256 _newCollateralAmount)
        public
        onlyOwner
    {
        uint256 oldCollateralAmount = requiredCollateralAmount;
        requiredCollateralAmount = _newCollateralAmount;
        emit RequiredCollateralChanged(
            address(collateralToken),
            requiredCollateralAmount,
            oldCollateralAmount
        );
    }

    event MiningRewardChanged(
        address rewardToken,
        uint256 newMiningReward,
        uint256 oldMiningReward
    );

    event RequiredCollateralChanged(
        address collateralToken,
        uint256 newRequiredCollateral,
        uint256 oldRequiredCollateral
    );

    event Mined(
        address indexed from,
        uint256 reward_amount,
        uint256 epochCount,
        bytes32 newChallengeNumber
    );
}
