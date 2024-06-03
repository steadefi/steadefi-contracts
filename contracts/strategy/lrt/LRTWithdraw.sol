// SPDX-License-Identifier: MIT
pragma solidity 0.8.21;

import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { IERC20Metadata } from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import { SafeERC20 } from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import { ISwap } from  "../../interfaces/swap/ISwap.sol";
import { LRTTypes } from "./LRTTypes.sol";
import { LRTReader } from "./LRTReader.sol";
import { LRTChecks } from "./LRTChecks.sol";
import { LRTManager } from "./LRTManager.sol";

/**
  * @title LRTWithdraw
  * @author Steadefi
  * @notice Re-usable library functions for withdraw operations for Steadefi leveraged vaults
*/
library LRTWithdraw {

  using SafeERC20 for IERC20;

  /* ====================== CONSTANTS ======================== */

  uint256 public constant SAFE_MULTIPLIER = 1e18;

  /* ======================== EVENTS ========================= */

  event WithdrawCompleted(
    address indexed user,
    address token,
    uint256 tokenAmt
  );

  /* ================== MUTATIVE FUNCTIONS =================== */

  /**
    * @notice @inheritdoc LRTVault
    * @param self LRTTypes.Store
  */
  function withdraw(
    LRTTypes.Store storage self,
    LRTTypes.WithdrawParams memory wp
  ) external {
    LRTTypes.WithdrawCache memory _wc;

    _wc.user = payable(msg.sender);

    LRTTypes.HealthParams memory _hp;

    _hp.equityBefore = LRTReader.equityValue(self);
    _hp.lrtAmtBefore = LRTReader.lrtAmt(self);
    _hp.debtRatioBefore = LRTReader.debtRatio(self);
    _hp.deltaBefore = LRTReader.delta(self);

    _wc.healthParams = _hp;

    // Mint fee before calculating shareRatio for correct totalSupply
    self.vault.mintFee();

    // Calculate user share ratio
    _wc.shareRatio = wp.shareAmt
      * SAFE_MULTIPLIER
      / IERC20(address(self.vault)).totalSupply();
    _wc.lrtAmt = _wc.shareRatio
      * LRTReader.lrtAmt(self)
      / SAFE_MULTIPLIER;

    _wc.withdrawValue = LRTReader.convertToUsdValue(
      self,
      address(self.LRT),
      _wc.lrtAmt
    );

    _wc.withdrawParams = wp;

    self.withdrawCache = _wc;

    LRTChecks.beforeWithdrawChecks(self);

    // Calculate minimum amount of assets expected based on shares to burn
    // and vault slippage value passed in. We calculate this after `beforeWithdrawChecks()`
    // to ensure the vault slippage passed in meets the `minVaultSlippage`.
    // minAssetsAmt = userVaultSharesAmt * vaultSvTokenValue / assetToReceiveValue x slippage
    _wc.minAssetsAmt = wp.shareAmt
      * LRTReader.svTokenValue(self)
      / self.chainlinkOracle.consultIn18Decimals(address(self.WNT))
      * (10000 - wp.slippage) / 10000;

    // minAssetsAmt is in 1e18. If asset decimals is less than 18, e.g. USDC,
    // we need to normalize the decimals of minAssetsAmt
    if (IERC20Metadata(address(self.WNT)).decimals() < 18)
      _wc.minAssetsAmt /= 10 ** (18 - IERC20Metadata(address(self.WNT)).decimals());

    // Burn user shares
    self.vault.burn(
      self.withdrawCache.user,
      self.withdrawCache.withdrawParams.shareAmt
    );

    // Account LP tokens removed from vault
    self.lrtAmt -= _wc.lrtAmt;

    // Swap LRT to WNT
    ISwap.SwapParams memory _sp;

    _sp.tokenIn = address(self.LRT);
    _sp.tokenOut = address(self.WNT);
    _sp.amountIn = _wc.lrtAmt;
    _sp.slippage = self.swapSlippage;
    _sp.deadline = wp.deadline;

    uint256 _wntAmt = LRTManager.swapExactTokensForTokens(self, _sp);

    // Calculate amount of WNT to swap tokenB for to repay
    _wc.repayParams.repayTokenBAmt = LRTManager.calcRepay(self, _wc.shareRatio);

    // If tokenB is WNT, no swap needed
    // If not, we swap WNT for tokenB
    uint256 _wntAmtInSwapped;

    if (address(self.tokenB) != address(self.WNT)) {
      ISwap.SwapParams memory _sp2;

      _sp2.tokenIn = address(self.WNT);
      _sp2.tokenOut = address(self.tokenB);
      _sp2.amountIn = LRTManager.calcAmountInMaximum(
        self,
        address(self.WNT),
        address(self.tokenB),
        _wc.repayParams.repayTokenBAmt,
        wp.slippage
      );
      _sp2.amountOut = _wc.repayParams.repayTokenBAmt;
      _sp2.slippage = self.swapSlippage;
      _sp2.deadline = wp.deadline;

      _wntAmtInSwapped = LRTManager.swapTokensForExactTokens(self, _sp2);
    } else {
      _wntAmtInSwapped = _wc.repayParams.repayTokenBAmt;
    }

    // Repay
    LRTManager.repay(
      self,
      _wc.repayParams.repayTokenBAmt
    );

    // Calculate amount of WNT to send to withdrawer
    _wc.assetsToUser = _wntAmt - _wntAmtInSwapped;

    _wc.healthParams.equityAfter = LRTReader.equityValue(self);

    self.withdrawCache = _wc;

    LRTChecks.afterWithdrawChecks(self);

    // Send WNT back to withdrawer
    self.WNT.withdraw(_wc.assetsToUser);
    (bool success, ) = _wc.user.call{
      value: _wc.assetsToUser
    }("");
    // if native transfer unsuccessful, send ERC20 back to user
    if (!success) {
      self.WNT.deposit{value: _wc.assetsToUser}();
      IERC20(address(self.WNT)).safeTransfer(
        _wc.user,
        _wc.assetsToUser
      );
    }

    emit WithdrawCompleted(
      _wc.user,
      address(self.WNT),
      _wc.assetsToUser
    );
  }
}
