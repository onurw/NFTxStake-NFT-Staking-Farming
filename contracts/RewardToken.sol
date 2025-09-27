// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "@openzeppelin/contracts/token/ERC20/extensions/ERC20Votes.sol";

contract RewardToken is ERC20Votes {
    constructor() ERC20("NFTx Reward", "NXR") ERC20Permit("NFTx Reward") {
        _mint(msg.sender, 10_000_000 ether);
    }

    function _update(address from, address to, uint256 value)
        internal
        override(ERC20, ERC20Votes)
    {
        super._update(from, to, value);
    }
}
