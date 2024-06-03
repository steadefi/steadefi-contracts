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
  * @title LRTDeposit
  * @author Steadefi
  * @notice Re-usable library functions for deposit operations for Steadefi leveraged vaults
*/
library LRTDeposit {

  using SafeERC20 for IERC20;

  /* ======================= CONSTANTS ======================= */

  uint256 public constant SAFE_MULTIPLIER = 1e18;

  /* ======================== EVENTS ========================= */

  event DepositCompleted(
    address indexed user,
    uint256 shareAmt,
    uint256 equityBefore,
    uint256 equityAfter
  );

  /* ================== MUTATIVE FUNCTIONS =================== */

  /**
    * @notice @inheritdoc GMXVault
    * @param self LRTTypes.Store
    * @param isNative Boolean as to whether user is depositing native asset (e.g. ETH, AVAX, etc.)
  */
  function deposit(
    LRTTypes.Store storage self,
    LRTTypes.DepositParams memory dp,
    bool isNative
  ) external {
    LRTTypes.DepositCache memory _dc;

    _dc.user = payable(msg.sender);

    LRTTypes.HealthParams memory _hp;

    _hp.equityBefore = LRTReader.equityValue(self);
    _hp.lrtAmtBefore = LRTReader.lrtAmt(self);
    _hp.debtRatioBefore = LRTReader.debtRatio(self);
    _hp.deltaBefore = LRTReader.delta(self);

    _dc.healthParams = _hp;
    _dc.depositParams = dp;

    // Transfer deposited assets from user to vault
    if (isNative) {
      LRTChecks.beforeNativeDepositChecks(self, dp);

      self.WNT.deposit{ value: dp.amt }();
    } else {
      IERC20(dp.token).safeTransferFrom(msg.sender, address(this), dp.amt);
    }

    // If LRT deposited, no swap needed; simply add it to LRT amt in depositCache
    // If deposited is not LRT/WNT/USDC, we swap it for WNT and get the depositValue
    // If deposited is WNT, we store the amt in a variable to be added on later to swap to LRT
    uint256 wntToSwapToLRTAmt;

    if (dp.token != address(self.LRT) && dp.token != address(self.WNT)) {
      // If user deposited any accepted token that isn't WNT/LRT
      // e.g. wstETH, USDC

      ISwap.SwapParams memory _sp;

      _sp.tokenIn = dp.token;
      _sp.tokenOut = address(self.WNT);
      _sp.amountIn = dp.amt;
      _sp.slippage = self.swapSlippage;
      _sp.deadline = dp.deadline;

      // Replace the deposit params with swapped values
      wntToSwapToLRTAmt = LRTManager.swapExactTokensForTokens(self, _sp);

      _dc.depositValue = LRTReader.convertToUsdValue(
        self,
        address(self.WNT),
        wntToSwapToLRTAmt
      );
    } else if (dp.token == address(self.LRT)) {
       // If user deposited LRT

       _dc.lrtAmt = dp.amt;

      _dc.depositValue = LRTReader.convertToUsdValue(
        self,
        address(self.LRT),
        dp.amt
      );
    } else {
      // If user deposited WNT

      wntToSwapToLRTAmt = dp.amt;

      _dc.depositValue = LRTReader.convertToUsdValue(
        self,
        address(dp.token),
        dp.amt
      );
    }

    self.depositCache = _dc;

    LRTChecks.beforeDepositChecks(self, _dc.depositValue);

    // Calculate minimum amount of shares expected based on deposit value
    // and vault slippage value passed in. We calculate this after `beforeDepositChecks()`
    // to ensure the vault slippage passed in meets the `minVaultSlippage`
    _dc.minSharesAmt = LRTReader.valueToShares(
      self,
      _dc.depositValue,
      _dc.healthParams.equityBefore
    ) * (10000 - dp.slippage) / 10000;

    // Borrow assets and restake/swap for LRT
    uint256 _borrowTokenBAmt = LRTManager.calcBorrow(self, _dc.depositValue);

    _dc.borrowParams.borrowTokenBAmt = _borrowTokenBAmt;

    LRTManager.borrow(self, _borrowTokenBAmt);

    // Swap borrowed token for WNT first
    // If borrow in WNT, no swap needed
    if (address(self.tokenB) != address(self.WNT)) {
      ISwap.SwapParams memory _sp2;

      _sp2.tokenIn = address(self.tokenB);
      _sp2.tokenOut = address(self.WNT);
      _sp2.amountIn = _borrowTokenBAmt;
      _sp2.slippage = self.swapSlippage;
      _sp2.deadline = dp.deadline;

      wntToSwapToLRTAmt += LRTManager.swapExactTokensForTokens(self, _sp2);
    } else {
      wntToSwapToLRTAmt += _borrowTokenBAmt;
    }

    // Swap WNT for LRT
    ISwap.SwapParams memory _sp3;

    _sp3.tokenIn = address(self.WNT);
    _sp3.tokenOut = address(self.LRT);
    _sp3.amountIn = wntToSwapToLRTAmt;
    _sp3.slippage = self.swapSlippage;
    _sp3.deadline = dp.deadline;

    _dc.lrtAmt += LRTManager.swapExactTokensForTokens(self, _sp3);

    // Add to vault's total LRT amount
    self.lrtAmt += _dc.lrtAmt;

    // Store equityAfter and shareToUser values in DepositCache
    _dc.healthParams.equityAfter = LRTReader.equityValue(self);

    _dc.sharesToUser = LRTReader.valueToShares(
      self,
      _dc.healthParams.equityAfter - _dc.healthParams.equityBefore,
      _dc.healthParams.equityBefore
    );

    self.depositCache = _dc;

    LRTChecks.afterDepositChecks(self);

    self.vault.mintFee();

    // Mint shares to depositor
    self.vault.mint(_dc.user, _dc.sharesToUser);

    emit DepositCompleted(
      _dc.user,
      _dc.sharesToUser,
      _dc.healthParams.equityBefore,
      _dc.healthParams.equityAfter
    );
  }
}
