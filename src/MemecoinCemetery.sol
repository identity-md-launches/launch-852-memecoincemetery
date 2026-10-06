// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

/// @notice The ERC-20 reads used to validate tokens and a holder's objection.
interface ICemeteryToken {
    /// @notice Returns the current supply in the token's smallest units.
    /// @return supply The current total supply.
    function totalSupply() external view returns (uint256 supply);

    /// @notice Returns an account's current balance in the token's smallest units.
    /// @param account The account to query.
    /// @return balance The account's balance.
    function balanceOf(address account) external view returns (uint256 balance);
}

/// @title Memecoin Cemetery
/// @notice Records permanent graves for tokens after a 30-day wake without a qualifying objection.
/// @dev No fees, token transfers, owner, upgrades or payable entry points. Eligibility trusts the
/// token's current reported supply and balance; no holding period or balance snapshot is required.
contract MemecoinCemetery {
    /// @notice A token has no record, an unsealed wake, or a permanent grave.
    enum State {
        None,
        Wake,
        Buried
    }

    /// @dev A wake retains its state until explicitly cancelled or sealed.
    struct Grave {
        /// @dev The record's lifecycle state.
        State state;
        /// @dev The account that opened the wake.
        address digger;
        /// @dev The original epitaph, at most 140 bytes.
        string epitaph;
        /// @dev Wake end time while in Wake; sealing time while Buried.
        uint256 timestamp;
    }

    /// @dev The interval during which qualifying holders can object.
    uint256 private constant WAKE_DURATION = 30 days;
    /// @dev The delay from a successful objection until another wake can open.
    uint256 private constant REDIG_COOLDOWN = 30 days;
    /// @dev Epitaph length is measured in bytes, not Unicode characters.
    uint256 private constant MAX_EPITAPH_BYTES = 140;

    /// @dev One wake or permanent grave per token address.
    mapping(address token => Grave grave) private _graves;
    /// @dev Earliest next dig after an objection; independent of the deleted wake.
    mapping(address token => uint256 timestamp) private _digAfter;

    /// @notice The number of permanently sealed graves; excludes wakes and cancelled burials.
    uint256 public graveCount;

    /// @notice A wake was opened.
    /// @param token The token being considered for burial.
    /// @param digger The account that opened the wake.
    /// @param epitaph The proposed epitaph.
    /// @param endsAt The first timestamp at which the grave can be sealed.
    event WakeOpened(address indexed token, address indexed digger, string epitaph, uint256 endsAt);

    /// @notice A qualifying holder cancelled a wake and started the re-dig cooldown.
    /// @param token The token whose wake was cancelled.
    /// @param holder The account that successfully objected.
    event Resurrected(address indexed token, address indexed holder);

    /// @notice A grave was permanently sealed.
    /// @param token The buried token.
    /// @param epitaph The epitaph recorded when the wake opened.
    /// @param digger The account that originally opened the wake.
    /// @param sealedAt The timestamp of sealing.
    event Buried(address indexed token, string epitaph, address indexed digger, uint256 sealedAt);

    /// @notice The token address has no deployed code.
    error InvalidToken();
    /// @notice A token's totalSupply or balanceOf call reverted.
    error TokenReadFailed();
    /// @notice The epitaph exceeds 140 bytes.
    error EpitaphTooLong();
    /// @notice The token already has a wake or permanent grave.
    error GraveAlreadyExists();
    /// @notice Thirty days have not elapsed since the last successful objection.
    error CooldownActive();
    /// @notice The token has no unsealed wake.
    error NotInWake();
    /// @notice The objection window has closed.
    error WakeEnded();
    /// @notice The objection window is still open.
    error WakeNotEnded();
    /// @notice The caller is not a holder of at least 0.1% of a nonzero supply.
    error InsufficientBalance();

    /// @notice Opens a 30-day wake for a token; anyone may dig without holding it.
    /// @dev Validates both ERC-20 reads using the digger's balance. A zero supply is allowed.
    /// Re-digging is allowed exactly 30 days after cancellation; sealed graves cannot be reopened.
    /// @param token The ERC-20 token address.
    /// @param epitaph The epitaph, up to 140 bytes (an empty epitaph is allowed).
    function dig(address token, string calldata epitaph) external {
        if (bytes(epitaph).length > MAX_EPITAPH_BYTES) revert EpitaphTooLong();
        if (_graves[token].state != State.None) revert GraveAlreadyExists();
        if (block.timestamp < _digAfter[token]) revert CooldownActive();
        if (token.code.length == 0) revert InvalidToken();

        _readToken(token, msg.sender);

        uint256 endsAt = block.timestamp + WAKE_DURATION;
        _graves[token] = Grave({state: State.Wake, digger: msg.sender, epitaph: epitaph, timestamp: endsAt});
        emit WakeOpened(token, msg.sender, epitaph, endsAt);
    }

    /// @notice Cancels a wake if the caller currently holds at least 0.1% of the token's supply.
    /// @dev Requires a nonzero supply and rounds the minimum balance up to a whole token unit.
    /// Objections are allowed strictly before endsAt. Cancellation clears the record and starts
    /// a fresh 30-day cooldown for this token, regardless of who next calls dig.
    /// @param token The token whose burial the caller objects to.
    function itLives(address token) external {
        Grave storage grave = _graves[token];
        if (grave.state != State.Wake) revert NotInWake();
        if (block.timestamp >= grave.timestamp) revert WakeEnded();

        (uint256 supply, uint256 balance) = _readToken(token, msg.sender);
        // ceil(supply / 1000) enforces 0.1% without overflowing at uint256's maximum.
        uint256 minimumBalance = supply / 1000 + (supply % 1000 == 0 ? 0 : 1);
        if (supply == 0 || balance < minimumBalance) revert InsufficientBalance();

        delete _graves[token];
        _digAfter[token] = block.timestamp + REDIG_COOLDOWN;
        emit Resurrected(token, msg.sender);
    }

    /// @notice Permanently seals an unopposed grave; anyone may seal at or after the wake ends.
    /// @dev Does not call the token, so token failures after dig cannot prevent sealing.
    /// A buried record can never transition to another state, and is counted exactly once.
    /// @param token The token whose completed wake should be sealed.
    function seal(address token) external {
        Grave storage grave = _graves[token];
        if (grave.state != State.Wake) revert NotInWake();
        if (block.timestamp < grave.timestamp) revert WakeNotEnded();

        grave.state = State.Buried;
        grave.timestamp = block.timestamp;
        ++graveCount;
        emit Buried(token, grave.epitaph, grave.digger, block.timestamp);
    }

    /// @notice Returns the current wake or grave for a token.
    /// @param token The token to look up.
    /// @return state None, Wake or Buried; an expired wake remains Wake until sealed.
    /// @return digger The original digger, or address(0) when state is None.
    /// @return epitaph The original epitaph, or an empty string when state is None.
    /// @return timestamp The wake's endsAt, the grave's sealedAt, or zero when state is None.
    function graveOf(address token)
        external
        view
        returns (State state, address digger, string memory epitaph, uint256 timestamp)
    {
        Grave storage grave = _graves[token];
        return (grave.state, grave.digger, grave.epitaph, grave.timestamp);
    }

    /// @dev View calls use STATICCALL, preventing token callbacks from mutating cemetery state.
    /// Reverting calls are caught; malformed ABI return data also rejects the entire operation.
    /// @param token The token to query.
    /// @param holder The account whose balance is queried.
    /// @return supply The token's current total supply.
    /// @return balance The holder's current balance.
    function _readToken(address token, address holder) private view returns (uint256 supply, uint256 balance) {
        try ICemeteryToken(token).totalSupply() returns (uint256 currentSupply) {
            supply = currentSupply;
        } catch {
            revert TokenReadFailed();
        }
        try ICemeteryToken(token).balanceOf(holder) returns (uint256 currentBalance) {
            balance = currentBalance;
        } catch {
            revert TokenReadFailed();
        }
    }
}
