// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {MemecoinCemetery, ICemeteryToken} from "src/MemecoinCemetery.sol";

/// @notice The Foundry cheatcodes used here, kept local so this suite needs no downloaded libraries.
interface CemeteryVm {
    /// @notice Sets the timestamp for subsequent calls.
    function warp(uint256 timestamp) external;
    /// @notice Reads the current timestamp without compiler caching across a warp.
    function getBlockTimestamp() external view returns (uint256);
    /// @notice Sets the sender of the next non-cheatcode call.
    function prank(address sender) external;
    /// @notice Expects the next call to revert with any data, including malformed ABI failures.
    function expectRevert() external;
    /// @notice Expects the next call to revert with the specified custom error.
    function expectRevert(bytes4 selector) external;
    /// @notice Checks the selected event topics, event data, and emitting contract.
    function expectEmit(bool topic1, bool topic2, bool topic3, bool data, address emitter) external;
    /// @notice Sets an account's ETH balance for payable-call rejection tests.
    function deal(address account, uint256 balance) external;
}

/// @notice Controllable ERC-20 read mock, including reverting and malformed return data.
/// @dev Explicit reported values allow testing arithmetic at uint256 limits without minting overflow.
contract CemeteryTokenMock is ICemeteryToken {
    /// @dev Supply returned to the cemetery.
    uint256 private _supply;
    /// @dev Balances returned to the cemetery.
    mapping(address => uint256) private _balances;
    /// @dev Zero means normal, one reverts, two returns nothing, and three returns 31 bytes.
    uint8 private _supplyMode;
    /// @dev The same read modes, independently applied to balanceOf.
    uint8 private _balanceMode;

    /// @notice Initializes the reported supply; all balances initially equal zero.
    constructor(uint256 supply) {
        _supply = supply;
    }

    /// @notice Changes the live reported supply without changing any balance.
    function setSupply(uint256 supply) external {
        _supply = supply;
    }

    /// @notice Changes an account's live reported balance without changing supply.
    function setBalance(address account, uint256 balance) external {
        _balances[account] = balance;
    }

    /// @notice Selects independent failure modes for the two ERC-20 reads.
    function setReadModes(uint8 supplyMode, uint8 balanceMode) external {
        _supplyMode = supplyMode;
        _balanceMode = balanceMode;
    }

    /// @notice Returns the configured supply or exercises the configured failure.
    function totalSupply() external view returns (uint256) {
        _checkRead(_supplyMode);
        return _supply;
    }

    /// @notice Returns the queried account's balance or exercises the configured failure.
    function balanceOf(address account) external view returns (uint256) {
        _checkRead(_balanceMode);
        return _balances[account];
    }

    /// @dev Returns deliberately invalid ABI data from the enclosing external call for modes 2 and 3.
    function _checkRead(uint8 mode) private pure {
        require(mode != 1, "mock read reverted");
        if (mode == 2) {
            assembly ("memory-safe") {
                return(0, 0)
            }
        }
        if (mode == 3) {
            assembly ("memory-safe") {
                return(0, 31)
            }
        }
    }
}

/// @notice A token that attempts a state-changing callback from its balanceOf implementation.
contract CemeteryCallbackToken {
    /// @dev Cemetery whose STATICCALL boundary is under test.
    MemecoinCemetery private immutable _cemetery;
    /// @dev An expired wake that could otherwise be sealed successfully.
    address private immutable _victim;

    /// @notice Selects a cemetery and an already sealable wake for the callback.
    constructor(MemecoinCemetery cemetery, address victim) {
        _cemetery = cemetery;
        _victim = victim;
    }

    /// @notice Reports a supply of 1,000 base units.
    function totalSupply() external pure returns (uint256) {
        return 1000;
    }

    /// @notice Attempts to seal another token and returns a qualifying balance if blocked.
    /// @dev Intentionally non-view: the caller's ERC-20 interface must enforce STATICCALL.
    function balanceOf(address) external returns (uint256) {
        (bool success,) = address(_cemetery).call{gas: 100_000}(abi.encodeCall(_cemetery.seal, (_victim)));
        require(!success, "state-changing token callback succeeded");
        return 1;
    }
}

