// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "@openzeppelin/contracts/token/ERC20/ERC20.sol";

/**
 * @title MockERC20
 * @notice 测试用 ERC20 代币，可自由 mint。
 */
contract MockERC20 is ERC20 {
    uint8 private _decimals;

    constructor(uint8 decimals_) ERC20("Mock Token", "MOCK") {
        _decimals = decimals_;
    }

    function decimals() public view override returns (uint8) {
        return _decimals;
    }

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }
}
