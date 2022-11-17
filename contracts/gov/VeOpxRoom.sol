// SPDX-License-Identifier: MIT

pragma solidity 0.8.16;

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";


import "@openzeppelin/contracts/security/ReentrancyGuard.sol";

import "@openzeppelin/contracts-upgradeable/security/PausableUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/access/OwnableUpgradeable.sol";

import "./interfaces/Ive.sol";
import "./interfaces/IveListener.sol";
import "./interfaces/IveOpxRoom.sol";

contract VeOpxRoom is IveOpxRoom, IveListener, ReentrancyGuard, PausableUpgradeable, OwnableUpgradeable {
    using SafeERC20 for IERC20;

    /* ========== DATA STRUCTURES ========== */

    struct Memberseat {
        uint256 lastSnapshotIndex;
        uint256 rewardEarned;
        uint256 epochTimerStart;
    }

    struct BoardroomSnapshot {
        uint256 time;
        uint256 rewardReceived;
        uint256 rewardPerShare;
    }

    /* ========== STATE VARIABLES ========== */

    uint256 private _totalSupply;
    uint256 private _totalRewardDistributed;
    mapping(address => uint256) private _balances;
    mapping(address => uint256) private _depositedNFT;
    mapping(uint256 => address) private _stakerOfNFT;

    // epoch
    uint256 public startTime;
    uint256 public lastEpochTime;
    uint256 private epoch_ = 0;
    uint256 private epochLength_ = 0;

    // reward
    uint256 public epochReward;

    address public ve;
    address public reward; // USDC

    address public reserveFund;

    mapping(address => Memberseat) public members;
    BoardroomSnapshot[] public boardroomHistory;

    uint256 public withdrawLockupEpochs;

    mapping(address => bool) public authorizer;


    address public voter;

    /* ========== EVENTS ========== */

    event Staked(address indexed user, uint256 tokenId, uint256 weight);
    event Withdrawn(address indexed user, uint256 tokenId, uint256 weight);
    event EmergencyWithdraw(address indexed user, uint256 tokenId, uint256 weight);
    event RewardPaid(address indexed user, uint256 earned);
    event RewardTaxed(address indexed user, uint256 taxed);
    event RewardAdded(address indexed user, uint256 amount);
    event OnERC721Received(address operator, address from, uint256 tokenId, bytes data);

    /* ========== Modifiers =============== */

    modifier checkEpoch() {
        uint256 _nextEpochPoint = nextEpochPoint();
        require(block.timestamp >= _nextEpochPoint, "!opened");

        _;

        lastEpochTime = _nextEpochPoint;
        epoch_ += 1;
    }

    modifier onlyAuthorizer() {
        require(authorizer[msg.sender], "!authorizer");
        _;
    }

    modifier memberExists() {
        require(_balances[msg.sender] > 0, "The member does not exist");
        _;
    }

    modifier updateReward(address member) {
        if (member != address(0)) {
            _updateReward(member);
        }
        _;
    }

    modifier onlyVe() {
        require(msg.sender == ve, "!ve");
        _;
    }

    modifier onlyVoter() {
        require(msg.sender == voter, "!voter");
        _;
    }


    function _updateReward(address member) internal {
        Memberseat memory seat = members[member];
        seat.rewardEarned = earned(member);
        seat.lastSnapshotIndex = latestSnapshotIndex();
        members[member] = seat;
    }

    /* ========== GOVERNANCE ========== */

    function initialize(
        address _reward,
        address _ve,
        address _reserveFund,
        uint256 _startTime
    ) external initializer {
        PausableUpgradeable.__Pausable_init();
        OwnableUpgradeable.__Ownable_init();

        reward = _reward;
        ve = _ve;
        reserveFund = _reserveFund;

        BoardroomSnapshot memory genesisSnapshot = BoardroomSnapshot({time : block.number, rewardReceived : 0, rewardPerShare : 0});
        boardroomHistory.push(genesisSnapshot);

        startTime = _startTime;
        epochLength_ = 1 hours;
        lastEpochTime = _startTime - epochLength_;

        withdrawLockupEpochs = 1;
        // Lock for 1 epochs

        epochReward = 1000000000000000;
        // 0.001 WETH
        authorizer[msg.sender] = true;
    }

    function setNextEpochPoint(uint256 _nextEpochPoint) external onlyOwner {
        require(_nextEpochPoint >= block.timestamp, "nextEpochPoint could not be the past");
        lastEpochTime = _nextEpochPoint - epochLength_;
    }

    function setEpochLength(uint256 _epochLength) external onlyOwner {
        //require(_epochLength >= 1 days && _epochLength <= 56 days, "out of range");
        epochLength_ = _epochLength;
    }

    function setLockUp(uint256 _withdrawLockupEpochs) external onlyOwner {
        require(_withdrawLockupEpochs <= 56, "out of range");
        // <= 2 week
        withdrawLockupEpochs = _withdrawLockupEpochs;
    }

    function setEpochReward(uint256 _epochReward) external onlyOwner {
        epochReward = _epochReward;
    }

    function setAuthorizer(address _address, bool _on) external onlyOwner {
        authorizer[_address] = _on;
    }

    function setReserveFund(address _reserveFund) external onlyOwner {
        require(_reserveFund != address(0), "zero");
        reserveFund = _reserveFund;
    }

    function setNewVe(address _newVe) external onlyOwner {
        require(_newVe != address(0), "zero");
        ve = _newVe;
    }

    function setNewVoter(address _newVoter) external onlyOwner {
        require(_newVoter != address(0), "zero");
        voter = _newVoter;
    }

    function setNewReward(address _newReward) external onlyOwner {
        IERC20 _oldReward = IERC20(reward);
        _oldReward.safeTransfer(owner(), _oldReward.balanceOf(address(this)));
        reward = _newReward;
    }

    /* ========== VIEW FUNCTIONS ========== */

    function totalSupply() external view returns (uint256) {
        return _totalSupply;
    }

    function totalRewardDistributed() external view returns (uint256) {
        return _totalRewardDistributed;
    }

    function balanceOf(address account) external view returns (uint256) {
        return _balances[account];
    }

    function depositedNFT(address account) external view returns (uint256) {
        return _depositedNFT[account];
    }

    function stakerOfNFT(uint256 tokenId) external override view returns (address) {
        return _stakerOfNFT[tokenId];
    }

    function epoch() public view returns (uint256) {
        return epoch_;
    }

    function nextEpochPoint() public view returns (uint256) {
        return lastEpochTime + nextEpochLength();
    }

    function nextEpochLength() public view returns (uint256) {
        return epochLength_;
    }

    // =========== Snapshot getters

    function latestSnapshotIndex() public view returns (uint256) {
        return boardroomHistory.length - 1;
    }

    function getLatestSnapshot() internal view returns (BoardroomSnapshot memory) {
        return boardroomHistory[latestSnapshotIndex()];
    }

    function getLastSnapshotIndexOf(address member) public view returns (uint256) {
        return members[member].lastSnapshotIndex;
    }

    function getLastSnapshotOf(address member) internal view returns (BoardroomSnapshot memory) {
        return boardroomHistory[getLastSnapshotIndexOf(member)];
    }

    function canWithdraw(address member) external view returns (bool) {
        return members[member].epochTimerStart + withdrawLockupEpochs <= epoch_;
    }

    // =========== Member getters

    function rewardPerShare() public view returns (uint256) {
        return getLatestSnapshot().rewardPerShare;
    }

    function earned(address member) public view returns (uint256) {
        uint256 latestRPS = getLatestSnapshot().rewardPerShare;
        uint256 storedRPS = getLastSnapshotOf(member).rewardPerShare;

        return _balances[member] * (latestRPS - storedRPS) / 1e18 + members[member].rewardEarned;
    }

    /* ========== MUTATIVE FUNCTIONS ========== */

    function _stake(uint256 _tokenId) internal virtual {
        uint256 _weight = uint256(Ive(ve).balanceOfNFT(_tokenId));
        _totalSupply += _weight;
        _balances[msg.sender] = _weight;
        _depositedNFT[msg.sender] = _tokenId;
        _stakerOfNFT[_tokenId] = msg.sender;
        emit Staked(msg.sender, _tokenId, _weight);
    }

    function _withdraw(uint256 _tokenId) internal virtual {
        uint256 _weight = _balances[msg.sender];
        _totalSupply -= _weight;
        _balances[msg.sender] = 0;
        _depositedNFT[msg.sender] = 0;
        _stakerOfNFT[_tokenId] = address(0);
        emit Withdrawn(msg.sender, _tokenId, _weight);
    }

    function stake(uint256 _tokenId) external nonReentrant whenNotPaused updateReward(msg.sender) {
        require(Ive(ve).depositedNFT(msg.sender) == _tokenId, "!owned");
        require(_depositedNFT[msg.sender] == 0, "unstake first");
        if (members[msg.sender].rewardEarned > 0) {
            claimReward();
        }
        _stake(_tokenId);
        members[msg.sender].epochTimerStart = epoch_;
        // reset timer
    }

    function exit() external nonReentrant memberExists whenNotPaused updateReward(msg.sender) {
        uint256 _tokenId = _depositedNFT[msg.sender];
        require(_tokenId > 0, "!staked");
        require(members[msg.sender].epochTimerStart + withdrawLockupEpochs <= epoch_, "still in withdraw lockup");
        _taxReward();
        _withdraw(_tokenId);
    }

    function emergencyWithdraw() external nonReentrant memberExists whenNotPaused updateReward(msg.sender) {
        uint256 _tokenId = _depositedNFT[msg.sender];
        require(_tokenId > 0, "!staked");
        _taxReward();
        Ive _ve = Ive(ve);
        IERC20 _token = IERC20(_ve.token());
        uint256 _before = _token.balanceOf(address(this));
        _ve.emergencyWithdraw(_tokenId);
        uint256 _weight = _token.balanceOf(address(this)) - _before; // _weight is original weight subtracted fee for early withdraw
        _totalSupply -= _balances[msg.sender];
        _balances[msg.sender] = 0;
        _depositedNFT[msg.sender] = 0;
        _stakerOfNFT[_tokenId] = address(0);
        _token.safeTransfer(msg.sender, _weight);
        emit EmergencyWithdraw(msg.sender, _tokenId, _weight);
    }

    function _taxReward() internal updateReward(msg.sender) {
        uint256 _earned = members[msg.sender].rewardEarned;
        if (_earned > 0) {
            members[msg.sender].rewardEarned = 0;
            _safeRewardTransfer(reserveFund, _earned);
            emit RewardTaxed(msg.sender, _earned);
        }
    }

    function claimReward() public updateReward(msg.sender) {
        uint256 _earned = members[msg.sender].rewardEarned;
        if (_earned > 0) {
            members[msg.sender].epochTimerStart = epoch_; // reset timer
            members[msg.sender].rewardEarned = 0;
            _safeRewardTransfer(msg.sender, _earned);
            emit RewardPaid(msg.sender, _earned);
        }
    }

    function _safeRewardTransfer(address _to, uint256 _amount) internal {
        IERC20 _reward = IERC20(reward);
        uint256 _rewardBal = _reward.balanceOf(address(this));
        if (_rewardBal > 0) {
            if (_amount > _rewardBal) {
                _reward.safeTransfer(_to, _rewardBal);
            } else {
                _reward.safeTransfer(_to, _amount);
            }
        }
    }

    function onTokenWeightUpdated(uint256 _tokenId) external override {
        address _staker = _stakerOfNFT[_tokenId];
        if (_staker != address(0)) {
            _updateReward(_staker);
            uint256 _weight = _balances[_staker];
            _totalSupply -= _weight;
            _weight = uint256(Ive(ve).balanceOfNFT(_tokenId));
            _totalSupply += _weight;
            _balances[_staker] = _weight;
        }
    }

    function onRewardUpdated(uint256 _epochReward, uint256 _totalWeight, uint256 _profitShareWeight) external onlyVoter {
        epochReward = (_epochReward * _profitShareWeight) / _totalWeight;
    }

    function onTokenExit(uint256 _tokenId) external nonReentrant whenNotPaused onlyVe {
        address _staker = _stakerOfNFT[_tokenId];
        if (_staker != address(0)) {
            _updateReward(_staker);
            require(_balances[_staker] > 0, "The member does not exist");
            require(members[_staker].epochTimerStart + withdrawLockupEpochs <= epoch_, "still in withdraw lockup");
            uint256 _earned = members[_staker].rewardEarned;
            if (_earned > 0) {
                members[_staker].rewardEarned = 0;
                _safeRewardTransfer(reserveFund, _earned);
                emit RewardTaxed(_staker, _earned);
            }
            uint256 _weight = _balances[_staker];
            _totalSupply -= _weight;
            _balances[_staker] = 0;
            _depositedNFT[_staker] = 0;
            _stakerOfNFT[_tokenId] = address(0);
            emit Withdrawn(_staker, _tokenId, _weight);
        }
    }

    function nft_increase_amount(uint256 _tokenId, uint256 _value) external {
        Ive _ve = Ive(ve);
        IERC20 _token = IERC20(_ve.token());
        _token.safeTransferFrom(msg.sender, address(this), _value);
        _token.safeIncreaseAllowance(address(_ve), _value);
        _ve.increase_amount(_tokenId, _value);
    }

    function nft_increase_unlock_time(uint256 _lock_duration) external {
        uint256 _tokenId = _depositedNFT[msg.sender];
        require(_tokenId > 0, "!staked");
        Ive(ve).increase_unlock_time(_tokenId, _lock_duration);
    }

    function allocateReward() external {
        allocateRewardManually(epochReward);
    }

    function allocateRewardManually(uint256 _amount) public nonReentrant checkEpoch whenNotPaused onlyAuthorizer {
        require(_amount > 0, "Cannot allocate 0");
        require(_totalSupply > 0, "Cannot allocate when totalSupply is 0");

        // Create & add new snapshot
        uint256 prevRPS = getLatestSnapshot().rewardPerShare;
        uint256 nextRPS = prevRPS + (_amount * 1e18 / _totalSupply);

        BoardroomSnapshot memory newSnapshot = BoardroomSnapshot({time : block.number, rewardReceived : _amount, rewardPerShare : nextRPS});
        boardroomHistory.push(newSnapshot);

        IERC20(reward).safeTransferFrom(reserveFund, address(this), _amount);
        _totalRewardDistributed += _amount;
        emit RewardAdded(msg.sender, _amount);
    }

    /* ========== EMERGENCY ========== */

    function pause() external onlyOwner {
        _pause();
    }

    function unpause() external onlyOwner {
        _unpause();
    }

    function governanceRecoverUnsupported(IERC20 _token) external onlyOwner {
        _token.safeTransfer(owner(), _token.balanceOf(address(this)));
    }
}
