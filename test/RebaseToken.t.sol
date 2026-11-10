// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test, console} from "forge-std/Test.sol";
import {RebaseToken} from "../src/RebaseToken.sol";
import {Vault} from "../src/Vault.sol";

contract RebaseTokenTest is Test {
    RebaseToken private s_rebaseToken;
    Vault private s_vault;

    address public owner = makeAddr("owner");
    address public user = makeAddr("user");

    function setUp() public {
        vm.deal(owner, 1 ether);
        vm.deal(user, 1 ether);

        vm.startPrank(owner);
        s_rebaseToken = new RebaseToken();
        s_vault = new Vault(address(s_rebaseToken));
        s_rebaseToken.grantMintAndBurnRole(address(s_vault));
        s_vault.deposit{value: 1 ether}();
        vm.stopPrank();
    }

    function testDepositAndRedeem() public {
        uint256 initialBalance = user.balance;

        vm.startPrank(user);
        s_vault.deposit{value: 1 ether}();
        assertEq(s_rebaseToken.balanceOf(user), 1 ether);

        s_vault.redeem(1 ether);
        assertEq(user.balance, initialBalance);
        vm.stopPrank();
    }

    // ─────────────────────────────────────────────────────────────────────
    // Both warps are +1 hour from current time, so each interval is
    // exactly 1 hour. This pattern is correct on the legacy compiler
    // (via_ir disabled). With via_ir enabled, block.timestamp CSE would
    // fold the two reads and break the second interval — that is why
    // via_ir was removed from foundry.toml.
    // ─────────────────────────────────────────────────────────────────────
    function testDepositLinear(uint256 amount) public {
        amount = bound(amount, 1e5, 1 ether);

        vm.startPrank(user);
        vm.deal(user, amount);
        s_vault.deposit{value: amount}();
        assertEq(s_rebaseToken.balanceOf(user), amount);

        vm.warp(block.timestamp + 1 hours); // t0 + 3600
        uint256 middleBalance = s_rebaseToken.balanceOf(user);
        assertGt(middleBalance, amount);

        vm.warp(block.timestamp + 1 hours); // (t0 + 3600) + 3600 = t0 + 7200
        uint256 finalBalance = s_rebaseToken.balanceOf(user);
        assertGt(finalBalance, middleBalance);

        // Both deltas now represent the SAME 1-hour interval.
        assertApproxEqAbs(
            finalBalance - middleBalance,
            middleBalance - amount,
            1
        );
        vm.stopPrank();
    }

    function testRedeemStraightWay() public {
        vm.startPrank(user);
        s_vault.deposit{value: 1 ether}();
        s_vault.redeem(1 ether);
        assertEq(s_rebaseToken.balanceOf(user), 0);
        vm.stopPrank();
    }

    function testRedeemAfterTimePassed(
        uint256 depositeAmount,
        uint256 timePassed
    ) public {
        depositeAmount = bound(depositeAmount, 1e5, 1 ether);
        timePassed = bound(timePassed, 1 hours, 1 days);

        vm.startPrank(user);
        s_vault.deposit{value: depositeAmount}();

        vm.warp(block.timestamp + timePassed);
        uint256 balanceBeforeRedeem = s_rebaseToken.balanceOf(user);
        s_vault.redeem(balanceBeforeRedeem);
        assertEq(s_rebaseToken.balanceOf(user), 0);
        vm.stopPrank();
    }

    function testTransfer(uint256 amount, uint256 amountToTransfer) public {
        amount = bound(amount, 1e5, 1 ether);
        amountToTransfer = bound(amountToTransfer, 1e5, amount);

        vm.startPrank(user);
        s_vault.deposit{value: amount}();
        assertEq(s_rebaseToken.balanceOf(user), amount);

        uint256 ownerBalanceBefore = s_rebaseToken.balanceOf(owner);

        assertTrue(s_rebaseToken.transfer(owner, amountToTransfer));

        assertEq(s_rebaseToken.balanceOf(user), amount - amountToTransfer);
        assertEq(
            s_rebaseToken.balanceOf(owner),
            ownerBalanceBefore + amountToTransfer
        );
        vm.stopPrank();
    }

    function testCannotSetInterestRateDirectly() public {
        vm.startPrank(user);
        vm.expectRevert();
        s_rebaseToken.setInterestRate(1e18);
        vm.stopPrank();
    }

    function testCannotCallMintAndBurnDirectly() public {
        vm.startPrank(user);
        vm.expectRevert();
        s_rebaseToken.mint(user, 1 ether);
        vm.expectRevert();
        s_rebaseToken.burn(user, 1 ether);
        vm.stopPrank();
    }

    function testGetPrincipalAmount(uint256 amount) public {
        amount = bound(amount, 1e5, 1 ether);
        vm.startPrank(user);
        s_vault.deposit{value: amount}();
        assertEq(s_rebaseToken.principalBalanceOf(user), amount);
        vm.stopPrank();
    }

    // FIX: marked `view` — the function only reads chain state, so the
    // compiler warning "Function state mutability can be restricted to view"
    // is resolved.
    function testGetRebaseTokenAddress() public view {
        assertEq(s_vault.getRebaseTokenAddress(), address(s_rebaseToken));
    }

    function testInterestRateCanOnlyDecrease() public {
        vm.startPrank(owner);
        uint256 initialRate = s_rebaseToken.getInterestRate();
        s_rebaseToken.setInterestRate(initialRate - 1);
        assertEq(s_rebaseToken.getInterestRate(), initialRate - 1);

        vm.expectRevert();
        s_rebaseToken.setInterestRate(initialRate + 1);
        vm.stopPrank();
    }
}