/// @notice Shared fixtures and record assertions for the independent test suites.
abstract contract CemeteryTestBase {
    /// @dev Foundry's deterministic cheatcode address.
    CemeteryVm internal constant vm = CemeteryVm(address(uint160(uint256(keccak256("hevm cheat code")))));
    /// @dev A nonzero starting time, avoiding accidental assumptions about timestamp zero.
    uint256 internal constant START = 1_700_000_000;
    /// @dev Specified wake duration and post-objection cooldown.
    uint256 internal constant PERIOD = 30 days;
    /// @dev A digger with no default token balance.
    address internal constant DIGGER = address(0xD166E2);
    /// @dev A distinct holder used for objections.
    address internal constant HOLDER = address(0xB0B);
    /// @dev An unrelated participant used to verify permissionless actions.
    address internal constant STRANGER = address(0xCA11);
    /// @dev Fresh application for each test.
    MemecoinCemetery internal cemetery;
    /// @dev Default mock with one million base units of supply.
    CemeteryTokenMock internal token;

    /// @notice Expected wake event, including indexed token and digger.
    event WakeOpened(address indexed token, address indexed digger, string epitaph, uint256 endsAt);
    /// @notice Expected cancellation event, including the actual objecting holder.
    event Resurrected(address indexed token, address indexed holder);
    /// @notice Expected burial event, retaining the original digger.
    event Buried(address indexed token, string epitaph, address indexed digger, uint256 sealedAt);

    /// @notice Deploys isolated, fee-free fixtures without a fork or environment variables.
    function setUp() public virtual {
        vm.warp(START);
        cemetery = new MemecoinCemetery();
        token = new CemeteryTokenMock(1_000_000);
    }

    /// @dev Opens the default token's wake from a balance-free digger.
    function _dig() internal {
        vm.prank(DIGGER);
        cemetery.dig(address(token), "Gone but not forgotten");
    }

    /// @dev Compares every externally visible record field against the expected lifecycle state.
    function _assertRecord(
        address subject,
        MemecoinCemetery.State expectedState,
        address expectedDigger,
        string memory expectedEpitaph,
        uint256 expectedTimestamp
    ) internal view {
        (MemecoinCemetery.State state, address digger, string memory epitaph, uint256 timestamp) =
            cemetery.graveOf(subject);
        require(state == expectedState, "wrong record state");
        require(digger == expectedDigger, "wrong original digger");
        require(keccak256(bytes(epitaph)) == keccak256(bytes(expectedEpitaph)), "wrong epitaph");
        require(timestamp == expectedTimestamp, "wrong lifecycle timestamp");
    }

    /// @dev Asserts that no wake or grave metadata survives for the selected token.
    function _assertEmpty(address subject) internal view {
        _assertRecord(subject, MemecoinCemetery.State.None, address(0), "", 0);
    }

    /// @dev Asserts that a failed operation preserved the default wake and grave count.
    function _assertDefaultWake() internal view {
        _assertRecord(address(token), MemecoinCemetery.State.Wake, DIGGER, "Gone but not forgotten", START + PERIOD);
        require(cemetery.graveCount() == 0, "unsealed wake counted as grave");
    }

    /// @dev Constructs an ASCII epitaph with precisely the requested byte length.
    function _epitaph(uint256 length) internal pure returns (string memory) {
        bytes memory value = new bytes(length);
        for (uint256 i; i < length; ++i) {
            value[i] = "x";
        }
        return string(value);
    }
}

