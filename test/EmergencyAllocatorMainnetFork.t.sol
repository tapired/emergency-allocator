// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity ^0.8.20;

import {Test} from "forge-std/Test.sol";

import {EmergencyAllocator, Id, IMorpho, MarketParams, MarketState, Position} from "../src/EmergencyAllocator.sol";

interface IMainnetMetaMorphoV1 {
    function owner() external view returns (address);
    function MORPHO() external view returns (IMorpho);
    function isAllocator(address) external view returns (bool);
    function setIsAllocator(address newAllocator, bool newIsAllocator) external;
    function withdrawQueueLength() external view returns (uint256);
    function withdrawQueue(uint256 index) external view returns (bytes32);
    function config(bytes32 id) external view returns (uint184 cap, bool enabled, uint64 removableAt);
}

interface IMainnetVaultV2 {
    function curator() external view returns (address);
    function isAllocator(address) external view returns (bool);
    function submit(bytes calldata data) external;
    function timelock(bytes4 selector) external view returns (uint256);
    function setIsAllocator(address account, bool newIsAllocator) external;
    function adaptersLength() external view returns (uint256);
    function adapters(uint256 index) external view returns (address);
}

interface IMorphoMarketV1AdapterV2Like {
    function morpho() external view returns (address);
    function marketIdsLength() external view returns (uint256);
    function marketIds(uint256 index) external view returns (bytes32);
    function supplyShares(bytes32 marketId) external view returns (uint256);
}

interface IERC20BalanceOf {
    function balanceOf(address account) external view returns (uint256);
}

interface IERC20Approve {
    function approve(address spender, uint256 amount) external returns (bool);
}

interface IMorphoBorrowLike is IMorpho {
    function supplyCollateral(MarketParams memory marketParams, uint256 assets, address onBehalf, bytes memory data)
        external;
    function borrow(
        MarketParams memory marketParams,
        uint256 assets,
        uint256 shares,
        address onBehalf,
        address receiver
    ) external returns (uint256 assetsBorrowed, uint256 sharesBorrowed);
}

