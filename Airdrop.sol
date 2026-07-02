// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {Ownable2Step, Ownable} from "@openzeppelin/contracts/access/Ownable2Step.sol";

/// @title Airdrop
/// @notice Simple owner-managed ERC20 airdrop contract.
/// @dev Tokens are pulled from `msg.sender` via `transferFrom`. Token address is provided per call.
contract Airdrop is Ownable2Step {
    using SafeERC20 for IERC20;

    /// @notice Thrown when a required address argument is zero.
    error ZeroAddress();
    /// @notice Thrown when amount argument is zero.
    error InvalidAmount();
    /// @notice Thrown when recipients and amounts arrays have different lengths.
    error LengthMismatch();
    /// @notice Thrown when recipients list is empty.
    error EmptyRecipients();

    /// @notice Emitted when a single-recipient airdrop is executed.
    /// @param token ERC20 token used for distribution.
    /// @param recipient Recipient address.
    /// @param amount Amount distributed.
    event Airdropped(address indexed token, address indexed recipient, uint256 amount);

    /// @notice Emitted when a batch airdrop is executed.
    /// @param token ERC20 token used for distribution.
    /// @param recipients Number of recipients processed.
    /// @param totalAmount Total amount distributed in the batch.
    event BatchAirdropped(address indexed token, uint256 recipients, uint256 totalAmount);

    /// @notice Deploys the airdrop contract.
    constructor() Ownable(msg.sender) {}

    /// @notice Distributes tokens to a single recipient.
    /// @dev Caller must approve this contract for `amount` beforehand.
    /// @param token ERC20 token to distribute.
    /// @param recipient Address receiving tokens.
    /// @param amount Amount to distribute.
    function airdrop(address token, address recipient, uint256 amount) external onlyOwner {
        if (token == address(0)) revert ZeroAddress();
        if (recipient == address(0)) revert ZeroAddress();
        if (amount == 0) revert InvalidAmount();

        IERC20(token).safeTransferFrom(msg.sender, recipient, amount);
        emit Airdropped(token, recipient, amount);
    }

    /// @notice Distributes tokens to multiple recipients.
    /// @dev `recipients[i]` receives `amounts[i]`. Caller must approve this contract for the total amount.
    /// @param token ERC20 token to distribute.
    /// @param recipients Recipient addresses.
    /// @param amounts Token amounts for each recipient.
    function batchAirdrop(
        address token,
        address[] calldata recipients,
        uint256[] calldata amounts
    ) external onlyOwner {
        if (token == address(0)) revert ZeroAddress();
        if (recipients.length == 0) revert EmptyRecipients();
        if (recipients.length != amounts.length) revert LengthMismatch();

        uint256 totalAmount;
        for (uint256 i = 0; i < recipients.length; i++) {
            address recipient = recipients[i];
            uint256 amount = amounts[i];

            if (recipient == address(0)) revert ZeroAddress();
            if (amount == 0) revert InvalidAmount();

            totalAmount += amount;
            IERC20(token).safeTransferFrom(msg.sender, recipient, amount);
            emit Airdropped(token, recipient, amount);
        }

        emit BatchAirdropped(token, recipients.length, totalAmount);
    }
}