/// @notice Tests permissionless lifecycle transitions, time boundaries, metadata and permanence.
contract MemecoinCemeteryLifecycleTest is CemeteryTestBase {
    /// @notice Unseen tokens have no record, and no graves are counted at deployment.
    function test_InitialState() public view {
        _assertEmpty(address(token));
        _assertEmpty(address(0));
        require(cemetery.graveCount() == 0, "nonzero initial grave count");
        require(address(cemetery).balance == 0, "unexpected initial ETH");
    }

    /// @notice A nonholder opens a 30-day wake and emits every specified event field.
    function test_DigByNonholderEmitsWakeOpened() public {
        require(token.balanceOf(DIGGER) == 0, "fixture digger owns tokens");
        vm.expectEmit(true, true, false, true, address(cemetery));
        emit WakeOpened(address(token), DIGGER, "Gone but not forgotten", START + PERIOD);
        _dig();
        _assertDefaultWake();
        require(token.balanceOf(DIGGER) == 0, "dig transferred tokens");
        require(token.balanceOf(address(cemetery)) == 0, "dig took custody");
    }

    /// @notice Neither another sender nor an expired but unsealed wake permits a duplicate dig.
    function test_DuplicateDigCannotReplaceWakeEvenAfterExpiry() public {
        _dig();
        vm.prank(STRANGER);
        vm.expectRevert(MemecoinCemetery.GraveAlreadyExists.selector);
        cemetery.dig(address(token), "replacement");
        _assertDefaultWake();
        vm.warp(START + PERIOD + 1);
        vm.expectRevert(MemecoinCemetery.GraveAlreadyExists.selector);
        cemetery.dig(address(token), "expired replacement");
        _assertDefaultWake();
    }

    /// @notice A caller with exactly 0.1% cancels the wake, clears metadata and retains its tokens.
    function test_ExactThresholdHolderResurrectsAndEmits() public {
        _dig();
        token.setBalance(HOLDER, 1000);
        vm.expectEmit(true, true, false, true, address(cemetery));
        emit Resurrected(address(token), HOLDER);
        vm.prank(HOLDER);
        cemetery.itLives(address(token));
        _assertEmpty(address(token));
        require(cemetery.graveCount() == 0, "cancelled wake counted");
        require(token.balanceOf(HOLDER) == 1000, "objection consumed tokens");
        require(token.balanceOf(address(cemetery)) == 0, "objection took custody");
        vm.expectRevert(MemecoinCemetery.NotInWake.selector);
        cemetery.itLives(address(token));
        vm.expectRevert(MemecoinCemetery.NotInWake.selector);
        cemetery.seal(address(token));
    }

    /// @notice Both a zero balance and one unit below the threshold fail without cancelling the wake.
    function test_BelowThresholdAndNonholderCannotObject() public {
        _dig();
        vm.prank(STRANGER);
        vm.expectRevert(MemecoinCemetery.InsufficientBalance.selector);
        cemetery.itLives(address(token));
        token.setBalance(HOLDER, 999);
        vm.prank(HOLDER);
        vm.expectRevert(MemecoinCemetery.InsufficientBalance.selector);
        cemetery.itLives(address(token));
        _assertDefaultWake();
        vm.warp(START + PERIOD);
        cemetery.seal(address(token));
        require(cemetery.graveCount() == 1, "failed objection blocked burial");
    }

    /// @notice Objections succeed one second before the wake deadline.
    function test_ObjectionAtLastSecond() public {
        _dig();
        token.setBalance(HOLDER, 1000);
        vm.warp(START + PERIOD - 1);
        vm.prank(HOLDER);
        cemetery.itLives(address(token));
        _assertEmpty(address(token));
    }

    /// @notice Objections fail at and after the deadline even before anyone seals the grave.
    function test_ObjectionRejectedAtAndAfterDeadline() public {
        _dig();
        token.setBalance(HOLDER, 1_000_000);
        vm.warp(START + PERIOD);
        vm.prank(HOLDER);
        vm.expectRevert(MemecoinCemetery.WakeEnded.selector);
        cemetery.itLives(address(token));
        vm.warp(START + PERIOD + 1);
        vm.prank(HOLDER);
        vm.expectRevert(MemecoinCemetery.WakeEnded.selector);
        cemetery.itLives(address(token));
        _assertDefaultWake();
    }

    /// @notice Neither seal nor itLives is valid for an unseen token.
    function test_LifecycleCallsRequireAnExistingWake() public {
        vm.expectRevert(MemecoinCemetery.NotInWake.selector);
        cemetery.seal(address(token));
        vm.expectRevert(MemecoinCemetery.NotInWake.selector);
        cemetery.itLives(address(token));
        _assertEmpty(address(token));
        require(cemetery.graveCount() == 0, "invalid calls changed count");
    }

    /// @notice Sealing fails immediately and one second before expiry; anyone can seal at expiry.
    function test_SealBoundaryAndBuriedEvent() public {
        _dig();
        vm.expectRevert(MemecoinCemetery.WakeNotEnded.selector);
        cemetery.seal(address(token));
        vm.warp(START + PERIOD - 1);
        vm.expectRevert(MemecoinCemetery.WakeNotEnded.selector);
        cemetery.seal(address(token));
        _assertDefaultWake();
        vm.warp(START + PERIOD);
        vm.expectEmit(true, true, false, true, address(cemetery));
        emit Buried(address(token), "Gone but not forgotten", DIGGER, START + PERIOD);
        vm.prank(STRANGER);
        cemetery.seal(address(token));
        _assertRecord(address(token), MemecoinCemetery.State.Buried, DIGGER, "Gone but not forgotten", START + PERIOD);
        require(cemetery.graveCount() == 1, "grave not counted once");
    }

    /// @notice A delayed seal stores and emits the actual seal time instead of the old wake deadline.
    function test_LateSealUsesActualTimestamp() public {
        _dig();
        uint256 sealedAt = START + PERIOD + 123 days;
        vm.warp(sealedAt);
        _assertDefaultWake();
        vm.expectEmit(true, true, false, true, address(cemetery));
        emit Buried(address(token), "Gone but not forgotten", DIGGER, sealedAt);
        vm.prank(STRANGER);
        cemetery.seal(address(token));
        _assertRecord(address(token), MemecoinCemetery.State.Buried, DIGGER, "Gone but not forgotten", sealedAt);
        require(cemetery.graveCount() == 1, "late grave not counted");
    }

    /// @notice Buried records cannot be dug, resurrected or sealed again, even years later.
    function test_SealedGraveIsPermanent() public {
        _dig();
        vm.warp(START + PERIOD);
        cemetery.seal(address(token));
        token.setBalance(HOLDER, 1_000_000);
        for (uint256 i; i < 2; ++i) {
            vm.prank(DIGGER);
            vm.expectRevert(MemecoinCemetery.GraveAlreadyExists.selector);
            cemetery.dig(address(token), "reopened");
            vm.prank(HOLDER);
            vm.expectRevert(MemecoinCemetery.NotInWake.selector);
            cemetery.itLives(address(token));
            vm.prank(STRANGER);
            vm.expectRevert(MemecoinCemetery.NotInWake.selector);
            cemetery.seal(address(token));
            _assertRecord(
                address(token), MemecoinCemetery.State.Buried, DIGGER, "Gone but not forgotten", START + PERIOD
            );
            require(cemetery.graveCount() == 1, "permanent grave double counted");
            vm.warp(START + 3650 days);
        }
    }

    /// @notice Cooldown starts at cancellation, applies to every digger, and ends exactly 30 days later.
    function test_RedigCooldownAndRepeatedResurrection() public {
        _dig();
        token.setBalance(HOLDER, 1000);
        uint256 cancelledAt = START + 10 days;
        vm.warp(cancelledAt);
        vm.prank(HOLDER);
        cemetery.itLives(address(token));
        vm.prank(DIGGER);
        vm.expectRevert(MemecoinCemetery.CooldownActive.selector);
        cemetery.dig(address(token), "too soon");
        vm.warp(START + PERIOD);
        vm.prank(STRANGER);
        vm.expectRevert(MemecoinCemetery.CooldownActive.selector);
        cemetery.dig(address(token), "old deadline is too soon");
        vm.warp(cancelledAt + PERIOD - 1);
        vm.prank(STRANGER);
        vm.expectRevert(MemecoinCemetery.CooldownActive.selector);
        cemetery.dig(address(token), "one second too soon");
        _assertEmpty(address(token));

        uint256 redigAt = cancelledAt + PERIOD;
        vm.warp(redigAt);
        vm.expectEmit(true, true, false, true, address(cemetery));
        emit WakeOpened(address(token), STRANGER, "A second chance", redigAt + PERIOD);
        vm.prank(STRANGER);
        cemetery.dig(address(token), "A second chance");
        _assertRecord(address(token), MemecoinCemetery.State.Wake, STRANGER, "A second chance", redigAt + PERIOD);

        vm.warp(redigAt + 1 days);
        vm.prank(HOLDER);
        cemetery.itLives(address(token));
        _assertEmpty(address(token));
        vm.warp(redigAt + 1 days + PERIOD - 1);
        vm.expectRevert(MemecoinCemetery.CooldownActive.selector);
        cemetery.dig(address(token), "second cooldown");
        vm.warp(redigAt + 1 days + PERIOD);
        cemetery.dig(address(token), "Final resting place");
        vm.warp(redigAt + 1 days + 2 * PERIOD);
        cemetery.seal(address(token));
        _assertRecord(
            address(token),
            MemecoinCemetery.State.Buried,
            address(this),
            "Final resting place",
            redigAt + 1 days + 2 * PERIOD
        );
        require(cemetery.graveCount() == 1, "repeated wakes changed count");
    }

    /// @notice Records, cooldowns and grave counts remain independent across token addresses.
    function test_MultipleTokensHaveIndependentRecordsAndCooldowns() public {
        CemeteryTokenMock second = new CemeteryTokenMock(1000);
        CemeteryTokenMock third = new CemeteryTokenMock(1000);
        _dig();
        cemetery.dig(address(second), "Second");
        token.setBalance(HOLDER, 1000);
        vm.warp(START + 1 days);
        vm.prank(HOLDER);
        cemetery.itLives(address(token));
        cemetery.dig(address(third), "Third");
        require(cemetery.graveCount() == 0, "wakes counted");
        vm.warp(START + PERIOD);
        cemetery.seal(address(second));
        require(cemetery.graveCount() == 1, "wrong first grave count");
        _assertEmpty(address(token));
        _assertRecord(address(third), MemecoinCemetery.State.Wake, address(this), "Third", START + 1 days + PERIOD);
        vm.warp(START + 1 days + PERIOD);
        cemetery.seal(address(third));
        vm.prank(STRANGER);
        cemetery.dig(address(token), "Returned");
        require(cemetery.graveCount() == 2, "redig changed grave count");
        _assertRecord(address(second), MemecoinCemetery.State.Buried, address(this), "Second", START + PERIOD);
        _assertRecord(address(third), MemecoinCemetery.State.Buried, address(this), "Third", START + 1 days + PERIOD);
        _assertRecord(address(token), MemecoinCemetery.State.Wake, STRANGER, "Returned", START + 1 days + 2 * PERIOD);
    }
}

