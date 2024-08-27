/// SPDX-License-Identifier: SSPL-1.-0
pragma solidity ^0.8.26;

import {ERC20} from "lib/solmate/src/tokens/ERC20.sol";

contract MockERC20 is ERC20("Manifold Finance", "FOLD", 18) {
    function mint(address recipient, uint256 amount) public {
        _mint(recipient, amount);
    }

    function burn(address recipient, uint256 amount) public {
        _burn(recipient, amount);
    }
}
