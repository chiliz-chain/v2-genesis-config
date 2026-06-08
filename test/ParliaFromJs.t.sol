// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.17;

import {JsTruffleFixture} from "./JsTruffleFixture.sol";

/**
 * @title ParliaTest
 * @notice Forge port of `genesis/test/parlia.js` — validator set mutations through `FakeStaking` (governance hook).
 */
contract ParliaTest is JsTruffleFixture {
    uint32 internal constant EPOCH_BLOCKS = 10;

    MockChain internal chain;

    function setUp() public {
        chain = deployDefaultMockChain();
        // Seeds `_activeValidatorsListPerEpoch` so remove-validator paths do not read an empty epoch index (see Staking.initNewParams).
        vm.prank(address(chain.runtimeUpgrade));
        chain.staking.initNewParams();
    }

    /// @notice Add validator, observe active set after advancing epoch, remove and confirm list empty.
    function test_addRemoveValidator() public {
        address validator = 0x00A601f45688DbA8a070722073B015277cF36725;

        assertFalse(chain.staking.isValidator(validator));
        chain.staking.addValidator(validator);
        rollToNextEpoch(chain, EPOCH_BLOCKS);

        assertTrue(chain.staking.isValidator(validator));
        address[] memory validators = chain.staking.getValidators();
        assertEq(validators.length, 1);
        assertEq(validators[0], validator);

        chain.staking.removeValidator(validator);
        rollToNextEpoch(chain, EPOCH_BLOCKS);

        assertFalse(chain.staking.isValidator(validator));
        assertEq(chain.staking.getValidators().length, 0);
    }

    /// @notice Removing the first of three validators leaves the other two (swap-and-pop semantics).
    function test_removeFirstOfThree() public {
        address first = address(1);
        address middle = address(2);
        address last = address(3);
        chain.staking.addValidator(first);
        chain.staking.addValidator(middle);
        chain.staking.addValidator(last);
        rollToNextEpoch(chain, EPOCH_BLOCKS);

        chain.staking.removeValidator(first);
        rollToNextEpoch(chain, EPOCH_BLOCKS);

        address[] memory validators = chain.staking.getValidators();
        assertEq(validators.length, 2);
        assertTrue(_arrayContains(validators, middle));
        assertTrue(_arrayContains(validators, last));
    }

    /// @notice Removing the middle element must not drop the ends.
    function test_removeMiddleOfThree() public {
        address first = address(1);
        address middle = address(2);
        address last = address(3);
        chain.staking.addValidator(first);
        chain.staking.addValidator(middle);
        chain.staking.addValidator(last);
        rollToNextEpoch(chain, EPOCH_BLOCKS);

        chain.staking.removeValidator(middle);
        rollToNextEpoch(chain, EPOCH_BLOCKS);

        address[] memory validators = chain.staking.getValidators();
        assertEq(validators.length, 2);
        assertTrue(_arrayContains(validators, first));
        assertTrue(_arrayContains(validators, last));
    }

    /// @notice Removing the tail validator shrinks the set by one.
    function test_removeLastOfThree() public {
        address first = address(1);
        address middle = address(2);
        address last = address(3);
        chain.staking.addValidator(first);
        chain.staking.addValidator(middle);
        chain.staking.addValidator(last);
        rollToNextEpoch(chain, EPOCH_BLOCKS);

        chain.staking.removeValidator(last);
        rollToNextEpoch(chain, EPOCH_BLOCKS);

        address[] memory validators = chain.staking.getValidators();
        assertEq(validators.length, 2);
        assertTrue(_arrayContains(validators, first));
        assertTrue(_arrayContains(validators, middle));
    }

    function _arrayContains(address[] memory haystack, address needle) internal pure returns (bool) {
        for (uint256 i = 0; i < haystack.length; i++) {
            if (haystack[i] == needle) return true;
        }
        return false;
    }
}