/// @notice Tests token compatibility, live eligibility, input limits and rejected ETH.
/// forge-config: default.fuzz.runs = 1000
contract MemecoinCemeteryEdgeTest is CemeteryTestBase {
    /// @notice Zero and code-free addresses cannot acquire records.
    function test_DigRejectsZeroAddressAndEOA() public {
        vm.expectRevert(MemecoinCemetery.InvalidToken.selector);
        cemetery.dig(address(0), "Zero");
        vm.expectRevert(MemecoinCemetery.InvalidToken.selector);
        cemetery.dig(STRANGER, "EOA");
        _assertEmpty(address(0));
        _assertEmpty(STRANGER);
        require(cemetery.graveCount() == 0, "invalid token counted");
    }

    /// @notice Deployed code without ERC-20 read functions is also rejected.
    function test_DigRejectsNonTokenContract() public {
        vm.expectRevert(MemecoinCemetery.TokenReadFailed.selector);
        cemetery.dig(address(cemetery), "Not an ERC-20");
        _assertEmpty(address(cemetery));
    }

    /// @notice An empty epitaph is accepted and remains empty after burial.
    function test_EmptyEpitaphRoundTrip() public {
        cemetery.dig(address(token), "");
        _assertRecord(address(token), MemecoinCemetery.State.Wake, address(this), "", START + PERIOD);
        vm.warp(START + PERIOD);
        cemetery.seal(address(token));
        _assertRecord(address(token), MemecoinCemetery.State.Buried, address(this), "", START + PERIOD);
    }

    /// @notice The exact 140-byte limit survives storage and both lifecycle events.
    function test_MaximumEpitaphRoundTrip() public {
        string memory epitaph = _epitaph(140);
        vm.expectEmit(true, true, false, true, address(cemetery));
        emit WakeOpened(address(token), address(this), epitaph, START + PERIOD);
        cemetery.dig(address(token), epitaph);
        _assertRecord(address(token), MemecoinCemetery.State.Wake, address(this), epitaph, START + PERIOD);
        vm.warp(START + PERIOD);
        vm.expectEmit(true, true, false, true, address(cemetery));
        emit Buried(address(token), epitaph, address(this), START + PERIOD);
        cemetery.seal(address(token));
        _assertRecord(address(token), MemecoinCemetery.State.Buried, address(this), epitaph, START + PERIOD);
    }

    /// @notice An epitaph one byte over the limit fails atomically and does not start a cooldown.
    function test_Epitaph141BytesRejectedThenValidDigSucceeds() public {
        vm.expectRevert(MemecoinCemetery.EpitaphTooLong.selector);
        cemetery.dig(address(token), _epitaph(141));
        _assertEmpty(address(token));
        _dig();
        _assertDefaultWake();
    }

    /// @notice The epitaph limit counts UTF-8 bytes rather than displayed characters.
    function test_UnicodeEpitaphUsesByteLength() public {
        string memory epitaph;
        for (uint256 i; i < 35; ++i) {
            epitaph = string.concat(epitaph, unicode"🪦");
        }
        require(bytes(epitaph).length == 140, "incorrect UTF-8 fixture");
        vm.expectRevert(MemecoinCemetery.EpitaphTooLong.selector);
        cemetery.dig(address(token), string.concat(epitaph, "x"));
        _assertEmpty(address(token));
        cemetery.dig(address(token), epitaph);
        _assertRecord(address(token), MemecoinCemetery.State.Wake, address(this), epitaph, START + PERIOD);
    }

    /// @notice Arbitrary byte strings are retained exactly up to the limit and rejected above it.
    function testFuzz_EpitaphBytes(bytes memory raw) public {
        if (raw.length > 140) {
            vm.expectRevert(MemecoinCemetery.EpitaphTooLong.selector);
            cemetery.dig(address(token), string(raw));
            _assertEmpty(address(token));
        } else {
            cemetery.dig(address(token), string(raw));
            _assertRecord(address(token), MemecoinCemetery.State.Wake, address(this), string(raw), START + PERIOD);
        }
        require(cemetery.graveCount() == 0, "dig changed grave count");
    }

    /// @notice A balance acquired after dig qualifies; the caller's own current balance is used.
    function test_ObjectionReadsCurrentBalanceOfCaller() public {
        token.setBalance(DIGGER, 1_000_000);
        _dig();
        vm.prank(HOLDER);
        vm.expectRevert(MemecoinCemetery.InsufficientBalance.selector);
        cemetery.itLives(address(token));
        token.setBalance(HOLDER, 1000);
        vm.prank(HOLDER);
        cemetery.itLives(address(token));
        _assertEmpty(address(token));
    }

    /// @notice A formerly eligible holder that has disposed of its tokens cannot object.
    function test_FormerHolderCannotUseOpeningBalance() public {
        token.setBalance(HOLDER, 1000);
        _dig();
        token.setBalance(HOLDER, 999);
        vm.prank(HOLDER);
        vm.expectRevert(MemecoinCemetery.InsufficientBalance.selector);
        cemetery.itLives(address(token));
        _assertDefaultWake();
    }

    /// @notice Supply increases and decreases after dig change eligibility immediately.
    function test_ObjectionReadsCurrentSupply() public {
        token.setBalance(HOLDER, 1000);
        _dig();
        token.setSupply(1_000_001);
        vm.prank(HOLDER);
        vm.expectRevert(MemecoinCemetery.InsufficientBalance.selector);
        cemetery.itLives(address(token));
        _assertDefaultWake();
        token.setSupply(999_999);
        vm.prank(HOLDER);
        cemetery.itLives(address(token));
        _assertEmpty(address(token));
    }

    /// @notice A zero-supply token may be buried, but a zero-balance account cannot object.
    function test_ZeroSupplyCanBeBuriedWithoutZeroBalanceObjection() public {
        token.setSupply(0);
        _dig();
        vm.prank(HOLDER);
        vm.expectRevert(MemecoinCemetery.InsufficientBalance.selector);
        cemetery.itLives(address(token));
        _assertDefaultWake();
        vm.warp(START + PERIOD);
        cemetery.seal(address(token));
        require(cemetery.graveCount() == 1, "zero-supply burial failed");
    }

    /// @notice A supply that becomes zero during the wake cannot authorize an objection.
    function test_SupplyBecomingZeroRejectsObjection() public {
        _dig();
        token.setSupply(0);
        token.setBalance(HOLDER, 0);
        vm.prank(HOLDER);
        vm.expectRevert(MemecoinCemetery.InsufficientBalance.selector);
        cemetery.itLives(address(token));
        _assertDefaultWake();
    }

    /// @notice Explicit small, indivisible and maximum supplies require rounding the threshold up.
    function test_ThresholdArithmeticEdges() public {
        uint256[7] memory supplies = [uint256(1), 999, 1000, 1001, 1_000_001, type(uint256).max - 1, type(uint256).max];
        for (uint256 i; i < supplies.length; ++i) {
            _checkThreshold(supplies[i]);
        }
    }

    /// @notice Every nonzero supply accepts the first eligible unit and rejects the previous unit.
    function testFuzz_ThresholdRoundsUpWithoutOverflow(uint256 supply) public {
        if (supply == 0) supply = 1;
        _checkThreshold(supply);
    }

    /// @dev Computes ceil(supply / 1000) independently via subtraction to avoid overflowing multiplication.
    function _checkThreshold(uint256 supply) internal {
        CemeteryTokenMock subject = new CemeteryTokenMock(supply);
        uint256 minimum = (supply - 1) / 1000 + 1;
        cemetery.dig(address(subject), "Arithmetic boundary");
        subject.setBalance(HOLDER, minimum - 1);
        vm.prank(HOLDER);
        vm.expectRevert(MemecoinCemetery.InsufficientBalance.selector);
        cemetery.itLives(address(subject));
        _assertRecord(
            address(subject), MemecoinCemetery.State.Wake, address(this), "Arithmetic boundary", START + PERIOD
        );
        subject.setBalance(HOLDER, minimum);
        vm.prank(HOLDER);
        cemetery.itLives(address(subject));
        _assertEmpty(address(subject));
        require(cemetery.graveCount() == 0, "threshold test changed grave count");
    }

    /// @notice Eligibility matches the mathematical threshold for arbitrary supply and balance pairs.
    function testFuzz_ArbitraryHolderEligibility(uint256 supply, uint256 balanceSeed) public {
        uint256 balance = supply == type(uint256).max ? balanceSeed : balanceSeed % (supply + 1);
        token.setSupply(supply);
        token.setBalance(HOLDER, balance);
        _dig();
        // Multiplication-free reference predicate: balance >= ceil(supply / 1000).
        bool eligible = supply != 0 && balance > (supply - 1) / 1000;
        vm.prank(HOLDER);
        if (!eligible) vm.expectRevert(MemecoinCemetery.InsufficientBalance.selector);
        cemetery.itLives(address(token));
        if (eligible) _assertEmpty(address(token));
        else _assertDefaultWake();
    }

    /// @notice Reverting totalSupply during dig leaves no record or cooldown and can be retried.
    function test_DigRejectsRevertingSupply() public {
        _checkFailedDig(1, 0);
    }

    /// @notice Reverting balanceOf during dig leaves no record or cooldown and can be retried.
    function test_DigRejectsRevertingBalance() public {
        _checkFailedDig(0, 1);
    }

    /// @notice Empty and truncated ERC-20 return data cannot open a wake.
    function test_DigRejectsMalformedTokenReads() public {
        _checkFailedDig(2, 0);
        token = new CemeteryTokenMock(1_000_000);
        _checkFailedDig(3, 0);
        token = new CemeteryTokenMock(1_000_000);
        _checkFailedDig(0, 2);
        token = new CemeteryTokenMock(1_000_000);
        _checkFailedDig(0, 3);
    }

    /// @dev Checks both failure atomicity and immediate recovery from an unsuccessful dig.
    function _checkFailedDig(uint8 supplyMode, uint8 balanceMode) internal {
        token.setReadModes(supplyMode, balanceMode);
        if (supplyMode == 1 || balanceMode == 1) vm.expectRevert(MemecoinCemetery.TokenReadFailed.selector);
        else vm.expectRevert();
        cemetery.dig(address(token), "Unreadable");
        _assertEmpty(address(token));
        require(cemetery.graveCount() == 0, "failed dig counted");
        token.setReadModes(0, 0);
        _dig();
        _assertDefaultWake();
    }

    /// @notice Token read failures during an objection preserve the wake; a later valid objection works.
    function test_ObjectionReadFailuresAreAtomicAndRecoverable() public {
        _dig();
        token.setBalance(HOLDER, 1000);
        for (uint8 mode = 1; mode <= 3; ++mode) {
            for (uint8 read; read < 2; ++read) {
                token.setReadModes(read == 0 ? mode : 0, read == 1 ? mode : 0);
                vm.prank(HOLDER);
                if (mode == 1) vm.expectRevert(MemecoinCemetery.TokenReadFailed.selector);
                else vm.expectRevert();
                cemetery.itLives(address(token));
                _assertDefaultWake();
            }
        }
        token.setReadModes(0, 0);
        vm.prank(HOLDER);
        cemetery.itLives(address(token));
        _assertEmpty(address(token));
    }

    /// @notice Once a wake exists, reverting token reads cannot prevent permissionless sealing.
    function test_SealDoesNotReadBrokenToken() public {
        _dig();
        token.setReadModes(1, 1);
        vm.prank(HOLDER);
        vm.expectRevert(MemecoinCemetery.TokenReadFailed.selector);
        cemetery.itLives(address(token));
        vm.warp(START + PERIOD);
        vm.prank(STRANGER);
        cemetery.seal(address(token));
        _assertRecord(address(token), MemecoinCemetery.State.Buried, DIGGER, "Gone but not forgotten", START + PERIOD);
        require(cemetery.graveCount() == 1, "broken token blocked burial");
    }

    /// @notice Token callbacks cannot mutate cemetery state during either dig or itLives.
    function test_TokenReadsEnforceStaticCallbacks() public {
        _dig();
        vm.warp(START + PERIOD);
        CemeteryCallbackToken callback = new CemeteryCallbackToken(cemetery, address(token));
        cemetery.dig(address(callback), "Callback token");
        _assertDefaultWake();
        cemetery.itLives(address(callback));
        _assertEmpty(address(callback));
        _assertDefaultWake();
        // The same callback target is genuinely sealable outside the token's static context.
        cemetery.seal(address(token));
        require(cemetery.graveCount() == 1, "callback target was not sealable");
    }

    /// @notice Plain ETH, unknown calldata, and value attached to every public entry point are rejected.
    function test_ETHRejectedAtEveryEntryPoint() public {
        vm.deal(address(this), 1 ether);
        _assertETHRejected("");
        _assertETHRejected(hex"deadbeef");
        _assertETHRejected(abi.encodeCall(cemetery.dig, (address(token), "Paid dig")));
        _assertEmpty(address(token));
        _dig();
        token.setBalance(address(this), 1000);
        _assertETHRejected(abi.encodeCall(cemetery.itLives, (address(token))));
        _assertDefaultWake();
        _assertETHRejected(abi.encodeCall(cemetery.graveOf, (address(token))));
        _assertETHRejected(abi.encodeCall(cemetery.graveCount, ()));
        vm.warp(START + PERIOD);
        _assertETHRejected(abi.encodeCall(cemetery.seal, (address(token))));
        _assertDefaultWake();
        cemetery.seal(address(token));
        _assertETHRejected("");
        require(cemetery.graveCount() == 1, "ETH attempt changed count");
    }

    /// @dev Makes a value-bearing call and verifies rejection without ETH retention.
    function _assertETHRejected(bytes memory data) internal {
        uint256 balanceBefore = address(this).balance;
        (bool success,) = address(cemetery).call{value: 1 wei}(data);
        require(!success, "cemetery accepted ETH");
        require(address(cemetery).balance == 0, "cemetery retained ETH");
        require(address(this).balance == balanceBefore, "rejected call lost ETH");
    }
}

