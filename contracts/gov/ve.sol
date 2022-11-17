// SPDX-License-Identifier: MIT

pragma solidity 0.8.16;

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC721/IERC721.sol";
import "@openzeppelin/contracts-upgradeable/access/OwnableUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/security/PausableUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/security/ReentrancyGuardUpgradeable.sol";


import "./lib/Base64.sol";
import "./interfaces/IveListener.sol";
import "./interfaces/ICappedMintableBurnableERC20.sol";
import "./interfaces/IOpxNFT.sol";
import "./interfaces/IveOpxRoom.sol";
import "./interfaces/IVoter.sol";

struct Point {
    int128 bias;
    int128 slope; // # -dweight / dt
    uint256 ts;
    uint256 blk; // block
}

/* We cannot really do block numbers per se b/c slope is per time, not per block
* and per block could be fairly bad b/c Ethereum changes blocktimes.
* What we can do is to extrapolate ***At functions */
    struct LockedBalance {
        int128 amount;
        uint256 end;
    }

contract ve is PausableUpgradeable, OwnableUpgradeable, ReentrancyGuardUpgradeable {
    enum DepositType {
        DEPOSIT_FOR_TYPE,
        CREATE_LOCK_TYPE,
        INCREASE_LOCK_AMOUNT,
        INCREASE_UNLOCK_TIME,
        MERGE_TYPE
    }

    event Deposit(
        address indexed provider,
        uint256 tokenId,
        uint256 value,
        uint256 indexed locktime,
        DepositType deposit_type,
        uint256 ts
    );
    event Withdraw(address indexed provider, uint256 tokenId, uint256 value, uint256 ts);
    event Supply(uint256 prevSupply, uint256 supply);

    uint256 internal constant WEEK = 1 weeks;
    uint256 public constant MAXTIME = 42 weeks;
    int128 internal constant iMAXTIME = 42 weeks;
    uint256 internal constant MULTIPLIER = 1 ether;

    address public token;
    uint256 public supply;
    mapping(uint256 => LockedBalance) public locked;

    mapping(uint256 => uint256) public ownership_change;

    uint256 public epoch;
    mapping(uint256 => Point) public point_history; // epoch -> unsigned point
    mapping(uint256 => Point[1000000000]) public user_point_history; // user -> Point[user_epoch]

    mapping(uint256 => uint256) public user_point_epoch;
    mapping(uint256 => int128) public slope_changes; // time -> signed slope change

    mapping(uint256 => uint256) public attachments;
    mapping(uint256 => bool) public voted;

    address public voter;
    address public boardroom;
    address[] public listeners;

    // NFT
    uint256 public totalDepositedNFT;
    address public opxNFT;
    mapping(address => uint256) private _depositedNFT;
    uint256[5] public boostedPercent;

    uint256 public minLockedAmount = 1 ether;
    uint256 public earlyWithdrawFeeRate = 5000;

    modifier onlyVoter() {
        require(msg.sender == voter, "!voter");
        _;
    }

    function initialize(address _token_addr, address _opxNFT) external initializer {
        PausableUpgradeable.__Pausable_init();
        OwnableUpgradeable.__Ownable_init();
        require(_token_addr != address(0) && _opxNFT != address(0), "zero");
        token = _token_addr;
        opxNFT = _opxNFT;
        point_history[0].blk = block.number;
        point_history[0].ts = block.timestamp;
        boostedPercent = [1000, 2000, 3000, 4000, 5000];
    }

    function setTokenAddress(address _token_addr) external onlyOwner {
        require(_token_addr != address(0), "zero");
        token = _token_addr;
    }

    function setOpxNFT(address _opxNFT) external onlyOwner {
        require(_opxNFT != address(0), "zero");
        opxNFT = _opxNFT;
    }

    function updateBoostedPercent(
        uint256[5] memory _boostedPercent
    ) external onlyOwner {
        boostedPercent = _boostedPercent;
    }

    function depositedNFT(address account) external view returns (uint256) {
        return _depositedNFT[account];
    }

    function getBoostedAmount(uint256 amount, uint256 _tokenId) external view returns (uint256) {
        uint256 _level = IOpxNFT(opxNFT).getTokenLevel(_tokenId);
        return amount + amount * boostedPercent[_level - 1] / 10000;
    }

    /// @notice Get the most recently recorded rate of voting power decrease for `_tokenId`
    /// @param _tokenId token of the NFT
    /// @return Value of the slope
    function get_last_user_slope(uint256 _tokenId) external view returns (int128) {
        uint256 uepoch = user_point_epoch[_tokenId];
        return user_point_history[_tokenId][uepoch].slope;
    }

    /// @notice Get the timestamp for checkpoint `_idx` for `_tokenId`
    /// @param _tokenId token of the NFT
    /// @param _idx User epoch number
    /// @return Epoch time of the checkpoint
    function user_point_history__ts(uint256 _tokenId, uint256 _idx) external view returns (uint256) {
        return user_point_history[_tokenId][_idx].ts;
    }

    /// @notice Get timestamp when `_tokenId`'s lock finishes
    /// @param _tokenId User NFT
    /// @return Epoch time of the lock end
    function locked__end(uint256 _tokenId) external view returns (uint256) {
        return locked[_tokenId].end;
    }


    function _isContract(address account) internal view returns (bool) {
        // This method relies on extcodesize, which returns 0 for contracts in
        // construction, since the code is only stored at the end of the
        // constructor execution.
        uint256 size;
        assembly {
            size := extcodesize(account)
        }
        return size > 0;
    }

    function estimatePower(uint256 _tokenId, uint256 _value, uint256 _lock_duration) external view returns (uint256) {
        uint256 unlock_time = (block.timestamp + _lock_duration) / WEEK * WEEK; // Locktime is rounded down to weeks

        LockedBalance memory _locked = locked[_tokenId];
        if (_locked.amount > 0) {
            if (_lock_duration > 0) {
                require(unlock_time > _locked.end, 'Can only increase lock duration');
                require(unlock_time <= block.timestamp + MAXTIME, 'Voting lock can be 42 weeks max');
            } else  unlock_time = _locked.end;
            require(_locked.end > block.timestamp, 'Cannot add to expired lock. Withdraw');
            int128 slope = (int128(int256(_value)) + _locked.amount) / iMAXTIME;
            int128 bias = slope * int128(int256(unlock_time - block.timestamp));

            bias -= slope * int128(int256(block.timestamp) - int256(block.timestamp));
            if (bias < 0) {
                bias = 0;
            }
            return this.getBoostedAmount(uint256(int256(bias)), _tokenId);
        } else {
            require(unlock_time > block.timestamp, 'Can only lock until time in the future');
            require(unlock_time <= block.timestamp + MAXTIME, 'Voting lock can be 42 weeks max');
            int128 slope = int128(int256(_value)) / iMAXTIME;
            int128 bias = slope * int128(int256(unlock_time - block.timestamp));

            bias -= slope * int128(int256(block.timestamp) - int256(block.timestamp));
            if (bias < 0) {
                bias = 0;
            }
            return this.getBoostedAmount(uint256(int256(bias)), _tokenId);
        }
    }



    /// @notice Record global and per-user data to checkpoint
    /// @param _tokenId NFT token ID. No user checkpoint if 0
    /// @param old_locked Pevious locked amount / end lock time for the user
    /// @param new_locked New locked amount / end lock time for the user
    function _checkpoint(
        uint256 _tokenId,
        LockedBalance memory old_locked,
        LockedBalance memory new_locked
    ) internal {
        Point memory u_old;
        Point memory u_new;
        int128 old_dslope = 0;
        int128 new_dslope = 0;
        uint256 _epoch = epoch;

        if (_tokenId != 0) {
            // Calculate slopes and biases
            // Kept at zero when they have to
            if (old_locked.end > block.timestamp && old_locked.amount > 0) {
                u_old.slope = old_locked.amount / iMAXTIME;
                u_old.bias = u_old.slope * int128(int256(old_locked.end - block.timestamp));
            }
            if (new_locked.end > block.timestamp && new_locked.amount > 0) {
                u_new.slope = new_locked.amount / iMAXTIME;
                u_new.bias = u_new.slope * int128(int256(new_locked.end - block.timestamp));
            }

            // Read values of scheduled changes in the slope
            // old_locked.end can be in the past and in the future
            // new_locked.end can ONLY by in the FUTURE unless everything expired: than zeros
            old_dslope = slope_changes[old_locked.end];
            if (new_locked.end != 0) {
                if (new_locked.end == old_locked.end) {
                    new_dslope = old_dslope;
                } else {
                    new_dslope = slope_changes[new_locked.end];
                }
            }
        }

        Point memory last_point = Point({bias: 0, slope: 0, ts: block.timestamp, blk: block.number});
        if (_epoch > 0) {
            last_point = point_history[_epoch];
        }
        uint256 last_checkpoint = last_point.ts;
        // initial_last_point is used for extrapolation to calculate block number
        // (approximately, for *At methods) and save them
        // as we cannot figure that out exactly from inside the contract
        Point memory initial_last_point = last_point;
        uint256 block_slope = 0; // dblock/dt
        if (block.timestamp > last_point.ts) {
            block_slope = (MULTIPLIER * (block.number - last_point.blk)) / (block.timestamp - last_point.ts);
        }
        // If last point is already recorded in this block, slope=0
        // But that's ok b/c we know the block in such case

        // Go over weeks to fill history and calculate what the current point is
        {
            uint256 t_i = (last_checkpoint / WEEK) * WEEK;
            for (uint256 i = 0; i < 255; ++i) {
                // Hopefully it won't happen that this won't get used in 5 years!
                // If it does, users will be able to withdraw but vote weight will be broken
                t_i += WEEK;
                int128 d_slope = 0;
                if (t_i > block.timestamp) {
                    t_i = block.timestamp;
                } else {
                    d_slope = slope_changes[t_i];
                }
                last_point.bias -= last_point.slope * int128(int256(t_i - last_checkpoint));
                last_point.slope += d_slope;
                if (last_point.bias < 0) {
                    // This can happen
                    last_point.bias = 0;
                }
                if (last_point.slope < 0) {
                    // This cannot happen - just in case
                    last_point.slope = 0;
                }
                last_checkpoint = t_i;
                last_point.ts = t_i;
                last_point.blk = initial_last_point.blk + (block_slope * (t_i - initial_last_point.ts)) / MULTIPLIER;
                _epoch += 1;
                if (t_i == block.timestamp) {
                    last_point.blk = block.number;
                    break;
                } else {
                    point_history[_epoch] = last_point;
                }
            }
        }

        epoch = _epoch;
        // Now point_history is filled until t=now

        if (_tokenId != 0) {
            // If last point was in this block, the slope change has been applied already
            // But in such case we have 0 slope(s)
            last_point.slope += (u_new.slope - u_old.slope);
            last_point.bias += (u_new.bias - u_old.bias);
            if (last_point.slope < 0) {
                last_point.slope = 0;
            }
            if (last_point.bias < 0) {
                last_point.bias = 0;
            }
        }

        // Record the changed point into history
        point_history[_epoch] = last_point;

        if (_tokenId != 0) {
            // Schedule the slope changes (slope is going down)
            // We subtract new_user_slope from [new_locked.end]
            // and add old_user_slope to [old_locked.end]
            if (old_locked.end > block.timestamp) {
                // old_dslope was <something> - u_old.slope, so we cancel that
                old_dslope += u_old.slope;
                if (new_locked.end == old_locked.end) {
                    old_dslope -= u_new.slope; // It was a new deposit, not extension
                }
                slope_changes[old_locked.end] = old_dslope;
            }

            if (new_locked.end > block.timestamp) {
                if (new_locked.end > old_locked.end) {
                    new_dslope -= u_new.slope; // old slope disappeared at this point
                    slope_changes[new_locked.end] = new_dslope;
                }
                // else: we recorded it already in old_dslope
            }
            // Now handle user history
            uint256 user_epoch = user_point_epoch[_tokenId] + 1;

            user_point_epoch[_tokenId] = user_epoch;
            u_new.ts = block.timestamp;
            u_new.blk = block.number;
            user_point_history[_tokenId][user_epoch] = u_new;
        }
    }

    /// @notice Deposit and lock tokens for a user
    /// @param _tokenId NFT that holds lock
    /// @param _value Amount to deposit
    /// @param unlock_time New time when to unlock the tokens, or 0 if unchanged
    /// @param locked_balance Previous locked amount / timestamp
    /// @param deposit_type The type of deposit
    function _deposit_for(
        uint256 _tokenId,
        uint256 _value,
        uint256 unlock_time,
        LockedBalance memory locked_balance,
        DepositType deposit_type
    ) internal {
        require(_value == 0 || _value >= minLockedAmount, "less than min amount");

        LockedBalance memory _locked = locked_balance;
        uint256 supply_before = supply;

        supply = supply_before + _value;
        LockedBalance memory old_locked;
        (old_locked.amount, old_locked.end) = (_locked.amount, _locked.end);
        // Adding to existing lock, or if a lock is expired - creating a new one
        _locked.amount += int128(int256(_value));
        if (unlock_time != 0) {
            _locked.end = unlock_time;
        }
        locked[_tokenId] = _locked;

        // Possibilities:
        // Both old_locked.end could be current or expired (>/< block.timestamp)
        // value == 0 (extend lock) or value > 0 (add to lock or extend lock)
        // _locked.end > block.timestamp (always)
        _checkpoint(_tokenId, old_locked, _locked);

        address from = msg.sender;
        if (_value != 0 && deposit_type != DepositType.MERGE_TYPE) {
            assert(IERC20(token).transferFrom(from, address(this), _value));
        }

        emit Deposit(from, _tokenId, _value, _locked.end, deposit_type, block.timestamp);
        emit Supply(supply_before, supply_before + _value);

        uint256 _length = listeners.length;
        for (uint256 i = 0; i < _length; i++) {
            IveListener(listeners[i]).onTokenWeightUpdated(_tokenId);
        }
    }

    function setMinLockedAmount(uint256 _minLockedAmount) external onlyOwner {
        minLockedAmount = _minLockedAmount;
    }

    function setEarlyWithdrawFeeRate(uint256 _earlyWithdrawFeeRate) external onlyOwner {
        require(_earlyWithdrawFeeRate <= 10000, "too high"); // <= 100%
        earlyWithdrawFeeRate = _earlyWithdrawFeeRate;
    }

    function setVoter(address _voter) external onlyOwner {
        voter = _voter;
    }

    function setBoardroom(address _boardroom) external onlyOwner {
        boardroom = _boardroom;
    }

    function addListener(address _listener) external onlyOwner {
        listeners.push(_listener);
    }

    function setListeners(address[] calldata _listeners) external onlyOwner {
        delete listeners;
        uint256 _length = _listeners.length;
        for (uint256 i = 0; i < _length; i++) {
            listeners.push(_listeners[i]);
        }
    }

    function voting(uint256 _tokenId) external onlyVoter {
        voted[_tokenId] = true;
    }

    function abstain(uint256 _tokenId) external onlyVoter {
        voted[_tokenId] = false;
    }

    function attach(uint256 _tokenId) external onlyVoter {
        attachments[_tokenId] = attachments[_tokenId]+1;
    }

    function detach(uint256 _tokenId) external onlyVoter {
        attachments[_tokenId] = attachments[_tokenId]-1;
    }

    /*
    function merge(uint256 _from, uint256 _to) external {
        require(attachments[_from] == 0 && !voted[_from], "attached");
        require(_from != _to);
        require(_isApprovedOrOwner(msg.sender, _from));
        require(_isApprovedOrOwner(msg.sender, _to));

        LockedBalance memory _locked0 = locked[_from];
        LockedBalance memory _locked1 = locked[_to];
        uint256 value0 = uint256(int256(_locked0.amount));
        uint256 end = _locked0.end >= _locked1.end ? _locked0.end : _locked1.end;

        locked[_from] = LockedBalance(0, 0);
        _checkpoint(_from, _locked0, LockedBalance(0, 0));
        _burn(_from);
        _deposit_for(_to, value0, end, _locked1, DepositType.MERGE_TYPE);
    }
    */

    function block_number() external view returns (uint256) {
        return block.number;
    }

    /// @notice Record global data to checkpoint
    function checkpoint() external {
        _checkpoint(0, LockedBalance(0, 0), LockedBalance(0, 0));
    }

    /// @notice Deposit `_value` tokens for `_tokenId` and add to the lock
    /// @dev Anyone (even a smart contract) can deposit for someone else, but
    ///      cannot extend their locktime and deposit for a brand new user
    /// @param _tokenId lock NFT
    /// @param _value Amount to add to user's lock
    function deposit_for(uint256 _tokenId, uint256 _value) external nonReentrant {
        require(_depositedNFT[msg.sender] != 0, "stake first");
        LockedBalance memory _locked = locked[_tokenId];

        require(_value > 0); // dev: need non-zero value
        require(_locked.amount > 0, 'No existing lock found');
        require(_locked.end > block.timestamp, 'Cannot add to expired lock. Withdraw');
        _deposit_for(_tokenId, _value, 0, _locked, DepositType.DEPOSIT_FOR_TYPE);
    }

    /// @notice Deposit `_value` tokens for `_to` and lock for `_lock_duration`
    /// @param _value Amount to deposit
    /// @param _lock_duration Number of seconds to lock tokens for (rounded down to nearest week)
    /// @param _to Address to deposit
    function _create_lock(uint256 _tokenId, uint256 _value, uint256 _lock_duration, address _to) internal returns (uint256) {
        uint256 unlock_time = (block.timestamp + _lock_duration) / WEEK * WEEK; // Locktime is rounded down to weeks

        require(_value > 0); // dev: need non-zero value
        require(unlock_time > block.timestamp, 'Can only lock until time in the future');
        require(unlock_time <= block.timestamp + MAXTIME, 'Voting lock can be 42 weeks max');
        require(IERC721(opxNFT).ownerOf(_tokenId) == _to, "user does not have specified NFT");
        require(_depositedNFT[_to] == 0, "unstake first");

        IERC721(opxNFT).transferFrom(_to, address(this), _tokenId);
        _depositedNFT[_to] = _tokenId;
        totalDepositedNFT++;
        _deposit_for(_tokenId, _value, unlock_time, locked[_tokenId], DepositType.CREATE_LOCK_TYPE);
        return _tokenId;
    }

    /// @notice Deposit `_value` tokens for `_to` and lock for `_lock_duration`
    /// @param _value Amount to deposit
    /// @param _lock_duration Number of seconds to lock tokens for (rounded down to nearest week)
    /// @param _to Address to deposit
    function create_lock_for(uint256 _tokenId, uint256 _value, uint256 _lock_duration, address _to) external nonReentrant returns (uint256) {
        return _create_lock(_tokenId, _value, _lock_duration, _to);
    }

    /// @notice Deposit `_value` tokens for `msg.sender` and lock for `_lock_duration`
    /// @param _value Amount to deposit
    /// @param _lock_duration Number of seconds to lock tokens for (rounded down to nearest week)
    function create_lock(uint256 _tokenId, uint256 _value, uint256 _lock_duration) external nonReentrant returns (uint256) {
        return _create_lock(_tokenId, _value, _lock_duration, msg.sender);
    }

    /// @notice Deposit `_value` additional tokens for `_tokenId` without modifying the unlock time
    /// @param _value Amount of tokens to deposit and add to the lock
    function increase_amount(uint256 _tokenId, uint256 _value) external nonReentrant {
        require(_depositedNFT[msg.sender] == _tokenId, "caller is not owner");

        LockedBalance memory _locked = locked[_tokenId];

        assert(_value > 0); // dev: need non-zero value
        require(_locked.amount > 0, 'No existing lock found');
        require(_locked.end > block.timestamp, 'Cannot add to expired lock. Withdraw');

        _deposit_for(_tokenId, _value, 0, _locked, DepositType.INCREASE_LOCK_AMOUNT);
    }

    /// @notice Extend the unlock time for `_tokenId`
    /// @param _lock_duration New number of seconds until tokens unlock
    function increase_unlock_time(uint256 _tokenId, uint256 _lock_duration) external nonReentrant {
        require(_depositedNFT[msg.sender] == _tokenId, "caller is not owner");

        LockedBalance memory _locked = locked[_tokenId];
        uint256 unlock_time = (block.timestamp + _lock_duration) / WEEK * WEEK; // Locktime is rounded down to weeks

        require(_locked.end > block.timestamp, 'Lock expired');
        require(_locked.amount > 0, 'Nothing is locked');
        require(unlock_time > _locked.end, 'Can only increase lock duration');
        require(unlock_time <= block.timestamp + MAXTIME, 'Voting lock can be 42 weeks max');

        _deposit_for(_tokenId, 0, unlock_time, _locked, DepositType.INCREASE_UNLOCK_TIME);
    }

    /// @notice Extend the unlock time for `_tokenId`
    /// @param _lock_duration New number of seconds until tokens unlock
    function increase_lock_both(uint256 _tokenId, uint256 _value, uint256 _lock_duration) external nonReentrant {
        require(_depositedNFT[msg.sender] == _tokenId, "caller is not owner");

        LockedBalance memory _locked = locked[_tokenId];
        uint256 unlock_time = (block.timestamp + _lock_duration) / WEEK * WEEK; // Locktime is rounded down to weeks

        assert(_value > 0); // dev: need non-zero value
        require(_locked.end > block.timestamp, 'Lock expired');
        require(_locked.amount > 0, 'Nothing is locked');
        require(unlock_time > _locked.end, 'Can only increase lock duration');
        require(unlock_time <= block.timestamp + MAXTIME, 'Voting lock can be 42 weeks max');

        _deposit_for(_tokenId, _value, unlock_time, _locked, DepositType.INCREASE_LOCK_AMOUNT);
    }


    /// @notice Withdraw all tokens for `_tokenId`
    /// @dev Only possible if the lock has expired
    function withdraw(uint256 _tokenId) external nonReentrant {
        _withdraw(_tokenId, false);
    }

    // This will charge PENALTY if lock is not expired yet
    function emergencyWithdraw(uint256 _tokenId) external nonReentrant {
        _withdraw(_tokenId, true);
    }

    function _withdraw(uint256 _tokenId, bool _isEmergency) internal {
        require(_depositedNFT[msg.sender] == _tokenId, "caller is not owner");
        IVoter(voter).onTokenWeightReset(_tokenId);
        require(attachments[_tokenId] == 0 && !voted[_tokenId], "attached");

        LockedBalance memory _locked = locked[_tokenId];
        require(_isEmergency || block.timestamp >= _locked.end, "lock not expired");
        uint256 value = uint256(int256(_locked.amount));

        locked[_tokenId] = LockedBalance(0,0);
        uint256 supply_before = supply;
        supply = supply_before - value;

        // old_locked can have either expired <= timestamp or zero end
        // _locked has only 0 end
        // Both can have >= 0 amount
        _checkpoint(_tokenId, _locked, LockedBalance(0,0));

        if (_isEmergency) {
            uint256 _fee = value * earlyWithdrawFeeRate / 10000;
            ICappedMintableBurnableERC20(token).burn(_fee);
            assert(IERC20(token).transfer(msg.sender, value - _fee));
        } else {
            assert(IERC20(token).transfer(msg.sender, value));
        }

        IveOpxRoom(boardroom).onTokenExit(_tokenId);

        uint256 _length = listeners.length;
        for (uint256 i = 0; i < _length; i++) {
            IveListener(listeners[i]).onTokenWeightUpdated(_tokenId);
        }

        IERC721(opxNFT).transferFrom(address(this), msg.sender, _tokenId);
        _depositedNFT[msg.sender] = 0;
        totalDepositedNFT--;

        emit Withdraw(msg.sender, _tokenId, value, block.timestamp);
        emit Supply(supply_before, supply_before - value);
    }

    // The following ERC20/minime-compatible methods are not real balanceOf and supply!
    // They measure the weights for the purpose of voting, so they don't represent
    // real coins.

    /// @notice Binary search to estimate timestamp for block number
    /// @param _block Block to find
    /// @param max_epoch Don't go beyond this epoch
    /// @return Approximate timestamp for block
    function _find_block_epoch(uint256 _block, uint256 max_epoch) internal view returns (uint256) {
        // Binary search
        uint256 _min = 0;
        uint256 _max = max_epoch;
        for (uint256 i = 0; i < 128; ++i) {
            // Will be always enough for 128-bit numbers
            if (_min >= _max) {
                break;
            }
            uint256 _mid = (_min + _max + 1) / 2;
            if (point_history[_mid].blk <= _block) {
                _min = _mid;
            } else {
                _max = _mid - 1;
            }
        }
        return _min;
    }

    /// @notice Get the current voting power for `_tokenId`
    /// @dev Adheres to the ERC20 `balanceOf` interface for Aragon compatibility
    /// @param _tokenId NFT for lock
    /// @param _t Epoch time to return voting power at
    /// @return User voting power
    function _balanceOfNFT(uint256 _tokenId, uint256 _t) internal view returns (uint256) {
        uint256 _epoch = user_point_epoch[_tokenId];
        if (_epoch == 0) {
            return 0;
        } else {
            Point memory last_point = user_point_history[_tokenId][_epoch];
            last_point.bias -= last_point.slope * int128(int256(_t) - int256(last_point.ts));
            if (last_point.bias < 0) {
                last_point.bias = 0;
            }
            return this.getBoostedAmount(uint256(int256(last_point.bias)), _tokenId);
        }
    }

    function balanceOfNFT(uint256 _tokenId) external view returns (uint256) {
        if (ownership_change[_tokenId] == block.number) return 0;
        return _balanceOfNFT(_tokenId, block.timestamp);
    }

    function balanceOfNFTAt(uint256 _tokenId, uint256 _t) external view returns (uint256) {
        return _balanceOfNFT(_tokenId, _t);
    }

    /// @notice Measure voting power of `_tokenId` at block height `_block`
    /// @dev Adheres to MiniMe `balanceOfAt` interface: https://github.com/Giveth/minime
    /// @param _tokenId User's wallet NFT
    /// @param _block Block to calculate the voting power at
    /// @return Voting power
    function _balanceOfAtNFT(uint256 _tokenId, uint256 _block) internal view returns (uint256) {
        // Copying and pasting totalSupply code because Vyper cannot pass by
        // reference yet
        assert(_block <= block.number);

        // Binary search
        uint256 _min = 0;
        uint256 _max = user_point_epoch[_tokenId];
        for (uint256 i = 0; i < 128; ++i) {
            // Will be always enough for 128-bit numbers
            if (_min >= _max) {
                break;
            }
            uint256 _mid = (_min + _max + 1) / 2;
            if (user_point_history[_tokenId][_mid].blk <= _block) {
                _min = _mid;
            } else {
                _max = _mid - 1;
            }
        }

        Point memory upoint = user_point_history[_tokenId][_min];

        uint256 max_epoch = epoch;
        uint256 _epoch = _find_block_epoch(_block, max_epoch);
        Point memory point_0 = point_history[_epoch];
        uint256 d_block = 0;
        uint256 d_t = 0;
        if (_epoch < max_epoch) {
            Point memory point_1 = point_history[_epoch + 1];
            d_block = point_1.blk - point_0.blk;
            d_t = point_1.ts - point_0.ts;
        } else {
            d_block = block.number - point_0.blk;
            d_t = block.timestamp - point_0.ts;
        }
        uint256 block_time = point_0.ts;
        if (d_block != 0) {
            block_time += (d_t * (_block - point_0.blk)) / d_block;
        }

        upoint.bias -= upoint.slope * int128(int256(block_time - upoint.ts));
        if (upoint.bias >= 0) {
            return uint256(uint128(upoint.bias));
        } else {
            return 0;
        }
    }

    function balanceOfAtNFT(uint256 _tokenId, uint256 _block) external view returns (uint256) {
        return _balanceOfAtNFT(_tokenId, _block);
    }

    /// @notice Calculate total voting power at some point in the past
    /// @param point The point (bias/slope) to start search from
    /// @param t Time to calculate the total voting power at
    /// @return Total voting power at that time
    function _supply_at(Point memory point, uint256 t) internal view returns (uint256) {
        Point memory last_point = point;
        uint256 t_i = (last_point.ts / WEEK) * WEEK;
        for (uint256 i = 0; i < 255; ++i) {
            t_i += WEEK;
            int128 d_slope = 0;
            if (t_i > t) {
                t_i = t;
            } else {
                d_slope = slope_changes[t_i];
            }
            last_point.bias -= last_point.slope * int128(int256(t_i - last_point.ts));
            if (t_i == t) {
                break;
            }
            last_point.slope += d_slope;
            last_point.ts = t_i;
        }

        if (last_point.bias < 0) {
            last_point.bias = 0;
        }
        return uint256(uint128(last_point.bias));
    }

    /// @notice Calculate total voting power
    /// @dev Adheres to the ERC20 `totalSupply` interface for Aragon compatibility
    /// @return Total voting power
    function totalSupplyAtT(uint256 t) public view returns (uint256) {
        uint256 _epoch = epoch;
        Point memory last_point = point_history[_epoch];
        return _supply_at(last_point, t);
    }

    function totalSupply() external view returns (uint256) {
        return totalSupplyAtT(block.timestamp);
    }

    /// @notice Calculate total voting power at some point in the past
    /// @param _block Block to calculate the total voting power at
    /// @return Total voting power at `_block`
    function totalSupplyAt(uint256 _block) external view returns (uint256) {
        assert(_block <= block.number);
        uint256 _epoch = epoch;
        uint256 target_epoch = _find_block_epoch(_block, _epoch);

        Point memory point = point_history[target_epoch];
        uint256 dt = 0;
        if (target_epoch < _epoch) {
            Point memory point_next = point_history[target_epoch + 1];
            if (point.blk != point_next.blk) {
                dt = ((_block - point.blk) * (point_next.ts - point.ts)) / (point_next.blk - point.blk);
            }
        } else {
            if (point.blk != block.number) {
                dt = ((_block - point.blk) * (block.timestamp - point.ts)) / (block.number - point.blk);
            }
        }
        // Now dt contains info on how far are we beyond point
        return _supply_at(point, point.ts + dt);
    }



    /* ========== EMERGENCY ========== */

    function governanceRecoverUnsupported(IERC20 _token) external onlyOwner {
        _token.transfer(owner(), _token.balanceOf(address(this)));
    }
}
