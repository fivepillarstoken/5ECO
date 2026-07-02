// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

/// @title IERC20Burnable
/// @notice ERC-20 extended with a `burn` entrypoint. `FiveECO` is ERC20Burnable, so `FounderPackages`
///         can burn the unreleased 5ECO of a terminated vesting schedule via `burnWithdrawSchedule`.
interface IERC20Burnable is IERC20 {
    /// @notice Destroys `amount` tokens from the caller, reducing total supply.
    /// @param amount The amount of tokens to burn.
    function burn(uint256 amount) external;
}