/// @notice Drives bounded random lifecycle calls against an independent model of four tokens.
/// @dev Expected reverts are consumed here; unexpected success or failure reverts the handler.
contract CemeteryLifecycleHandler {
    /// @dev Cheatcodes used to vary actors, time and ETH balances.
    CemeteryVm private constant vm = CemeteryVm(address(uint160(uint256(keccak256("hevm cheat code")))));
    /// @dev Wake and cooldown duration from the specification.
    uint256 private constant PERIOD = 30 days;
    /// @dev Application under invariant testing.
    MemecoinCemetery private immutable _cemetery;
    /// @dev Finite token set makes exhaustive record/count comparison possible after every call.
    CemeteryTokenMock[4] private _tokens;
    /// @dev Independent lifecycle model; buried records never change again.
    ExpectedRecord[4] private _expected;
    /// @dev Number of successful model transitions into Buried.
    uint256 private _expectedCount;

    /// @notice Expected observable record plus the independent per-token cooldown deadline.
    struct ExpectedRecord {
        /// @dev Expected lifecycle state.
        MemecoinCemetery.State state;
        /// @dev Expected opening caller.
        address digger;
        /// @dev Hash of the exact expected epitaph bytes.
        bytes32 epitaphHash;
        /// @dev Expected wake deadline or seal timestamp.
        uint256 timestamp;
        /// @dev Earliest valid re-dig time after a successful objection.
        uint256 nextDig;
    }

    /// @notice Starts each campaign with an active wake, a permanent grave, a cooldown and an unseen token.
    constructor(MemecoinCemetery cemetery) {
        _cemetery = cemetery;
        for (uint256 i; i < _tokens.length; ++i) {
            _tokens[i] = new CemeteryTokenMock(1_000_000);
            _expected[i].epitaphHash = keccak256("");
        }
        dig(1, 0, 40);
        vm.warp(vm.getBlockTimestamp() + PERIOD);
        seal(1, 1);
        dig(0, 0, 40);
        dig(2, 1, 40);
        object(2, 2, 1_000_000, 2, false);
    }

    /// @notice Attempts digs by several actors with epitaph lengths spanning the allowed boundary.
    function dig(uint256 tokenSeed, uint256 actorSeed, uint8 lengthSeed) public {
        uint256 index = tokenSeed % _tokens.length;
        ExpectedRecord storage expected = _expected[index];
        address actor = _actor(actorSeed);
        uint256 timestamp = vm.getBlockTimestamp();
        bytes memory epitaph = new bytes(uint256(lengthSeed) % 151);
        if (epitaph.length != 0) epitaph[0] = bytes1(keccak256(abi.encode(actor, timestamp)));
        bool shouldSucceed =
            expected.state == MemecoinCemetery.State.None && timestamp >= expected.nextDig && epitaph.length <= 140;
        vm.prank(actor);
        (bool success,) =
            address(_cemetery).call(abi.encodeCall(_cemetery.dig, (address(_tokens[index]), string(epitaph))));
        require(success == shouldSucceed, "dig disagrees with lifecycle model");
        if (shouldSucceed) {
            expected.state = MemecoinCemetery.State.Wake;
            expected.digger = actor;
            expected.epitaphHash = keccak256(epitaph);
            expected.timestamp = timestamp + PERIOD;
        }
    }

    /// @notice Varies current supply, boundary balances and token failures before attempting an objection.
    function object(uint256 tokenSeed, uint256 actorSeed, uint128 supply, uint8 balanceSeed, bool unreadable) public {
        uint256 index = tokenSeed % _tokens.length;
        address actor = _actor(actorSeed);
        CemeteryTokenMock subject = _tokens[index];
        ExpectedRecord storage expected = _expected[index];
        uint256 minimum = supply == 0 ? 1 : (uint256(supply) - 1) / 1000 + 1;
        uint256 balance;
        if (balanceSeed % 4 == 1) balance = minimum - 1;
        else if (balanceSeed % 4 == 2) balance = minimum;
        else if (balanceSeed % 4 == 3) balance = supply;
        if (supply == 0) balance = 0;
        subject.setSupply(supply);
        subject.setBalance(actor, balance);
        subject.setReadModes(unreadable ? 1 : 0, 0);
        bool shouldSucceed = expected.state == MemecoinCemetery.State.Wake
            && vm.getBlockTimestamp() < expected.timestamp && !unreadable && supply != 0 && balance >= minimum;
        vm.prank(actor);
        (bool success,) = address(_cemetery).call(abi.encodeCall(_cemetery.itLives, (address(subject))));
        require(success == shouldSucceed, "objection disagrees with lifecycle model");
        subject.setReadModes(0, 0);
        if (shouldSucceed) {
            delete _expected[index];
            _expected[index].epitaphHash = keccak256("");
            _expected[index].nextDig = vm.getBlockTimestamp() + PERIOD;
        }
    }

    /// @notice Attempts sealing by arbitrary participants, including duplicate and premature calls.
    function seal(uint256 tokenSeed, uint256 actorSeed) public {
        uint256 index = tokenSeed % _tokens.length;
        ExpectedRecord storage expected = _expected[index];
        uint256 timestamp = vm.getBlockTimestamp();
        bool shouldSucceed = expected.state == MemecoinCemetery.State.Wake && timestamp >= expected.timestamp;
        vm.prank(_actor(actorSeed));
        (bool success,) = address(_cemetery).call(abi.encodeCall(_cemetery.seal, (address(_tokens[index]))));
        require(success == shouldSucceed, "seal disagrees with lifecycle model");
        if (shouldSucceed) {
            expected.state = MemecoinCemetery.State.Buried;
            expected.timestamp = timestamp;
            ++_expectedCount;
        }
    }

    /// @notice Advances time by up to 40 days, crossing wake and cooldown deadlines in random order.
    function advanceTime(uint32 elapsed) external {
        vm.warp(vm.getBlockTimestamp() + uint256(elapsed) % (40 days + 1));
    }

    /// @notice Attempts a bounded ETH transfer at arbitrary lifecycle states.
    function sendETH(uint96 amountSeed) external {
        uint256 amount = uint256(amountSeed) % 1 ether + 1;
        vm.deal(address(this), amount);
        (bool success,) = address(_cemetery).call{value: amount}("");
        require(!success, "random ETH transfer accepted");
    }

    /// @notice Checks every record, permanent-grave accounting and the absence of voluntary ETH custody.
    /// @dev Forced ETH and unsolicited ERC-20 transfers are outside the contract's payable-call policy.
    function assertModel() external view {
        uint256 observedGraves;
        for (uint256 i; i < _tokens.length; ++i) {
            ExpectedRecord storage expected = _expected[i];
            (MemecoinCemetery.State state, address digger, string memory epitaph, uint256 timestamp) =
                _cemetery.graveOf(address(_tokens[i]));
            require(state == expected.state, "random sequence changed expected state");
            require(digger == expected.digger, "random sequence changed original digger");
            require(keccak256(bytes(epitaph)) == expected.epitaphHash, "random sequence changed epitaph");
            require(timestamp == expected.timestamp, "random sequence changed timestamp");
            if (state == MemecoinCemetery.State.Buried) ++observedGraves;
        }
        require(_cemetery.graveCount() == observedGraves, "grave count differs from buried records");
        require(observedGraves == _expectedCount, "buried grave disappeared or was double counted");
        require(address(_cemetery).balance == 0, "random calls left ETH in cemetery");
    }

    /// @dev Selects from three distinct nonzero callers without giving any caller privileges.
    function _actor(uint256 seed) private pure returns (address) {
        if (seed % 3 == 0) return address(0xA11CE);
        if (seed % 3 == 1) return address(0xB0B);
        return address(0xCA11);
    }
}

/// @notice Stateful random tests of lifecycle consistency, permanent records and accurate grave counts.
/// forge-config: default.invariant.runs = 256
/// forge-config: default.invariant.depth = 64
/// forge-config: default.invariant.fail-on-revert = true
contract MemecoinCemeteryInvariantTest {
    /// @dev The only fuzz target; expected application reverts are handled within its actions.
    CemeteryLifecycleHandler private _handler;

    /// @notice Deploys a fresh cemetery and initializes the independent lifecycle model.
    function setUp() public {
        CemeteryVm(address(uint160(uint256(keccak256("hevm cheat code"))))).warp(1_700_000_000);
        _handler = new CemeteryLifecycleHandler(new MemecoinCemetery());
    }

    /// @notice Foundry invariant targeting hook, avoiding any dependency on forge-std.
    /// @return targets Only the handler, so random calls cannot bypass model bookkeeping.
    function targetContracts() public view returns (address[] memory targets) {
        targets = new address[](1);
        targets[0] = address(_handler);
    }

    /// @notice All records equal the model after every action; graves are permanent and counted exactly once.
    function invariant_RecordsCountAndPermanenceMatchModel() public view {
        _handler.assertModel();
    }
}
