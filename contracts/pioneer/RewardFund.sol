// SPDX-License-Identifier: MIT

pragma solidity 0.6.12;

import "../access/Governable.sol";
import "../libraries/token/IERC20.sol";

contract RewardFund is Governable {
    function approve(
        address _token,
        address _spender,
        uint256 _amount
    ) external onlyGov {
        IERC20(_token).approve(_spender, _amount);
    }

    function transfer(
        address _token,
        address payable _recipient,
        uint256 _amount
    ) external onlyGov {
        if (_token == address(0)) {
            _recipient.transfer(_amount);
        } else {
            IERC20(_token).transfer(_recipient, _amount);
        }
    }

}
