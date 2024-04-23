// SPDX-License-Identifier: MIT
pragma solidity 0.8.21;

import { ERC20 } from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { SafeERC20 } from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import { ReentrancyGuard } from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import { Pausable } from "@openzeppelin/contracts/utils/Pausable.sol";
import { AccessManaged } from "@openzeppelin/contracts/access/manager/AccessManaged.sol";
import { EnumerableSet } from "@openzeppelin/contracts/utils/structs/EnumerableSet.sol";
import { ILendingVault } from "../../interfaces/v2/lending/ILendingVault.sol";
import { IWNT } from "../interfaces/tokens/IWNT.sol";
import { Errors } from "../utils/Errors.sol";

contract LendingVault is ERC20, ReentrancyGuard, Pausable, AccessManaged, ILendingVault {

  using SafeERC20 for IERC20;
  using EnumerableSet for EnumerableSet.AddressSet;

  /* ====================== CONSTANTS ======================== */

  uint256 public constant SAFE_MULTIPLIER = 1e18;
  uint256 public constant SECONDS_PER_YEAR = 365 days;

  /* ==================== STATE VARIABLES ==================== */

  // Vault's underlying asset
  IERC20 public asset;
  // Is asset native ETH
  bool public isNativeAsset;
  // Protocol treasury address
  address public treasury;
  // Amount borrowed from this vault
  uint256 public totalBorrows;
  // Total borrow shares in this vault
  uint256 public totalBorrowDebt;
  // The fee % applied to interest earned that goes to the protocol in 1e18
  uint256 public performanceFee;
  // Protocol earnings reserved in this vault
  uint256 public vaultReserves;
  // Last updated timestamp of this vault
  uint256 public lastUpdatedAt;
  // Max capacity of vault in asset decimals / amt
  uint256 public maxCapacity;

  /* ==================== ENUMERABLE SETS ==================== */

  // Array of approved borrower addresses for this lending vault
  EnumerableSet.AddressSet private _approvedBorrowers;

  /* ======================= MAPPINGS ======================== */

  // Mapping of borrowers to borrowers struct
  mapping(address => Borrower) public borrowers;
  // Mapping of borrowers to their interest rate model
  mapping(address => InterestRate) public interestRates;
  // Mapping of borrowers to their maximum interest rate model
  mapping(address => InterestRate) public maxInterestRates;

  /* ======================== EVENTS ========================= */

  event Deposit(address indexed depositor, uint256 sharesAmt, uint256 depositAmt);
  event Withdraw(address indexed withdrawer, uint256 sharesAmt, uint256 withdrawAmt);
  event Borrow(address indexed borrower, uint256 borrowDebt, uint256 borrowAmt);
  event Repay(address indexed borrower, uint256 repayDebt, uint256 repayAmt);
  event PerformanceFeeUpdated(
    address indexed caller,
    uint256 previousPerformanceFee,
    uint256 newPerformanceFee
  );
  event UpdateMaxCapacity(uint256 maxCapacity);
  event EmergencyPause(address indexed guardian);
  event EmergencyResume(address indexed guardian);
  event UpdateInterestRate(
    address borrower,
    uint256 baseRate,
    uint256 multiplier,
    uint256 jumpMultiplier,
    uint256 kink1,
    uint256 kink2
  );
  event UpdateMaxInterestRate(
    address borrower,
    uint256 baseRate,
    uint256 multiplier,
    uint256 jumpMultiplier,
    uint256 kink1,
    uint256 kink2
  );

  /* ======================= MODIFIERS ======================= */

  /**
    * @notice Allow only approved borrower addresses
  */
  modifier onlyBorrower() {
    _onlyBorrower();
    _;
  }

  /* ====================== CONSTRUCTOR ====================== */

  /**
    * @param _name  Name for this lending vault, e.g. Interest Bearing AVAX
    * @param _symbol  Symbol for this lending vault, e.g. ibAVAX-AVAXUSDC-GMX
    * @param _asset  Contract address for underlying ERC20 asset
    * @param _isNativeAsset  Whether vault asset is native or not
    * @param _performanceFee  Performance fee in 1e18
    * @param _maxCapacity Max capacity of lending vault in asset decimals
    * @param _treasury  Contract address for protocol treasury
    * @param _accessManager Address of access manager
  */
  constructor(
    string memory _name,
    string memory _symbol,
    IERC20 _asset,
    bool _isNativeAsset,
    uint256 _performanceFee,
    uint256 _maxCapacity,
    address _treasury,
    address _accessManager
  ) ERC20(_name, _symbol) AccessManaged(_accessManager) {
    if (address(_asset) == address(0)) revert Errors.ZeroAddressNotAllowed();
    if (_treasury == address(0)) revert Errors.ZeroAddressNotAllowed();
    if (ERC20(address(_asset)).decimals() > 18) revert Errors.TokenDecimalsMustBeLessThan18();

    asset = _asset;
    isNativeAsset = _isNativeAsset;
    performanceFee = _performanceFee;
    maxCapacity = _maxCapacity;
    treasury = _treasury;
  }

  /* ===================== VIEW FUNCTIONS ==================== */

  /**
    * @notice Returns the total value of the lending vault, i.e totalBorrows + interest + totalAvailableAsset
    * @return Value of lending vault in token decimals
  */
  function totalAsset() public view returns (uint256) {
    return totalBorrows + _pendingInterests(0) + totalAvailableAsset();
  }

  /**
    * @notice Returns the available balance of asset in the vault that is borrowable
    * @return Balance of asset in the vault in token decimals
  */
  function totalAvailableAsset() public view returns (uint256) {
    return asset.balanceOf(address(this));
  }

  /**
    * @notice Returns the the borrow utilization rate of the vault
    * @return Ratio of borrows to total liquidity in 1e18
  */
  function utilizationRate() public view returns (uint256){
    uint256 totalAsset_ = totalAsset();

    return (totalAsset_ == 0) ? 0 : totalBorrows * SAFE_MULTIPLIER / totalAsset_;
  }

  /**
    * @notice Returns the exchange rate for lvToken to asset
    * @return Ratio of lvToken to underlying asset in token decimals
  */
  function lvTokenValue() public view returns (uint256) {
    uint256 totalAsset_ = totalAsset();
    uint256 totalSupply_ = totalSupply();

    if (totalAsset_ == 0 || totalSupply_ == 0) {
      return 1 * (10 ** ERC20(address(asset)).decimals());
    } else {
      return totalAsset_ * SAFE_MULTIPLIER / totalSupply_;
    }
  }

  /**
    * @notice Returns the borrow APR for a specific borrower
    * @param borrower Address of borrower
    * @return Current borrow rate for a borrower in 1e18
  */
  function borrowAPRPerBorrower(address borrower) public view returns (uint256) {
    uint256 _borrowerDebtAmt = borrowers[borrower].debt;
    return _calculateInterestRate(borrower, _borrowerDebtAmt, totalAvailableAsset());
  }

  /**
    * @notice Returns the weighted average borrow APR for this vault
    * @return Current borrow rate on aggregate/average in 1e18
  */
  function borrowAPR() public view returns (uint256) {
    uint256 _borrowAPR;

    for (uint256 i = 0; i < _approvedBorrowers.length(); i++) {
      address _borrower = _approvedBorrowers.at(i);
      uint256 _borrowAPRPerBorrower = borrowAPRPerBorrower(_borrower);

      if (_borrowAPRPerBorrower > 0) {
        _borrowAPR += _borrowAPRPerBorrower * borrowers[_borrower].debt / totalBorrows;
      }
    }

    return _borrowAPR;
  }

  /**
    * @notice Returns the current lending APR; borrowAPR * utilization * (1 - performanceFee)
    * @return Current lending rate in 1e18
  */
  function lendingAPR() public view returns (uint256) {
    uint256 borrowAPR_ = borrowAPR();
    uint256 utilizationRate_ = utilizationRate();

    if (borrowAPR_ == 0 || utilizationRate_ == 0) {
      return 0;
    } else {
      return borrowAPR_ * utilizationRate_
                         / SAFE_MULTIPLIER
                         * ((1 * SAFE_MULTIPLIER) - performanceFee)
                         / SAFE_MULTIPLIER;
    }
  }

  /**
    * @notice Returns a borrower's maximum total repay amount taking into account ongoing interest
    * @param borrower Borrower's address
    * @return Borrower's total repay amount of assets in assets decimals
  */
  function maxRepay(address borrower) public view returns (uint256) {
    if (totalBorrows == 0) {
      return 0;
    } else {
      return borrowers[borrower].debt * (totalBorrows + _pendingInterest(borrower, 0)) / totalBorrowDebt;
    }
  }

  /**
    * @notice Check if a borrower is approved
    * @param borrower Borrower's address
    * @return on whether borrower is approved in this lending vault or not
  */
  function approvedBorrower(address borrower) public view returns (bool) {
    return _approvedBorrowers.contains(borrower);
  }

  /**
    * @notice List of approved borrower addresses
    * @return of approved borrower addresses
  */
  function approvedBorrowers() public view returns (address[] memory) {
    return _approvedBorrowers.values();
  }

  /* ================== MUTATIVE FUNCTIONS =================== */

  /**
    * @notice Deposits native asset into lending vault and mint shares to user
    * @param assetAmt Amount of asset tokens to deposit in token decimals
    * @param minSharesAmt Minimum amount of lvTokens tokens to receive on deposit
  */
  function depositNative(uint256 assetAmt, uint256 minSharesAmt) payable public nonReentrant whenNotPaused {
    if (msg.value == 0) revert Errors.EmptyDepositAmount();
    if (assetAmt != msg.value) revert Errors.InvalidNativeDepositAmountValue();
    if (assetAmt + totalAsset() > maxCapacity) revert Errors.InsufficientCapacity();
    if (assetAmt == 0) revert Errors.InsufficientDepositAmount();

    IWNT(address(asset)).deposit{ value: msg.value }();

    // Update vault with accrued interest and latest timestamp
    _updateVaultWithInterestsAndTimestamp(assetAmt);

    uint256 _sharesAmount = _mintShares(assetAmt);

    if (_sharesAmount < minSharesAmt) revert Errors.InsufficientSharesMinted();

    emit Deposit(msg.sender, _sharesAmount, assetAmt);
  }

  /**
    * @notice Deposits asset into lending vault and mint shares to user
    * @param assetAmt Amount of asset tokens to deposit in token decimals
    * @param minSharesAmt Minimum amount of lvTokens tokens to receive on deposit
  */
  function deposit(uint256 assetAmt, uint256 minSharesAmt) public nonReentrant whenNotPaused {
    if (assetAmt + totalAsset() > maxCapacity) revert Errors.InsufficientCapacity();
    if (assetAmt == 0) revert Errors.InsufficientDepositAmount();

    asset.safeTransferFrom(msg.sender, address(this), assetAmt);

    // Update vault with accrued interest and latest timestamp
    _updateVaultWithInterestsAndTimestamp(assetAmt);

    uint256 _sharesAmount = _mintShares(assetAmt);

    if (_sharesAmount < minSharesAmt) revert Errors.InsufficientSharesMinted();

    emit Deposit(msg.sender, _sharesAmount, assetAmt);
  }

  /**
    * @notice Withdraws asset from lending vault, burns lvToken from user
    * @param sharesAmt Amount of lvTokens to burn in 1e18
    * @param minAssetAmt Minimum amount of asset tokens to receive on withdrawal
  */
  function withdraw(uint256 sharesAmt, uint256 minAssetAmt) public nonReentrant {
    if (sharesAmt == 0) revert Errors.InsufficientWithdrawAmount();
    if (sharesAmt > balanceOf(msg.sender)) revert Errors.InsufficientWithdrawBalance();

    // Update vault with accrued interest and latest timestamp
    _updateVaultWithInterestsAndTimestamp(0);

    uint256 _assetAmt = _burnShares(sharesAmt);

    if (_assetAmt > totalAvailableAsset()) revert Errors.InsufficientAssetsBalance();
    if (_assetAmt < minAssetAmt) revert Errors.InsufficientAssetsReceived();

    if (isNativeAsset) {
      IWNT(address(asset)).withdraw(_assetAmt);
      (bool success, ) = msg.sender.call{value: _assetAmt}("");
      require(success, "Transfer failed.");
    } else {
      asset.safeTransfer(msg.sender, _assetAmt);
    }

    emit Withdraw(msg.sender, sharesAmt, _assetAmt);
  }

  /**
    * @notice Borrow asset from lending vault, adding debt
    * @param borrowAmt Amount of tokens to borrow in token decimals
  */
  function borrow(uint256 borrowAmt) external nonReentrant whenNotPaused onlyBorrower {
    if (borrowAmt == 0) revert Errors.InsufficientBorrowAmount();
    if (borrowAmt > totalAvailableAsset()) revert Errors.InsufficientLendingLiquidity();

    // Update vault with accrued interest and latest timestamp
    _updateVaultWithInterestsAndTimestamp(0);

    // Calculate debt amount
    uint256 _debt = totalBorrows == 0 ? borrowAmt : borrowAmt * totalBorrowDebt / totalBorrows;

    // Update vault state
    totalBorrows = totalBorrows + borrowAmt;
    totalBorrowDebt = totalBorrowDebt + _debt;

    // Update borrower state
    Borrower storage borrower = borrowers[msg.sender];
    borrower.debt = borrower.debt + _debt;
    borrower.lastUpdatedAt = block.timestamp;

    // Transfer borrowed token from vault to manager
    asset.safeTransfer(msg.sender, borrowAmt);

    emit Borrow(msg.sender, _debt, borrowAmt);
  }

  /**
    * @notice Repay asset to lending vault, reducing debt
    * @param repayAmt Amount of debt to repay in token decimals
  */
  function repay(uint256 repayAmt) external nonReentrant {
    if (repayAmt == 0) revert Errors.InsufficientRepayAmount();
    // Update vault with accrued interest and latest timestamp
    _updateVaultWithInterestsAndTimestamp(0);

    uint256 maxRepay_ = maxRepay(msg.sender);
    if (maxRepay_ > 0) {
      if (repayAmt > maxRepay_) {
        repayAmt = maxRepay_;
      }

      // Calculate debt to reduce based on repay amount
      uint256 _debt = repayAmt * borrowers[msg.sender].debt / maxRepay_;

      // Update vault state
      totalBorrows = totalBorrows - repayAmt;
      totalBorrowDebt = totalBorrowDebt - _debt;

      // Update borrower state
      borrowers[msg.sender].debt = borrowers[msg.sender].debt - _debt;
      borrowers[msg.sender].lastUpdatedAt = block.timestamp;

      // Transfer repay tokens to the vault
      asset.safeTransferFrom(msg.sender, address(this), repayAmt);

      emit Repay(msg.sender, _debt, repayAmt);
    }
  }

  /**
  * @notice Withdraw protocol fees from reserves to treasury
  * @param assetAmt  Amount to withdraw in token decimals
  */
  function withdrawReserve(uint256 assetAmt) external nonReentrant restricted {
    // Update vault with accrued interest and latest timestamp
    _updateVaultWithInterestsAndTimestamp(0);

    if (assetAmt > vaultReserves) assetAmt = vaultReserves;

    unchecked {
      vaultReserves = vaultReserves - assetAmt;
    }

    asset.safeTransfer(treasury, assetAmt);
  }

  /* ================== INTERNAL FUNCTIONS =================== */

  /**
    * @notice Allow only approved borrower addresses
  */
  function _onlyBorrower() internal view {
    if (!_approvedBorrowers.contains(msg.sender)) revert Errors.OnlyBorrowerAllowed();
  }

  /**
    * @notice Calculate amount of lvTokens owed to depositor and mints them
    * @param assetAmt  Amount of asset to deposit in token decimals
    * @return Amount of lvTokens minted in 1e18
  */
  function _mintShares(uint256 assetAmt) internal returns (uint256) {
    uint256 _shares;

    if (totalSupply() == 0) {
      _shares = assetAmt * _to18ConversionFactor();
    } else {
      _shares = assetAmt * totalSupply() / (totalAsset() - assetAmt);
    }

    // Mint lvToken to user equal to liquidity share amount
    _mint(msg.sender, _shares);

    return _shares;
  }

  /**
    * @notice Calculate amount of asset owed to depositor based on lvTokens burned
    * @param sharesAmt Amount of shares to burn in 1e18
    * @return Amount of assets withdrawn based on lvTokens burned in token decimals
  */
  function _burnShares(uint256 sharesAmt) internal returns (uint256) {
    // Calculate amount of assets to withdraw based on shares to burn
    uint256 totalSupply_ = totalSupply();
    uint256 _withdrawAmount = totalSupply_ == 0 ? 0 : sharesAmt * totalAsset() / totalSupply_;

    // Burn user's lvTokens
    _burn(msg.sender, sharesAmt);

    return _withdrawAmount;
  }

  /**
    * @notice Interest accrual function that calculates accumulated interest from lastUpdatedTimestamp and add to totalBorrows
    * @param assetAmt Additonal amount of assets being deposited in token decimals
  */
  function _updateVaultWithInterestsAndTimestamp(uint256 assetAmt) internal {
    uint256 _interest = _pendingInterests(assetAmt);
    uint256 _toReserve = _interest * performanceFee / SAFE_MULTIPLIER;

    vaultReserves = vaultReserves + _toReserve;
    totalBorrows = totalBorrows + _interest;
    lastUpdatedAt = block.timestamp;
  }

  /**
    * @notice Returns the pending interest from a borrower that will be accrued to the reserves in the next call
    * @param borrower Address of borrower
    * @param assetAmt Newly deposited assets to be subtracted off total available liquidity in token decimals
    * @return Amount of interest owned in token decimals
  */
  function _pendingInterest(address borrower, uint256 assetAmt) internal view returns (uint256) {
    if (totalBorrows == 0) return 0;

    uint256 totalAvailableAsset_ = totalAvailableAsset();
    uint256 _timePassed = block.timestamp - lastUpdatedAt;
    uint256 _floating = totalAvailableAsset_ == 0 ? 0 : totalAvailableAsset_ - assetAmt;
    uint256 _borrowerDebtAmt = borrowers[borrower].debt;
    uint256 _ratePerSec = _calculateInterestRate(borrower, _borrowerDebtAmt, _floating)
      / SECONDS_PER_YEAR;

    // First division is due to _ratePerSec being in 1e18
    // Second division is due to _ratePerSec being in 1e18
    return _ratePerSec * _borrowerDebtAmt * _timePassed / SAFE_MULTIPLIER;
  }

    /**
    * @notice Returns pending interest from all borrowers that will be accrued to the reserves in the next call
    * @param assetAmt Newly deposited assets to be subtracted off total available liquidity in token decimals
    * @return Amount of interest owned in token decimals
  */
  function _pendingInterests(uint256 assetAmt) internal view returns (uint256) {
    uint256 pendingInterests_;

    for (uint256 i = 0; i < _approvedBorrowers.length(); i++) {
      pendingInterests_ += _pendingInterest(_approvedBorrowers.at(i), assetAmt);
    }

    return pendingInterests_;
  }

  /**
    * @notice Conversion factor for tokens with less than 1e18 to return in 1e18
    * @return Amount of decimals for conversion to 1e18
  */
  function _to18ConversionFactor() internal view returns (uint256) {
    unchecked {
      if (ERC20(address(asset)).decimals() == 18) return 1;

      return 10**(18 - ERC20(address(asset)).decimals());
    }
  }

  /**
    * @notice Return the interest rate based on the borrower's model and overall utilization rate
    * @param borrower Address of borrower
    * @param debt Total borrowed amount
    * @param floating Total available liquidity
    * @return Current interest rate in 1e18
  */
  function _calculateInterestRate(
    address borrower,
    uint256 debt,
    uint256 floating
  ) internal view returns (uint256) {
    if (debt == 0 && floating == 0) return 0;

    InterestRate memory _interestRate = interestRates[borrower];
    uint256 _total = debt + floating;
    uint256 _utilization = debt * SAFE_MULTIPLIER / _total;

    // If _utilization above kink2, return a higher interest rate
    // (base + rate + excess _utilization above kink 2 * jumpMultiplier)
    if (_utilization > _interestRate.kink2) {
      return _interestRate.baseRate + (_interestRate.kink1 * _interestRate.multiplier / SAFE_MULTIPLIER)
                      + ((_utilization - _interestRate.kink2) * _interestRate.jumpMultiplier / SAFE_MULTIPLIER);
    }

    // If _utilization between kink1 and kink2, rates are flat
    if (_interestRate.kink1 < _utilization && _utilization <= _interestRate.kink2) {
      return _interestRate.baseRate + (_interestRate.kink1 * _interestRate.multiplier / SAFE_MULTIPLIER);
    }

    // If _utilization below kink1, calculate borrow rate for slope up to kink 1
    return _interestRate.baseRate + (_utilization * _interestRate.multiplier / SAFE_MULTIPLIER);
  }

  /* ================= RESTRICTED FUNCTIONS ================== */

  /**
    * @notice Updates lending vault interest rate model variables, callable only by keeper
    * @param borrower Address of borrower
    * @param newInterestRate InterestRate struct
  */
  function updateInterestRate(
    address borrower,
    InterestRate memory newInterestRate
  ) public restricted() {
    InterestRate memory _interestRate = interestRates[borrower];
    InterestRate memory _maxInterestRate = maxInterestRates[borrower];

    if (
      newInterestRate.baseRate > _maxInterestRate.baseRate ||
      newInterestRate.multiplier > _maxInterestRate.multiplier ||
      newInterestRate.jumpMultiplier > _maxInterestRate.jumpMultiplier ||
      newInterestRate.kink1 > _maxInterestRate.kink1 ||
      newInterestRate.kink2 > _maxInterestRate.kink2
    ) revert Errors.InterestRateModelExceeded();

    _interestRate.baseRate = newInterestRate.baseRate;
    _interestRate.multiplier = newInterestRate.multiplier;
    _interestRate.jumpMultiplier = newInterestRate.jumpMultiplier;
    _interestRate.kink1 = newInterestRate.kink1;
    _interestRate.kink2 = newInterestRate.kink2;

    interestRates[borrower] = _interestRate;

    emit UpdateInterestRate(
      borrower,
      _interestRate.baseRate,
      _interestRate.multiplier,
      _interestRate.jumpMultiplier,
      _interestRate.kink1,
      _interestRate.kink2
    );
  }

  /**
    * @notice Update perf fee
    * @param newPerformanceFee  Fee percentage in 1e18
  */
  function updatePerformanceFee(uint256 newPerformanceFee) external restricted {
    // Update vault with accrued interest and latest timestamp
    _updateVaultWithInterestsAndTimestamp(0);

    performanceFee = newPerformanceFee;

    emit PerformanceFeeUpdated(msg.sender, performanceFee, newPerformanceFee);
  }

  /**
    * @notice Approve address to borrow from this vault
    * @param borrower  Borrower address
  */
  function approveBorrower(address borrower) external restricted {
    if (_approvedBorrowers.contains(borrower)) revert Errors.BorrowerAlreadyApproved();

    _approvedBorrowers.add(borrower);
  }

  /**
    * @notice Revoke address to borrow from this vault
    * @param borrower  Borrower address
  */
  function revokeBorrower(address borrower) external restricted {
    if (!_approvedBorrowers.contains(borrower)) revert Errors.BorrowerAlreadyApproved();

    _approvedBorrowers.remove(borrower);
  }

  /**
    * @notice Emergency repay of assets to lending vault to clear bad debt
    * @param repayAmt Amount of debt to repay in token decimals
  */
  function emergencyRepay(uint256 repayAmt, address defaulter) external nonReentrant {
    if (repayAmt == 0) revert Errors.InsufficientRepayAmount();

    // Update vault with accrued interest and latest timestamp
    _updateVaultWithInterestsAndTimestamp(0);

    uint256 maxRepay_ = maxRepay(defaulter);

    if (maxRepay_ > 0) {
      if (repayAmt > maxRepay_) {
        repayAmt = maxRepay_;
      }

      // Calculate debt to reduce based on repay amount
      uint256 _debt = repayAmt * borrowers[defaulter].debt / maxRepay_;

      // Update vault state
      totalBorrows = totalBorrows - repayAmt;
      totalBorrowDebt = totalBorrowDebt - _debt;

      // Update borrower state
      borrowers[defaulter].debt = borrowers[defaulter].debt - _debt;
      borrowers[defaulter].lastUpdatedAt = block.timestamp;

      // Transfer repay tokens to the vault
      asset.safeTransferFrom(msg.sender, address(this), repayAmt);

      emit Repay(defaulter, _debt, repayAmt);
    }
  }

  /**
    * @notice Emergency pause of lending vault that pauses all deposits and borrows
  */
  function emergencyPause() external whenNotPaused restricted {
    _pause();

    emit EmergencyPause(msg.sender);
  }

  /**
    * @notice Emergency resume of lending vault that unpauses all deposits and borrows
  */
  function emergencyResume() external whenPaused restricted {
    _unpause();

    emit EmergencyResume(msg.sender);
  }

  /**
    * @notice Update max capacity value
    * @param newMaxCapacity Capacity value in token decimals (amount)
  */
  function updateMaxCapacity(uint256 newMaxCapacity) external restricted {
    maxCapacity = newMaxCapacity;

    emit UpdateMaxCapacity(newMaxCapacity);
  }

  /**
    * @notice Updates maximum allowed lending vault interest rate model variables
    * @param borrower Address of borrower
    * @param newMaxInterestRate InterestRate struct
  */
  function updateMaxInterestRate(
    address borrower,
    InterestRate memory newMaxInterestRate
  ) public restricted {
    InterestRate memory _maxInterestRate = maxInterestRates[borrower];

    _maxInterestRate.baseRate = newMaxInterestRate.baseRate;
    _maxInterestRate.multiplier = newMaxInterestRate.multiplier;
    _maxInterestRate.jumpMultiplier = newMaxInterestRate.jumpMultiplier;
    _maxInterestRate.kink1 = newMaxInterestRate.kink1;
    _maxInterestRate.kink2 = newMaxInterestRate.kink2;

    maxInterestRates[borrower] = _maxInterestRate;

    emit UpdateMaxInterestRate(
      borrower,
      _maxInterestRate.baseRate,
      _maxInterestRate.multiplier,
      _maxInterestRate.jumpMultiplier,
      _maxInterestRate.kink1,
      _maxInterestRate.kink2
    );
  }

  /**
    * @notice Update treasury address
    * @param newTreasury Treasury address
  */
  function updateTreasury(address newTreasury) external restricted {
    if (newTreasury == address(0)) revert Errors.ZeroAddressNotAllowed();

    treasury = newTreasury;
  }

  /* ================== FALLBACK FUNCTIONS =================== */

  /**
    * @notice Fallback function to receive native token sent to this contract,
    * needed for receiving native token to contract when unwrapped
  */
  receive() external payable {
    if (!isNativeAsset) revert Errors.OnlyNonNativeDepositToken();
  }
}
