// SPDX-License-Identifier: AGPL-3.0-or-later
pragma solidity =0.8.8; 

import "@openzeppelin/contracts/token/ERC20/ERC20.sol";

contract mock is ERC20 { 

    constructor() ERC20("Manifold", "FOLD") { }

    function mint(uint amount) external {
        _mint(_msgSender(), amount);
    }

}