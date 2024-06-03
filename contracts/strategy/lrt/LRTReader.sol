// SPDX-License-Identifier: MIT
pragma solidity 0.8.21;

import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { IERC20Metadata } from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import { SafeCast } from "@openzeppelin/contracts/utils/math/SafeCast.sol";
import { LRTTypes } from "./LRTTypes.sol";

/**
  * @title LRTReader
  * @author Steadefi
  * @notice Re-usable library functions for reading data and values for Steadefi leveraged vaults
*/
library LRTReader {

  using SafeCast for uint256;

  /* =================== CONSTANTS FUNCTIONS ================= */

  uint256 public constant SAFE_MULTIPLIER = 1e18;

  /* ===================== VIEW FUNCTIONS ==================== */

  /**
    * @notice @inheritdoc LRTVault
    * @param self LRTTypes.Store
  */
  function svTokenValue(LRTTypes.Store storage self) public view returns (uint256) {
    uint256 equityValue_ = equityValue(self);
    uint256 totalSupply_ = IERC20(address(self.vault)).totalSupply();
    return equityValue_ * SAFE_MULTIPLIER / (totalSupply_ + pendingFee(self));
  }

  /**
    * @notice @inheritdoc LRTVault
    * @param self LRTTypes.Store
  */
  function pendingFee(LRTTypes.Store storage self) public view returns (uint256) {
    uint256 totalSupply_ = IERC20(address(self.vault)).totalSupply();
    uint256 _secondsFromLastCollection = block.timestamp - self.lastFeeCollected;
    return (totalSupply_ * self.feePerSecond * _secondsFromLastCollection) / SAFE_MULTIPLIER;
  }

  /**
    * @notice @inheritdoc LRTVault
    * @param self LRTTypes.Store
  */
  function valueToShares(
    LRTTypes.Store storage self,
    uint256 value,
    uint256 currentEquity
  ) public view returns (uint256) {
    uint256 _sharesSupply = IERC20(address(self.vault)).totalSupply() + pendingFee(self);
    if (_sharesSupply == 0 || currentEquity == 0) return value;
    return value * _sharesSupply / currentEquity;
  }

  /**
    * @notice @inheritdoc LRTVault
    * @param self LRTTypes.Store
  */
  function convertToUsdValue(
    LRTTypes.Store storage self,
    address token,
    uint256 amt
  ) public view returns (uint256) {
    return (amt * self.chainlinkOracle.consultIn18Decimals(token))
      / (10 ** IERC20Metadata(token).decimals());
  }

  /**
    * @notice @inheritdoc LRTVault
    * @param self LRTTypes.Store
  */
  function assetValue(LRTTypes.Store storage self) public view returns (uint256) {
    return convertToUsdValue(
      self,
      address(self.LRT),
      lrtAmt(self)
    );
  }

  /**
    * @notice @inheritdoc LRTVault
    * @param self LRTTypes.Store
  */
  function debtValue(LRTTypes.Store storage self) public view returns (uint256) {
    uint256 _tokenBDebtAmt = debtAmt(self);
    return convertToUsdValue(self, address(self.tokenB), _tokenBDebtAmt);
  }

  /**
    * @notice @inheritdoc LRTVault
    * @param self LRTTypes.Store
  */
  function equityValue(LRTTypes.Store storage self) public view returns (uint256) {
    uint256 _assetValue = assetValue(self);
    uint256 _debtValue = debtValue(self);

    // in underflow condition return 0
    unchecked {
      if (_assetValue < _debtValue) return 0;
      return _assetValue - _debtValue;
    }
  }

  /**
    * @notice @inheritdoc LRTVault
    * @param self LRTTypes.Store
  */
  function assetAmt(LRTTypes.Store storage self) public view returns (uint256) {
    return lrtAmt(self);
  }

  /**
    * @notice @inheritdoc LRTVault
    * @param self LRTTypes.Store
  */
  function debtAmt(LRTTypes.Store storage self) public view returns (uint256) {
    return self.tokenBLendingVault.maxRepay(address(self.vault));
  }

  /**
    * @notice @inheritdoc LRTVault
    * @param self LRTTypes.Store
  */
  function lrtAmt(LRTTypes.Store storage self) public view returns (uint256) {
    return self.lrtAmt;
  }

  /**
    * @notice @inheritdoc LRTVault
    * @param self LRTTypes.Store
  */
  function leverage(LRTTypes.Store storage self) public view returns (uint256) {
    if (assetValue(self) == 0 || equityValue(self) == 0) return 0;
    return assetValue(self) * SAFE_MULTIPLIER / equityValue(self);
  }

  /**
    * @notice @inheritdoc LRTVault
    * @param self LRTTypes.Store
  */
  function delta(LRTTypes.Store storage self) public view returns (int256) {
    uint256 _lrtAmt = assetAmt(self);
    uint256 _tokenBDebtAmt = debtAmt(self);
    uint256 equityValue_ = equityValue(self);

    if (_lrtAmt == 0 && _tokenBDebtAmt == 0) return 0;
    if (equityValue_ == 0) return 0;

    bool _isPositive = _lrtAmt >= _tokenBDebtAmt;

    uint256 _unsignedDelta = _isPositive ?
      _lrtAmt - _tokenBDebtAmt :
      _tokenBDebtAmt - _lrtAmt;

    int256 signedDelta = (_unsignedDelta
      * self.chainlinkOracle.consultIn18Decimals(address(self.tokenB))
      / equityValue_).toInt256();

    if (_isPositive) return signedDelta;
    else return -signedDelta;
  }

  /**
    * @notice @inheritdoc LRTVault
    * @param self LRTTypes.Store
  */
  function debtRatio(LRTTypes.Store storage self) public view returns (uint256) {
    uint256 _tokenBDebtValue = debtValue(self);
    if (assetValue(self) == 0) return 0;
    return _tokenBDebtValue * SAFE_MULTIPLIER / assetValue(self);
  }

  /**
    * @notice @inheritdoc LRTVault
    * @param self LRTTypes.Store
  */
  function additionalCapacity(LRTTypes.Store storage self) public view returns (uint256) {
    uint256 _additionalCapacity;

    // As LRT strategies only borrow 1 asset, Delta Long and Neutral
    // both have similar calculation processes
    if (
      self.delta == LRTTypes.Delta.Long ||
      self.delta == LRTTypes.Delta.Neutral
    ) {
      _additionalCapacity = convertToUsdValue(
        self,
        address(self.tokenB),
        self.tokenBLendingVault.totalAvailableAsset()
      ) * SAFE_MULTIPLIER / (self.leverage - 1e18);
    }

    return _additionalCapacity;
  }

  /**
    * @notice @inheritdoc LRTVault
    * @param self LRTTypes.Store
  */
  function capacity(LRTTypes.Store storage self) public view returns (uint256) {
    return additionalCapacity(self) + equityValue(self);
  }
}