contract EmergencyAllocatorMainnetForkTest is Test {
    address internal constant V1_VAULT = 0xF9bdDd4A9b3A45f980e11fDDE96e16364dDBEc49;
    address internal constant V2_VAULT = 0xB885F6d448dA7E2C642Ec31190B629E40E87B069;
    uint256 internal constant FORK_BLOCK = 25_050_823;
    uint256 internal constant ROUNDING_TOLERANCE_REL = 1e14; // 1 bps

    EmergencyAllocator internal allocator;
    bool internal forkEnabled;

    function setUp() public {
        string memory rpcUrl = vm.envOr("ETH_RPC_URL", string(""));
        if (bytes(rpcUrl).length == 0) return;

        vm.createSelectFork(rpcUrl, FORK_BLOCK);
        allocator = new EmergencyAllocator(address(this));
        forkEnabled = true;
    }

    function test_mainnetFork_emergencyReallocateVaultV1UsesLiveQueueAndLiquidity() public {
        if (!forkEnabled) return;

        IMainnetMetaMorphoV1 vault = IMainnetMetaMorphoV1(V1_VAULT);
        IMorpho morpho = vault.MORPHO();

        vm.prank(vault.owner());
        vault.setIsAllocator(address(allocator), true);
        assertTrue(vault.isAllocator(address(allocator)));

        (bytes32 sourceMarketId, bytes32 idleMarketId, uint256 targetWithdrawable) =
            _prepareVaultV1Scenario(vault, morpho);

        uint256 withdrawnAssets = allocator.emergencyReallocateVaultV1(V1_VAULT, sourceMarketId, idleMarketId);

        assertApproxEqRel(withdrawnAssets, targetWithdrawable, ROUNDING_TOLERANCE_REL);
    }

    function test_mainnetFork_emergencyDeallocateVaultV2UsesLiveAdapterAndLiquidity() public {
        if (!forkEnabled) return;

        IMainnetVaultV2 vault = IMainnetVaultV2(V2_VAULT);
        address adapter = _findMorphoMarketAdapter(vault);
        IMorphoMarketV1AdapterV2Like marketAdapter = IMorphoMarketV1AdapterV2Like(adapter);
        IMorpho morpho = IMorpho(marketAdapter.morpho());

        _grantVaultV2Allocator(vault, address(allocator));
        assertTrue(vault.isAllocator(address(allocator)));

        (bytes32 marketId, uint256 withdrawableAssets) = _selectVaultV2Market(marketAdapter, morpho);
        assertGt(withdrawableAssets, 0, "no live v2 market");

        MarketParams memory marketParams = morpho.idToMarketParams(Id.wrap(marketId));
        (,,, uint256 availableLiquidityBefore,) = allocator.previewVaultV2Withdrawable(address(adapter), marketParams);
        (uint256 targetWithdrawable,) = _borrowToReduceLiquidity(
            IMorphoBorrowLike(address(morpho)), marketParams, withdrawableAssets, availableLiquidityBefore
        );

        uint256 vaultBalanceBefore = IERC20BalanceOf(marketParams.loanToken).balanceOf(V2_VAULT);

        uint256 withdrawnAssets = allocator.emergencyDeallocateVaultV2(V2_VAULT, adapter, marketId);

        uint256 vaultBalanceAfter = IERC20BalanceOf(marketParams.loanToken).balanceOf(V2_VAULT);

        assertApproxEqRel(withdrawnAssets, targetWithdrawable, ROUNDING_TOLERANCE_REL);
        assertApproxEqRel(vaultBalanceAfter - vaultBalanceBefore, withdrawnAssets, ROUNDING_TOLERANCE_REL);
    }

    function _grantVaultV2Allocator(IMainnetVaultV2 vault, address newAllocator) internal {
        address curator = vault.curator();
        bytes memory data = abi.encodeCall(IMainnetVaultV2.setIsAllocator, (newAllocator, true));

        vm.prank(curator);
        vault.submit(data);

        uint256 delay = vault.timelock(IMainnetVaultV2.setIsAllocator.selector);
        if (delay != 0) vm.warp(block.timestamp + delay);

        vm.prank(curator);
        vault.setIsAllocator(newAllocator, true);
    }

    function _findMorphoMarketAdapter(IMainnetVaultV2 vault) internal view returns (address adapter) {
        uint256 adaptersLength = vault.adaptersLength();
        for (uint256 i; i < adaptersLength; ++i) {
            address candidate = vault.adapters(i);
            try IMorphoMarketV1AdapterV2Like(candidate).marketIdsLength() returns (uint256) {
                return candidate;
            } catch {}
        }

        revert("no market adapter");
    }

    function _selectVaultV2Market(IMorphoMarketV1AdapterV2Like adapter, IMorpho morpho)
        internal
        view
        returns (bytes32 marketId, uint256 withdrawableAssets)
    {
        uint256 length = adapter.marketIdsLength();
        for (uint256 i; i < length; ++i) {
            bytes32 candidate = adapter.marketIds(i);
            if (adapter.supplyShares(candidate) == 0) continue;

            MarketParams memory marketParams = morpho.idToMarketParams(Id.wrap(candidate));
            if (marketParams.collateralToken == address(0)) continue;
            (,,,, uint256 candidateWithdrawable) = allocator.previewVaultV2Withdrawable(address(adapter), marketParams);
            if (candidateWithdrawable == 0) continue;

            return (candidate, candidateWithdrawable);
        }

        revert("no v2 market");
    }

    function _prepareVaultV1Scenario(IMainnetMetaMorphoV1 vault, IMorpho morpho)
        internal
        returns (bytes32 sourceMarketId, bytes32 idleMarketId, uint256 targetWithdrawable)
    {
        uint256 length = vault.withdrawQueueLength();

        for (uint256 i; i < length; ++i) {
            bytes32 candidateSource = vault.withdrawQueue(i);
            MarketParams memory sourceMarketParams = morpho.idToMarketParams(Id.wrap(candidateSource));
            if (sourceMarketParams.collateralToken == address(0)) continue;

            uint256 availableLiquidityBefore;
            uint256 sourceWithdrawable;
            (, availableLiquidityBefore, sourceWithdrawable) =
                allocator.previewMetaMorphoWithdrawable(V1_VAULT, candidateSource);
            if (sourceWithdrawable == 0) continue;

            (bool found, bytes32 candidateIdle, uint256 candidateTargetWithdrawable) = _findBorrowableIdleMarket(
                vault, morpho, candidateSource, sourceMarketParams, availableLiquidityBefore, sourceWithdrawable
            );
            if (!found) continue;

            sourceMarketId = candidateSource;
            idleMarketId = candidateIdle;
            targetWithdrawable = candidateTargetWithdrawable;
            return (sourceMarketId, idleMarketId, targetWithdrawable);
        }

        revert("no borrowable v1 market pair");
    }

    function _findBorrowableIdleMarket(
        IMainnetMetaMorphoV1 vault,
        IMorpho morpho,
        bytes32 sourceMarketId,
        MarketParams memory sourceMarketParams,
        uint256 availableLiquidityBefore,
        uint256 sourceWithdrawable
    ) internal returns (bool found, bytes32 idleMarketId, uint256 targetWithdrawable) {
        uint256 length = vault.withdrawQueueLength();

        for (uint256 j; j < length; ++j) {
            bytes32 candidateIdle = vault.withdrawQueue(j);
            if (candidateIdle == sourceMarketId) continue;

            uint256 feasibleAssets = _idleFeasibleAssets(vault, morpho, candidateIdle, sourceWithdrawable);
            if (feasibleAssets == 0) continue;

            uint256 requestedWithdrawable = feasibleAssets > 1 ? feasibleAssets / 2 : feasibleAssets;
            uint256 borrowAmount = availableLiquidityBefore - requestedWithdrawable;
            if (borrowAmount == 0) continue;

            try this.tryBorrowMarket(address(morpho), sourceMarketParams, borrowAmount) returns (
                uint256 borrowedAssets
            ) {
                return (true, candidateIdle, availableLiquidityBefore - borrowedAssets);
            } catch {}
        }

        return (false, bytes32(0), 0);
    }

    function _idleFeasibleAssets(
        IMainnetMetaMorphoV1 vault,
        IMorpho morpho,
        bytes32 idleMarketId,
        uint256 sourceWithdrawable
    ) internal view returns (uint256 feasibleAssets) {
        (uint184 cap, bool enabled,) = vault.config(idleMarketId);
        if (!enabled) return 0;

        uint256 idleAssets = _marketAssetsOf(morpho, idleMarketId, V1_VAULT);
        if (uint256(cap) <= idleAssets) return 0;

        return _min(sourceWithdrawable, uint256(cap) - idleAssets);
    }

    function _borrowChunkFromMarket(
        IMorphoBorrowLike morpho,
        MarketParams memory marketParams,
        uint256 targetBorrowAmount
    ) internal returns (uint256 borrowedAssets) {
        address borrower = makeAddr("fork-borrower");
        uint256 collateralAmount = 1e30;
        deal(marketParams.collateralToken, borrower, collateralAmount);

        vm.startPrank(borrower);
        IERC20Approve(marketParams.collateralToken).approve(address(morpho), type(uint256).max);
        morpho.supplyCollateral(marketParams, collateralAmount, borrower, hex"");

        uint256 attempt = targetBorrowAmount;
        for (uint256 i; i < 8; ++i) {
            try morpho.borrow(marketParams, attempt, 0, borrower, borrower) returns (uint256 assetsBorrowed, uint256) {
                vm.stopPrank();
                return assetsBorrowed;
            } catch {
                attempt /= 2;
                if (attempt == 0) break;
            }
        }
        vm.stopPrank();

        revert("unable to borrow");
    }

    function tryBorrowMarket(address morpho, MarketParams memory marketParams, uint256 targetBorrowAmount)
        external
        returns (uint256 borrowedAssets)
    {
        require(msg.sender == address(this), "only self");
        return _borrowChunkFromMarket(IMorphoBorrowLike(morpho), marketParams, targetBorrowAmount);
    }

    function _borrowToReduceLiquidity(
        IMorphoBorrowLike morpho,
        MarketParams memory marketParams,
        uint256 currentWithdrawable,
        uint256 currentAvailableLiquidity
    ) internal returns (uint256 targetWithdrawable, uint256 borrowedAssets) {
        targetWithdrawable = currentWithdrawable > 1 ? currentWithdrawable / 2 : currentWithdrawable;
        uint256 borrowAmount = currentAvailableLiquidity - targetWithdrawable;
        assertGt(borrowAmount, 0, "borrow amount is zero");

        borrowedAssets = _borrowChunkFromMarket(morpho, marketParams, borrowAmount);
        assertApproxEqRel(borrowedAssets, borrowAmount, ROUNDING_TOLERANCE_REL);
    }

    function _marketAssetsOf(IMorpho morpho, bytes32 marketId, address account) internal view returns (uint256) {
        Position memory position = morpho.position(Id.wrap(marketId), account);
        MarketState memory market = morpho.market(Id.wrap(marketId));

        if (position.supplyShares == 0 || market.totalSupplyShares == 0) return 0;
        return position.supplyShares * uint256(market.totalSupplyAssets) / uint256(market.totalSupplyShares);
    }

    function _min(uint256 x, uint256 y) internal pure returns (uint256) {
        return x < y ? x : y;
    }
}
