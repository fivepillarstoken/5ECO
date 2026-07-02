// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {ERC20Burnable, ERC20} from "@openzeppelin/contracts/token/ERC20/extensions/ERC20Burnable.sol";

/// @title FiveECO
/// @notice ERC20 token with supply minted at deployment and burnable.
contract FiveECO is ERC20Burnable {
    /// @notice Thrown when constructor addresses are invalid (zero address).
    error ZeroAddress();

    /// @notice Creates the ERC20 and performs initial allocation.
    /// @dev Mints full supply at deployment:
    ///      - 17,000,000 to `miningEmissionContract` for emissions,
    ///      - 750,000 to `liquidityWallet`,
    ///      - 250,000 to `treasuryWallet`,
    ///      - 1,000,000 to `teamWallet`,
    ///      - 1,000,000 to `rankingWallet`,
    ///      - 1,000,000 to `marketingWallet`.
    /// @param miningEmissionContract Address of `MiningEmission` contract receiving emission allocation.
    /// @param liquidityWallet Address receiving liquidity allocation.
    /// @param treasuryWallet Address receiving treasury allocation.
    /// @param teamWallet Address receiving team allocation.
    /// @param rankingWallet Address receiving ranking allocation.
    /// @param marketingWallet Address receiving marketing allocation.
    constructor(
        address miningEmissionContract,
        address liquidityWallet,
        address treasuryWallet,
        address teamWallet,
        address rankingWallet,
        address marketingWallet
    ) ERC20("5ECO", "5ECO") {
        if (
            address(miningEmissionContract) == address(0) ||
            address(liquidityWallet) == address(0) ||
            address(treasuryWallet) == address(0) ||
            address(teamWallet) == address(0) ||
            address(rankingWallet) == address(0) ||
            address(marketingWallet) == address(0)
        ) revert ZeroAddress();

        _mint(miningEmissionContract, 17_000_000 * 10 ** decimals());
        _mint(liquidityWallet, 750_000 * 10 ** decimals());
        _mint(treasuryWallet, 250_000 * 10 ** decimals());
        _mint(teamWallet, 1_000_000 * 10 ** decimals());
        _mint(rankingWallet, 1_000_000 * 10 ** decimals());
        _mint(marketingWallet, 1_000_000 * 10 ** decimals());
    }
}
