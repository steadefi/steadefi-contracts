// SPDX-License-Identifier: MIT
pragma solidity 0.8.21;

import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { SafeERC20 } from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import { IERC20Metadata } from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import { AccessManaged } from "@openzeppelin/contracts/access/manager/AccessManaged.sol";
import { IChainlinkOracle } from  "../interfaces/oracles/IChainlinkOracle.sol";
import { ILBRouter } from "../interfaces/protocols/trader-joe/ILBRouter.sol";
import { ISwap } from "../interfaces/swap/ISwap.sol";
import { Errors } from "../utils/Errors.sol";

contract TraderJoeSwap is AccessManaged, ISwap {

  using SafeERC20 for IERC20;

  /* ==================== STATE VARIABLES ==================== */

  // Address of TraderJoe router
  ILBRouter public router;
  // Address of Chainlink oracle
  IChainlinkOracle public oracle;
  // Address of wrapped native token
  address public WNT;

  /* ====================== CONSTANTS ======================== */

  uint256 public constant SAFE_MULTIPLIER = 1e18;

  /* ======================= MAPPINGS ======================== */

  // Mapping of pair bin steps for tokenIn => tokenOut which determines swap pool
  mapping(address => mapping(address => uint256)) public pairBinSteps;

  /* ======================== EVENTS ========================= */

  event PairBinStepUpdated(address tokenIn, address tokenOut, uint256 pairBinStep);
  event RouterUpdated(address router);
  event OracleUpdated(address oracle);

  /* ====================== CONSTRUCTOR ====================== */

  /**
    * @param _router Address of router of swap
    * @param _oracle Address of Chainlink oracle
    * @param _WNT Address of wrapped native token
    * @param _accessManager Address of access manager
  */
  constructor(
    ILBRouter _router,
    IChainlinkOracle _oracle,
    address _WNT,
    address _accessManager
  ) AccessManaged(_accessManager) {
    if (
      address(_router) == address(0) ||
      address(_oracle) == address(0)
    ) revert Errors.ZeroAddressNotAllowed();

    router = ILBRouter(_router);
    oracle = IChainlinkOracle(_oracle);
    WNT = _WNT;
  }

  /* ================== MUTATIVE FUNCTIONS =================== */

  /**
    * @notice Swap exact amount of tokenIn for as many amount of tokenOut
    * @param sp ISwap.SwapParams
    * @return amountOut Amount of tokenOut; in token decimals
  */
  function swapExactTokensForTokens(ISwap.SwapParams memory sp) external returns (uint256) {
    IERC20(sp.tokenIn).safeTransferFrom(msg.sender, address(this), sp.amountIn);

    IERC20(sp.tokenIn).approve(address(router), sp.amountIn);

    uint256[] memory _pairBinSteps;
    IERC20[] memory _tokenPath;
    ILBRouter.Version[] memory _versions;

    // If there is a LB Pair for tokenIn and tokenOut, no intermediary bin needed
    if (pairBinSteps[sp.tokenIn][sp.tokenOut] != 0) {
      _pairBinSteps = new uint256[](1);
      _pairBinSteps[0] = pairBinSteps[sp.tokenIn][sp.tokenOut];

      _tokenPath = new IERC20[](2);
      _tokenPath[0] = IERC20(sp.tokenIn);
      _tokenPath[1] = IERC20(sp.tokenOut);

      _versions = new ILBRouter.Version[](1);
      _versions[0] = ILBRouter.Version.V2_1;
    } else {
      // If not, we use wrapped native token as intermediary bin
      _pairBinSteps = new uint256[](2);
      _pairBinSteps[0] = pairBinSteps[sp.tokenIn][WNT];
      _pairBinSteps[1] = pairBinSteps[WNT][sp.tokenOut];

      _tokenPath = new IERC20[](3);
      _tokenPath[0] = IERC20(sp.tokenIn);
      _tokenPath[1] = IERC20(WNT);
      _tokenPath[2] = IERC20(sp.tokenOut);

      _versions = new ILBRouter.Version[](2);
      _versions[0] = ILBRouter.Version.V2_1;
      _versions[1] = ILBRouter.Version.V2_1;
    }

    ILBRouter.Path memory _path;
    _path.pairBinSteps = _pairBinSteps;
    _path.versions = _versions;
    _path.tokenPath = _tokenPath;

    uint256 _valueIn = sp.amountIn * oracle.consultIn18Decimals(sp.tokenIn) / SAFE_MULTIPLIER;

    uint256 _amountOutMinimum = _valueIn
      * SAFE_MULTIPLIER
      / oracle.consultIn18Decimals(sp.tokenOut)
      / (10 ** (18 - IERC20Metadata(sp.tokenOut).decimals()))
      * (10000 - sp.slippage) / 10000;

    uint256 _amountOut = router.swapExactTokensForTokens(
      sp.amountIn,
      _amountOutMinimum,
      _path,
      address(this),
      sp.deadline
    );

    IERC20(sp.tokenOut).safeTransfer(msg.sender, _amountOut);

    return _amountOut;
  }

  /**
    * @notice Swap as little tokenIn for exact amount of tokenOut
    * @param sp ISwap.SwapParams
    * @return amountIn Amount of tokenIn swapped; in token decimals
  */
  function swapTokensForExactTokens(ISwap.SwapParams memory sp) external returns (uint256) {
    IERC20(sp.tokenIn).safeTransferFrom(
      msg.sender,
      address(this),
      sp.amountIn
    );

    IERC20(sp.tokenIn).approve(address(router), sp.amountIn);

    uint256[] memory _pairBinSteps;
    IERC20[] memory _tokenPath;
    ILBRouter.Version[] memory _versions;

    // If there is a LB Pair for tokenIn and tokenOut, no intermediary bin needed
    if (pairBinSteps[sp.tokenIn][sp.tokenOut] != 0) {
      _pairBinSteps = new uint256[](1);
      _pairBinSteps[0] = pairBinSteps[sp.tokenIn][sp.tokenOut];

      _tokenPath = new IERC20[](2);
      _tokenPath[0] = IERC20(sp.tokenIn);
      _tokenPath[1] = IERC20(sp.tokenOut);

      _versions = new ILBRouter.Version[](1);
      _versions[0] = ILBRouter.Version.V2_1;
    } else {
      _pairBinSteps = new uint256[](2);
      _pairBinSteps[0] = pairBinSteps[sp.tokenIn][WNT];
      _pairBinSteps[1] = pairBinSteps[WNT][sp.tokenOut];

      _tokenPath = new IERC20[](3);
      _tokenPath[0] = IERC20(sp.tokenIn);
      _tokenPath[1] = IERC20(WNT);
      _tokenPath[2] = IERC20(sp.tokenOut);

      _versions = new ILBRouter.Version[](2);
      _versions[0] = ILBRouter.Version.V2_1;
      _versions[1] = ILBRouter.Version.V2_1;
    }

    ILBRouter.Path memory _path;
    _path.pairBinSteps = _pairBinSteps;
    _path.versions = _versions;
    _path.tokenPath = _tokenPath;

    uint256[] memory _amountIn = router.swapTokensForExactTokens(
      sp.amountOut,
      sp.amountIn,
      _path,
      address(this),
      sp.deadline
    );

    // Return sender back any unused tokenIn
    IERC20(sp.tokenIn).safeTransfer(
      msg.sender,
      IERC20(sp.tokenIn).balanceOf(address(this))
    );

    IERC20(sp.tokenOut).safeTransfer(
      msg.sender,
      IERC20(sp.tokenOut).balanceOf(address(this))
    );

    // First value in array is the amountIn used for tokenIn
    return _amountIn[0];
  }

  /* ================= RESTRICTED FUNCTIONS ================== */

  /**
    * @notice Update pair bin step for tokenIn => tokenOut which determines the swap pool to
    * swap tokenIn for tokenOut at
    * @dev To add tokenIn/Out for both ways of the token swap to ensure the same swap pool is used
    * for the swap in both directions
    * @param tokenIn Address of token to swap from
    * @param tokenOut Address of token to swap to
    * @param pairBinStep Pair bin step for the liquidity pool in uint256
  */
  function updatePairBinStep(address tokenIn, address tokenOut, uint256 pairBinStep) external restricted {
    if (tokenIn == address(0) || tokenOut == address(0)) revert Errors.ZeroAddressNotAllowed();

    pairBinSteps[tokenIn][tokenOut] = pairBinStep;

    emit PairBinStepUpdated(tokenIn, tokenOut, pairBinStep);
  }

  /**
    * @notice Update swap router
    * @param newRouter Address of new swap router
  */
  function updateRouter(address newRouter) external restricted {
    if (newRouter == address(0)) revert Errors.ZeroAddressNotAllowed();

    router = ILBRouter(newRouter);

    emit RouterUpdated(newRouter);
  }

  /**
    * @notice Update chainlink oracle
    * @param newOracle Address of new chainlink oracle
  */
  function updateOracle(address newOracle) external restricted {
    if (newOracle == address(0)) revert Errors.ZeroAddressNotAllowed();

    oracle = IChainlinkOracle(newOracle);

    emit OracleUpdated(newOracle);
  }
}
