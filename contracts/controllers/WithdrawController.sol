// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.16;

import "../interfaces/IPool.sol";
import "./interfaces/IWithdrawController.sol";
import "./interfaces/IPoolController.sol";
import "../libraries/PoolLib.sol";
import {EnumerableSet} from "@openzeppelin/contracts/utils/structs/EnumerableSet.sol";
import {SafeMath} from "@openzeppelin/contracts/utils/math/SafeMath.sol";

/**
 * @title WithdrawState
 */
contract WithdrawController is IWithdrawController {
    using SafeMath for uint256;
    using EnumerableSet for EnumerableSet.AddressSet;

    /**
     * @dev A reference to the pool for this withdraw state
     */
    IPool private _pool;

    /**
     * @dev Per-lender withdraw request information
     */
    mapping(address => IPoolWithdrawState) private _withdrawState;

    /**
     * @dev Aggregate withdraw request information
     */
    IPoolWithdrawState private _globalWithdrawState;

    /**
     * @dev Mapping of withdrawPeriod to snapshot
     */
    mapping(uint256 => IPoolSnapshotState) private _snapshots;

    /**
     * @dev Modifier that checks that the caller is a pool lender
     */
    modifier onlyPool() {
        require(address(_pool) == msg.sender, "WithdrawController: Not Pool");
        _;
    }

    /**
     * @dev Constructor for a Pool's withdraw state
     */
    constructor(address pool) {
        _pool = IPool(pool);
    }

    /*//////////////////////////////////////////////////////////////
                        State Views
    //////////////////////////////////////////////////////////////*/

    /**
     * @dev The current withdraw period. Funds marked with this period (or
     * earlier), are eligible to be considered for redemption/widrawal.
     *
     * TODO: This can be internal
     */
    function withdrawPeriod() public view returns (uint256 period) {
        period = PoolLib.calculateCurrentWithdrawPeriod(
            block.timestamp,
            _pool.activatedAt(),
            _pool.settings().withdrawRequestPeriodDuration
        );
    }

    /**
     * @dev Returns the current withdraw state of an owner.
     */
    function _currentWithdrawState(address owner)
        internal
        view
        returns (IPoolWithdrawState memory state)
    {
        uint256 currentPeriod = withdrawPeriod();
        state = PoolLib.progressWithdrawState(
            _withdrawState[owner],
            currentPeriod
        );

        return simulateCrank(state);
    }

    /**
     * @dev Returns the current global withdraw state.
     */
    function _currentGlobalWithdrawState()
        internal
        view
        returns (IPoolWithdrawState memory state)
    {
        state = PoolLib.progressWithdrawState(
            _globalWithdrawState,
            withdrawPeriod()
        );
    }

    /*//////////////////////////////////////////////////////////////
                            Balance Views
    //////////////////////////////////////////////////////////////*/

    /**
     * @inheritdoc IWithdrawController
     */
    function interestBearingBalanceOf(address owner)
        external
        view
        returns (uint256 shares)
    {
        shares = _pool.balanceOf(owner) - maxRedeem(owner);
    }

    /**
     * @inheritdoc IWithdrawController
     */
    function requestedBalanceOf(address owner)
        external
        view
        returns (uint256 shares)
    {
        shares = _currentWithdrawState(owner).requestedShares;
    }

    /**
     * @inheritdoc IWithdrawController
     */
    function totalRequestedBalance() external view returns (uint256 shares) {
        shares = _currentGlobalWithdrawState().requestedShares;
    }

    /**
     * @inheritdoc IWithdrawController
     */
    function eligibleBalanceOf(address owner)
        external
        view
        returns (uint256 shares)
    {
        shares = _currentWithdrawState(owner).eligibleShares;
    }

    /**
     * @inheritdoc IWithdrawController
     */
    function totalEligibleBalance() external view returns (uint256 shares) {
        shares = _currentGlobalWithdrawState().eligibleShares;
    }

    /**
     * @inheritdoc IWithdrawController
     */
    function totalRedeemableShares() external view returns (uint256 shares) {
        shares = _currentGlobalWithdrawState().redeemableShares;
    }

    /**
     * @inheritdoc IWithdrawController
     */
    function totalWithdrawableAssets() external view returns (uint256 assets) {
        assets = _currentGlobalWithdrawState().withdrawableAssets;
    }

    /*//////////////////////////////////////////////////////////////
                            Max Methods
    //////////////////////////////////////////////////////////////*/

    /**
     * @inheritdoc IWithdrawController
     */
    function maxRedeemRequest(address owner)
        external
        view
        returns (uint256 maxShares)
    {
        maxShares = PoolLib.calculateMaxRedeemRequest(
            _currentWithdrawState(owner),
            _pool.balanceOf(owner),
            _pool.settings().requestFeeBps
        );
    }

    /**
     * @inheritdoc IWithdrawController
     */
    function maxRedeem(address owner) public view returns (uint256 maxShares) {
        maxShares = _currentWithdrawState(owner).redeemableShares;
    }

    /**
     * @inheritdoc IWithdrawController
     */
    function maxWithdraw(address owner) external view returns (uint256 assets) {
        assets = _currentWithdrawState(owner).withdrawableAssets;
    }

    /*//////////////////////////////////////////////////////////////
                            Preview Methods
    //////////////////////////////////////////////////////////////*/

    /**
     * @inheritdoc IWithdrawController
     */
    function previewRedeemRequest(uint256 shares)
        external
        view
        returns (uint256 assets)
    {
        uint256 shareFees = PoolLib.calculateRequestFee(
            shares,
            _pool.settings().requestFeeBps
        );

        assets = _pool.convertToAssets(shares - shareFees);
    }

    /**
     * @inheritdoc IWithdrawController
     */
    function previewWithdrawRequest(uint256 assets)
        external
        view
        returns (uint256 shares)
    {
        uint256 assetFees = PoolLib.calculateRequestFee(
            assets,
            _pool.settings().requestFeeBps
        );

        shares = _pool.convertToShares(assets + assetFees);
    }

    /**
     * @inheritdoc IWithdrawController
     */
    function previewRedeem(address owner, uint256 shares)
        external
        view
        returns (uint256 assets)
    {
        assets = PoolLib.calculateConversion(
            shares,
            _currentWithdrawState(owner).withdrawableAssets,
            _currentWithdrawState(owner).redeemableShares,
            false
        );
    }

    /**
     * @inheritdoc IWithdrawController
     */
    function previewWithdraw(address owner, uint256 assets)
        external
        view
        returns (uint256 shares)
    {
        IPoolWithdrawState memory withdrawState = _currentWithdrawState(
            msg.sender
        );
        shares = PoolLib.calculateConversion(
            assets,
            withdrawState.redeemableShares,
            withdrawState.withdrawableAssets,
            true
        );
    }

    /*//////////////////////////////////////////////////////////////
                            Request Methods
    //////////////////////////////////////////////////////////////*/

    /**
     * @inheritdoc IWithdrawController
     */
    function performRequest(address owner, uint256 shares) external onlyPool {
        crankLender(owner); // Get them up-to-date

        uint256 currentPeriod = withdrawPeriod();

        // Update the requested amount from the user
        _withdrawState[owner] = PoolLib.calculateWithdrawStateForRequest(
            _currentWithdrawState(owner),
            currentPeriod,
            shares
        );
        _withdrawState[owner].latestCrankPeriod = _globalWithdrawState
            .latestCrankPeriod;

        // Update the global amount
        _globalWithdrawState = PoolLib.calculateWithdrawStateForRequest(
            _globalWithdrawState,
            currentPeriod,
            shares
        );
    }

    /*//////////////////////////////////////////////////////////////
                        Cancellation Methods
    //////////////////////////////////////////////////////////////*/

    /**
     * @inheritdoc IWithdrawController
     */
    function maxRequestCancellation(address owner)
        public
        view
        returns (uint256 maxShares)
    {
        maxShares = PoolLib.calculateMaxCancellation(
            _currentWithdrawState(owner),
            _pool.settings().requestCancellationFeeBps
        );
    }

    /**
     * @inheritdoc IWithdrawController
     */
    function performRequestCancellation(address owner, uint256 shares)
        external
        onlyPool
    {
        crankLender(owner);
        uint256 currentPeriod = withdrawPeriod();

        // Update the requested amount from the user
        _withdrawState[owner] = PoolLib.calculateWithdrawStateForCancellation(
            _currentWithdrawState(owner),
            currentPeriod,
            shares
        );

        // Update the global amount
        _globalWithdrawState = PoolLib.calculateWithdrawStateForCancellation(
            _globalWithdrawState,
            currentPeriod,
            shares
        );
    }

    /*//////////////////////////////////////////////////////////////
                            Crank
    //////////////////////////////////////////////////////////////*/

    /**
     * @inheritdoc IWithdrawController
     */
    function crank() external onlyPool returns (uint256 redeemableShares) {
        uint256 currentPeriod = withdrawPeriod();
        IPoolWithdrawState memory globalState = _currentGlobalWithdrawState();
        if (globalState.latestCrankPeriod == currentPeriod) {
            return 0;
        }

        // Calculate the amount available for withdrawal
        uint256 liquidAssets = _pool.liquidityPoolAssets();
        IPoolController _poolController = IPoolController(
            _pool.poolController()
        );

        uint256 availableAssets = liquidAssets
            .mul(_poolController.withdrawGate())
            .mul(PoolLib.RAY)
            .div(10_000)
            .div(PoolLib.RAY);

        uint256 availableShares = _pool.convertToShares(availableAssets);

        if (
            availableAssets <= 0 ||
            availableShares <= 0 ||
            globalState.eligibleShares <= 0
        ) {
            // unable to redeem anything
            redeemableShares = 0;
            return 0;
        }

        // Determine the amount of shares that we will actually distribute.
        redeemableShares = Math.min(
            availableShares,
            globalState.eligibleShares - 1 // We offset by 1 to avoid a 100% redeem rate, which throws off all the math.
        );

        if (redeemableShares == 0) {
            return 0;
        }

        // Calculate the redeemable rate for each lender
        uint256 redeemableRateRay = redeemableShares.mul(PoolLib.RAY).div(
            globalState.eligibleShares
        );

        // Calculate the exchange rate for the snapshotted funds
        uint256 fxExchangeRate = availableAssets.mul(PoolLib.RAY).div(
            availableShares
        );

        // Pull up the prior snapshot
        IPoolSnapshotState memory lastSnapshot = _snapshots[
            globalState.latestCrankPeriod
        ];

        // Cache the last aggregate difference. This is set to 1 * RAY if it
        // doesn't exist, so that everything doesn't collapse to 0.
        uint256 lastDiff = lastSnapshot.aggregationDifferenceRay != 0
            ? lastSnapshot.aggregationDifferenceRay
            : PoolLib.RAY;

        // Compute the new snapshotted values
        _snapshots[currentPeriod] = IPoolSnapshotState(
            // New aggregation
            lastSnapshot.aggregationSumRay +
                redeemableRateRay.mul(lastDiff).div(PoolLib.RAY),
            // New aggregation w/ FX
            lastSnapshot.aggregationSumFxRay +
                redeemableRateRay
                    .mul(lastDiff)
                    .div(PoolLib.RAY)
                    .mul(fxExchangeRate)
                    .div(PoolLib.RAY),
            // New difference
            lastDiff.mul(PoolLib.RAY - redeemableRateRay).div(PoolLib.RAY)
        );

        // Update the global withdraw state to earmark those funds
        globalState = PoolLib.updateWithdrawStateForWithdraw(
            globalState,
            _pool.convertToAssets(redeemableShares),
            redeemableShares
        );
        globalState.latestCrankPeriod = currentPeriod;
        _globalWithdrawState = globalState;
    }

    /**
     * @dev Simulates the effects of multiple snapshots against a lenders
     * requested withdrawal.
     */
    function simulateCrank(IPoolWithdrawState memory withdrawState)
        internal
        view
        returns (IPoolWithdrawState memory)
    {
        uint256 currentPeriod = withdrawPeriod();
        uint256 lastPoolCrank = _globalWithdrawState.latestCrankPeriod;

        // Current snaphot
        IPoolSnapshotState memory endingSnapshot = _snapshots[lastPoolCrank];

        // Offset snapshot
        IPoolSnapshotState memory offsetSnapshot = _snapshots[
            withdrawState.latestCrankPeriod
        ];

        // Calculate shares now redeemable
        uint256 sharesRedeemable = withdrawState.eligibleShares.mul(
            endingSnapshot.aggregationSumRay - offsetSnapshot.aggregationSumRay
        );
        sharesRedeemable = sharesRedeemable
            .mul(offsetSnapshot.aggregationDifferenceRay > 0 ? PoolLib.RAY : 1)
            .div(
                offsetSnapshot.aggregationDifferenceRay > 0
                    ? offsetSnapshot.aggregationDifferenceRay
                    : 1
            )
            .div(PoolLib.RAY);

        // Calculate assets now withdrawable
        uint256 assetsWithdrawable = withdrawState.eligibleShares.mul(
            endingSnapshot.aggregationSumFxRay -
                offsetSnapshot.aggregationSumFxRay
        );

        assetsWithdrawable = assetsWithdrawable
            .mul(offsetSnapshot.aggregationDifferenceRay > 0 ? PoolLib.RAY : 1)
            .div(
                offsetSnapshot.aggregationDifferenceRay > 0
                    ? offsetSnapshot.aggregationDifferenceRay
                    : 1
            )
            .div(PoolLib.RAY);

        withdrawState.withdrawableAssets += assetsWithdrawable;
        withdrawState.redeemableShares += sharesRedeemable;
        withdrawState.eligibleShares -= sharesRedeemable;

        withdrawState.latestCrankPeriod = lastPoolCrank;

        return withdrawState;
    }

    /**
     * @dev Cranks a lender
     */
    function crankLender(address addr) internal {
        _withdrawState[addr] = _currentWithdrawState(addr);
    }

    /*//////////////////////////////////////////////////////////////
                            Withdraw / Redeem
    //////////////////////////////////////////////////////////////*/

    /**
     * @inheritdoc IWithdrawController
     */
    function redeem(address owner, uint256 shares)
        external
        onlyPool
        returns (uint256 assets)
    {
        // Calculate how many assets should be transferred
        IPoolWithdrawState memory state = _currentWithdrawState(owner);
        assets = PoolLib.calculateConversion(
            shares,
            state.withdrawableAssets,
            state.redeemableShares,
            false
        );

        _performWithdraw(owner, shares, assets);
    }

    /**
     * @inheritdoc IWithdrawController
     */
    function withdraw(address owner, uint256 assets)
        external
        onlyPool
        returns (uint256 shares)
    {
        // Calculate how many shares should be burned
        IPoolWithdrawState memory state = _currentWithdrawState(owner);
        shares = PoolLib.calculateConversion(
            assets,
            state.redeemableShares,
            state.withdrawableAssets,
            true
        );

        _performWithdraw(owner, shares, assets);
    }

    /**
     * @dev Perform the state update for a withdraw
     */
    function _performWithdraw(
        address owner,
        uint256 shares,
        uint256 assets
    ) internal {
        crankLender(owner);
        IPoolWithdrawState memory currentState = _currentWithdrawState(owner);

        require(
            assets <= _currentWithdrawState(owner).withdrawableAssets,
            "Pool: InsufficientBalance"
        );

        require(
            shares <= _currentWithdrawState(owner).redeemableShares,
            "Pool: InsufficientBalance"
        );

        // update the withdrawState to account for these shares being
        // removed from "withdrawable"
        _withdrawState[owner].redeemableShares -= shares;
        _withdrawState[owner].withdrawableAssets -= assets;
        _globalWithdrawState.redeemableShares -= shares;
        _globalWithdrawState.withdrawableAssets -= assets;
    }
}