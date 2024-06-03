// SPDX-License-Identifier: MIT
pragma solidity 0.8.21;

import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { SafeERC20 } from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import { ISwap } from  "../../interfaces/swap/ISwap.sol";
import { LRTTypes } from "./LRTTypes.sol";
import { LRTReader } from "./LRTReader.sol";
import { LRTChecks } from "./LRTChecks.sol";
import { LRTManager } from "./LRTManager.sol";

/**
  * @title LRTEmergency
  * @author Steadefi
  * @notice Re-usable library functions for emergency operations for Steadefi leveraged vaults
*/
library LRTEmergency {

  using SafeERC20 for IERC20;

  /* ====================== CONSTANTS ======================== */

  uint256 public constant SAFE_MULTIPLIER = 1e18;
  uint256 public constant DUST_AMOUNT = 1e17;

  /* ======================== EVENTS ========================= */

  event EmergencyPaused();
  event EmergencyRepaid(uint256 repayTokenBAmt);
  event EmergencyBorrowed(uint256 borrowTokenBAmt);
  event EmergencyResumed();
  event EmergencyClosed();
  event EmergencyWithdraw(
    address indexed user,
    uint256 sharesAmt,
    address wntToken,
    uint256 wntTokenAmt,
    address rewardToken,
    uint256 rewardTokenAmt
  );
  event EmergencyStatusChanged(uint256 status);

  /* ================== MUTATIVE FUNCTIONS =================== */

  /**
    * @notice @inheritdoc LRTVault
    * @param self LRTTypes.Store
  */
  function emergencyPause(
    LRTTypes.Store storage self
  ) external {
    LRTChecks.beforeEmergencyPauseChecks(self);

    self.status = LRTTypes.Status.Paused;

    emit EmergencyPaused();
  }

  /**
    * @notice @inheritdoc LRTVault
    * @param self LRTTypes.Store
  */
  function emergencyRepay(
    LRTTypes.Store storage self
  ) external {
    LRTChecks.beforeEmergencyRepayChecks(self);

    self.status = LRTTypes.Status.Repay;

    // In most cases, the lrtAmt and LRT balance should be equal
    if (self.lrtAmt >= self.LRT.balanceOf(address(this))) {
      self.lrtAmt -= self.LRT.balanceOf(address(this));
    } else {
      // But in the event that there is more LRTs added, we set self.lrtAmt to 0
      self.lrtAmt = 0;
    }

    // Swap all LRT to WNT
    ISwap.SwapParams memory _sp;

    _sp.tokenIn = address(self.LRT);
    _sp.tokenOut = address(self.WNT);
    _sp.amountIn = self.LRT.balanceOf(address(this));
    _sp.slippage = self.swapSlippage;
    _sp.deadline = block.timestamp;

    LRTManager.swapExactTokensForTokens(self, _sp);

    // Calculate amount of tokenB to swap for to repay
    LRTTypes.RepayParams memory _rp;

    _rp.repayTokenBAmt = LRTManager.calcRepay(self, 1e18);

    // If tokenB is WNT, no swap needed
    // If not, we swap WNT for tokenB
    if (address(self.tokenB) != address(self.WNT)) {
      ISwap.SwapParams memory _sp2;

      _sp2.tokenIn = address(self.WNT);
      _sp2.tokenOut = address(self.tokenB);
      _sp2.amountIn = LRTManager.calcAmountInMaximum(
        self,
        address(self.WNT),
        address(self.tokenB),
        _rp.repayTokenBAmt,
        self.swapSlippage
      );
      _sp2.amountOut = _rp.repayTokenBAmt;
      _sp2.slippage = self.swapSlippage;
      _sp2.deadline = block.timestamp;

      // Swap WNT for tokenB
      LRTManager.swapTokensForExactTokens(self, _sp2);
    }

    // Repay
    LRTManager.repay(self, _rp.repayTokenBAmt);

    self.status = LRTTypes.Status.Repaid;

    emit EmergencyRepaid(_rp.repayTokenBAmt);
  }

  /**
    * @notice @inheritdoc LRTVault
    * @param self LRTTypes.Store
  */
  function emergencyBorrow(
    LRTTypes.Store storage self
  ) external {
    LRTChecks.beforeEmergencyBorrowChecks(self);

    // Re-borrow assets
    uint256 _depositValue = LRTReader.convertToUsdValue(
      self,
      address(self.WNT),
      self.WNT.balanceOf(address(this))
    );

    uint256 _borrowTokenBAmt = LRTManager.calcBorrow(self, _depositValue);

    LRTManager.borrow(self, _borrowTokenBAmt);

    // Swap borrowed token for WNT
    // If borrow in WNT, no swap needed
    if (address(self.tokenB) != address(self.WNT)) {
      ISwap.SwapParams memory _sp;

      _sp.tokenIn = address(self.tokenB);
      _sp.tokenOut = address(self.WNT);
      _sp.amountIn = _borrowTokenBAmt;
      _sp.slippage = self.swapSlippage;
      _sp.deadline = block.timestamp;

      LRTManager.swapExactTokensForTokens(self, _sp);
    }

    self.status = LRTTypes.Status.Paused;

    emit EmergencyBorrowed(_borrowTokenBAmt);
  }

  /**
    * @notice @inheritdoc LRTVault
    * @param self LRTTypes.Store
  */
  function emergencyResume(
    LRTTypes.Store storage self
  ) external {
    LRTChecks.beforeEmergencyResumeChecks(self);

    self.status = LRTTypes.Status.Resume;

    // Swap WNT to LRT
    ISwap.SwapParams memory _sp;

    _sp.tokenIn = address(self.WNT);
    _sp.tokenOut = address(self.LRT);
    _sp.amountIn = self.WNT.balanceOf(address(this));
    _sp.slippage = self.swapSlippage;
    _sp.deadline = block.timestamp;

    // Add to vault's total LRT amount
    self.lrtAmt = LRTManager.swapExactTokensForTokens(self, _sp);

    self.status = LRTTypes.Status.Open;

    emit EmergencyResumed();
  }

  /**
    * @notice @inheritdoc LRTVault
    * @param self LRTTypes.Store
  */
  function emergencyClose(
    LRTTypes.Store storage self
  ) external {
    LRTChecks.beforeEmergencyCloseChecks(self);

    self.status = LRTTypes.Status.Closed;

    emit EmergencyClosed();
  }

  /**
    * @notice @inheritdoc LRTVault
    * @param self LRTTypes.Store
  */
  function emergencyWithdraw(
    LRTTypes.Store storage self,
    uint256 shareAmt
  ) external {
    // check to ensure shares withdrawn does not exceed user's balance
    uint256 _userShareBalance = IERC20(address(self.vault)).balanceOf(msg.sender);

    // to avoid leaving dust behind
    unchecked {
      if (_userShareBalance - shareAmt < DUST_AMOUNT) {
        shareAmt = _userShareBalance;
      }
    }

    LRTChecks.beforeEmergencyWithdrawChecks(self, shareAmt);

    // share ratio calculation must be before burn()
    uint256 _shareRatio = shareAmt
      * SAFE_MULTIPLIER
      / IERC20(address(self.vault)).totalSupply();

    self.vault.burn(msg.sender, shareAmt);

    uint256 _withdrawAmtWNT = _shareRatio
      * self.WNT.balanceOf(address(this))
      / SAFE_MULTIPLIER;

    // Send WNT back to withdrawer
    self.WNT.withdraw(_withdrawAmtWNT);
    (bool success, ) = msg.sender.call{
      value: _withdrawAmtWNT
    }("");
    // if native transfer unsuccessful, send WNT back to user
    if (!success) {
      self.WNT.deposit{value: _withdrawAmtWNT}();
      IERC20(address(self.WNT)).safeTransfer(
        msg.sender,
        _withdrawAmtWNT
      );
    }

    // Proportionately distribute reward tokens based on share ratio
    uint256 _withdrawAmtRewardToken;
    if (address(self.rewardToken) != address(0)) {
      _withdrawAmtRewardToken = _shareRatio
        * self.rewardToken.balanceOf(address(this))
        / SAFE_MULTIPLIER;

      self.rewardToken.safeTransfer(msg.sender, _withdrawAmtRewardToken);
    }

    emit EmergencyWithdraw(
      msg.sender,
      shareAmt,
      address(self.WNT),
      _withdrawAmtWNT,
      address(self.rewardToken),
      _withdrawAmtRewardToken
    );
  }

  /**
    * @notice @inheritdoc LRTVault
    * @param self LRTTypes.Store
  */
  function emergencyStatusChange(
    LRTTypes.Store storage self,
    LRTTypes.Status status
  ) external {
    LRTChecks.beforeEmergencyStatusChangeChecks(self);

    self.status = status;

    emit EmergencyStatusChanged(uint256(status));
  }
}
