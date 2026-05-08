// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity ^0.8.20;

import {Test} from "forge-std/Test.sol";

import {
    EmergencyAllocator,
    Id,
    IERC20Minimal,
    IMetaMorphoV1_1,
    IMorpho,
    IVaultV2,
    MarketAllocation,
    MarketParams,
    MarketState,
    Position
} from "../src/EmergencyAllocator.sol";

contract EmergencyAllocatorTest is Test {
    MockERC20 internal asset;
    MockMorpho internal morpho;
    EmergencyAllocator internal allocator;
    MockMetaMorphoV1_1 internal metaMorpho;
    MockVaultV2 internal vaultV2;
    MockMorphoMarketV1AdapterV2 internal adapter;
    MarketParams internal sourceMarket;
    MarketParams internal idleMarket;
    bytes32 internal sourceMarketId;
    bytes32 internal idleMarketId;

    function setUp() public {
        asset = new MockERC20();
        morpho = new MockMorpho();
        allocator = new EmergencyAllocator(address(this));

        sourceMarket = MarketParams({
            loanToken: address(asset),
            collateralToken: address(0xBEEF),
            oracle: address(0xCAFE),
            irm: address(0x1111),
            lltv: 0
        });

        idleMarket = MarketParams({
            loanToken: address(asset),
            collateralToken: address(0xF00D),
            oracle: address(0xFACE),
            irm: address(0x2222),
            lltv: 0
        });

        sourceMarketId = _marketId(sourceMarket);
        idleMarketId = _marketId(idleMarket);

        morpho.setMarketParams(sourceMarketId, sourceMarket);
        morpho.setMarketParams(idleMarketId, idleMarket);
    }

    function test_emergencyReallocateMetaMorphoWithdrawsAvailableLiquidity() public {
        metaMorpho = new MockMetaMorphoV1_1(address(asset), morpho);
        metaMorpho.setAllocator(address(allocator), true);
        metaMorpho.setMarketEnabled(sourceMarketId, true);
        metaMorpho.setMarketEnabled(idleMarketId, true);

        morpho.setMarketState(sourceMarketId, 1_000, 1_000, 800);
        morpho.setSupplyShares(sourceMarketId, address(metaMorpho), 350);

        asset.mint(address(morpho), 400);

        uint256 withdrawnAssets =
            allocator.emergencyReallocateVaultV1(address(metaMorpho), sourceMarketId, idleMarketId);

        assertEq(withdrawnAssets, 200);
        assertEq(morpho.position(Id.wrap(sourceMarketId), address(metaMorpho)).supplyShares, 150);
        assertEq(morpho.position(Id.wrap(idleMarketId), address(metaMorpho)).supplyShares, 200);
        assertEq(asset.balanceOf(address(metaMorpho)), 0);
    }

    function test_emergencyDeallocateVaultV2WithdrawsUsingExplicitAdapterAndMarketParams() public {
        vaultV2 = new MockVaultV2(address(asset));
        adapter = new MockMorphoMarketV1AdapterV2(address(vaultV2), address(asset), morpho);

        vaultV2.setAllocator(address(allocator), true);

        morpho.setMarketState(sourceMarketId, 700, 700, 580);
        morpho.setSupplyShares(sourceMarketId, address(adapter), 300);
        adapter.setSupplyShares(sourceMarketId, 300);

        asset.mint(address(morpho), 200);

        uint256 withdrawnAssets =
            allocator.emergencyDeallocateVaultV2(address(vaultV2), address(adapter), sourceMarketId);

        assertEq(withdrawnAssets, 120);
        assertEq(asset.balanceOf(address(vaultV2)), 120);
        assertEq(morpho.position(Id.wrap(sourceMarketId), address(adapter)).supplyShares, 180);
        assertEq(adapter.supplyShares(sourceMarketId), 180);
    }

    function test_previewVaultV2WithdrawableReturnsConservativeNumbers() public {
        vaultV2 = new MockVaultV2(address(asset));
        adapter = new MockMorphoMarketV1AdapterV2(address(vaultV2), address(asset), morpho);

        morpho.setMarketState(sourceMarketId, 500, 500, 420);
        morpho.setSupplyShares(sourceMarketId, address(adapter), 140);
        adapter.setSupplyShares(sourceMarketId, 140);
        asset.mint(address(morpho), 300);

        (
            bytes32 morphoMarketId,
            address resolvedMorpho,
            uint256 positionAssets,
            uint256 availableLiquidity,
            uint256 withdrawableAssets
        ) = allocator.previewVaultV2Withdrawable(address(adapter), sourceMarket);

        assertEq(morphoMarketId, sourceMarketId);
        assertEq(resolvedMorpho, address(morpho));
        assertEq(positionAssets, 140);
        assertEq(availableLiquidity, 80);
        assertEq(withdrawableAssets, 80);
    }

    function test_emergencyReallocateVaultV1ReturnsZeroWhenNoLiquidity() public {
        metaMorpho = new MockMetaMorphoV1_1(address(asset), morpho);
        metaMorpho.setAllocator(address(allocator), true);
        metaMorpho.setMarketEnabled(sourceMarketId, true);
        metaMorpho.setMarketEnabled(idleMarketId, true);

        morpho.setMarketState(sourceMarketId, 1_000, 1_000, 1_000);
        morpho.setSupplyShares(sourceMarketId, address(metaMorpho), 350);

        uint256 withdrawnAssets =
            allocator.emergencyReallocateVaultV1(address(metaMorpho), sourceMarketId, idleMarketId);

        assertEq(withdrawnAssets, 0);
        assertEq(morpho.position(Id.wrap(sourceMarketId), address(metaMorpho)).supplyShares, 350);
        assertEq(morpho.position(Id.wrap(idleMarketId), address(metaMorpho)).supplyShares, 0);
    }

    function test_emergencyDeallocateVaultV2ReturnsZeroWhenNoLiquidity() public {
        vaultV2 = new MockVaultV2(address(asset));
        adapter = new MockMorphoMarketV1AdapterV2(address(vaultV2), address(asset), morpho);

        vaultV2.setAllocator(address(allocator), true);

        morpho.setMarketState(sourceMarketId, 700, 700, 700);
        morpho.setSupplyShares(sourceMarketId, address(adapter), 300);
        adapter.setSupplyShares(sourceMarketId, 300);

        uint256 withdrawnAssets =
            allocator.emergencyDeallocateVaultV2(address(vaultV2), address(adapter), sourceMarketId);

        assertEq(withdrawnAssets, 0);
        assertEq(asset.balanceOf(address(vaultV2)), 0);
        assertEq(morpho.position(Id.wrap(sourceMarketId), address(adapter)).supplyShares, 300);
        assertEq(adapter.supplyShares(sourceMarketId), 300);
    }

    function _marketId(MarketParams memory marketParams) internal pure returns (bytes32 marketId) {
        assembly ("memory-safe") {
            marketId := keccak256(marketParams, 160)
        }
    }
}

contract MockERC20 is IERC20Minimal {
    mapping(address account => uint256) public balanceOf;
    mapping(address owner => mapping(address spender => uint256)) public allowance;

    function mint(address to, uint256 amount) external {
        balanceOf[to] += amount;
    }

    function approve(address spender, uint256 amount) external returns (bool) {
        allowance[msg.sender][spender] = amount;
        return true;
    }

    function transfer(address to, uint256 amount) external returns (bool) {
        balanceOf[msg.sender] -= amount;
        balanceOf[to] += amount;
        return true;
    }

    function transferFrom(address from, address to, uint256 amount) external returns (bool) {
        uint256 allowed = allowance[from][msg.sender];
        if (allowed != type(uint256).max) allowance[from][msg.sender] = allowed - amount;
        balanceOf[from] -= amount;
        balanceOf[to] += amount;
        return true;
    }
}

contract MockMorpho is IMorpho {
    mapping(bytes32 marketId => MarketParams) internal marketParamsById;
    mapping(bytes32 marketId => MarketState) internal marketStateById;
    mapping(bytes32 marketId => mapping(address user => Position)) internal positionByIdAndUser;

    function setMarketParams(bytes32 marketId, MarketParams memory marketParams) external {
        marketParamsById[marketId] = marketParams;
    }

    function setMarketState(
        bytes32 marketId,
        uint128 totalSupplyAssets,
        uint128 totalSupplyShares,
        uint128 totalBorrowAssets
    ) external {
        marketStateById[marketId] = MarketState({
            totalSupplyAssets: totalSupplyAssets,
            totalSupplyShares: totalSupplyShares,
            totalBorrowAssets: totalBorrowAssets,
            totalBorrowShares: 0,
            lastUpdate: 0,
            fee: 0
        });
    }

    function setSupplyShares(bytes32 marketId, address user, uint256 supplyShares) external {
        positionByIdAndUser[marketId][user].supplyShares = supplyShares;
    }

    function accrueInterest(MarketParams memory) external pure {}

    function idToMarketParams(Id id) external view returns (MarketParams memory) {
        return marketParamsById[Id.unwrap(id)];
    }

    function market(Id id) external view returns (MarketState memory) {
        return marketStateById[Id.unwrap(id)];
    }

    function position(Id id, address user) external view returns (Position memory) {
        return positionByIdAndUser[Id.unwrap(id)][user];
    }

    function supply(MarketParams memory marketParams, uint256 assets, uint256, address onBehalf, bytes memory)
        external
        returns (uint256, uint256)
    {
        bytes32 marketId = _findId(marketParams);
        MockERC20(marketParams.loanToken).transferFrom(msg.sender, address(this), assets);
        marketStateById[marketId].totalSupplyAssets += uint128(assets);
        marketStateById[marketId].totalSupplyShares += uint128(assets);
        positionByIdAndUser[marketId][onBehalf].supplyShares += assets;
        return (assets, assets);
    }

    function withdraw(
        MarketParams memory marketParams,
        uint256 assets,
        uint256 shares,
        address onBehalf,
        address receiver
    ) external returns (uint256, uint256) {
        bytes32 marketId = _findId(marketParams);
        MarketState storage marketState = marketStateById[marketId];
        Position storage positionState = positionByIdAndUser[marketId][onBehalf];

        if (shares == 0) shares = assets;
        if (assets == 0) assets = shares;

        uint256 liquidity = marketState.totalSupplyAssets - marketState.totalBorrowAssets;
        require(assets <= liquidity, "liquidity");

        positionState.supplyShares -= shares;
        marketState.totalSupplyAssets -= uint128(assets);
        marketState.totalSupplyShares -= uint128(shares);

        MockERC20(marketParams.loanToken).transfer(receiver, assets);

        return (assets, shares);
    }

    function _findId(MarketParams memory marketParams) internal view returns (bytes32 marketId) {
        marketId = _marketId(marketParams);
        require(marketParamsById[marketId].loanToken != address(0), "unknown market");
    }

    function _marketId(MarketParams memory marketParams) internal pure returns (bytes32 marketId) {
        assembly ("memory-safe") {
            marketId := keccak256(marketParams, 160)
        }
    }
}

contract MockMetaMorphoV1_1 is IMetaMorphoV1_1 {
    MockERC20 internal immutable asset;
    IMorpho public immutable MORPHO;

    mapping(address account => bool) public isAllocator;
    mapping(bytes32 marketId => bool) public marketEnabled;

    constructor(address asset_, IMorpho morpho_) {
        asset = MockERC20(asset_);
        MORPHO = morpho_;
        asset.approve(address(morpho_), type(uint256).max);
    }

    function setAllocator(address account, bool newIsAllocator) external {
        isAllocator[account] = newIsAllocator;
    }

    function setMarketEnabled(bytes32 marketId, bool enabled) external {
        marketEnabled[marketId] = enabled;
    }

    function reallocate(MarketAllocation[] calldata allocations) external {
        require(isAllocator[msg.sender], "unauthorized");

        uint256 totalSupplied;
        uint256 totalWithdrawn;

        for (uint256 i; i < allocations.length; ++i) {
            MarketAllocation memory allocation = allocations[i];
            bytes32 marketId = _findId(allocation.marketParams);
            require(marketEnabled[marketId], "disabled");

            uint256 currentShares = MORPHO.position(Id.wrap(marketId), address(this)).supplyShares;
            MarketState memory marketState = MORPHO.market(Id.wrap(marketId));
            uint256 currentAssets = marketState.totalSupplyShares == 0
                ? 0
                : currentShares * uint256(marketState.totalSupplyAssets) / uint256(marketState.totalSupplyShares);

            uint256 withdrawn = currentAssets > allocation.assets ? currentAssets - allocation.assets : 0;
            if (withdrawn > 0) {
                uint256 shares = allocation.assets == 0 ? currentShares : 0;
                (uint256 withdrawnAssets,) = MockMorpho(address(MORPHO))
                    .withdraw(allocation.marketParams, withdrawn, shares, address(this), address(this));
                totalWithdrawn += withdrawnAssets;
            } else {
                uint256 suppliedAssets = allocation.assets == type(uint256).max
                    ? totalWithdrawn - totalSupplied
                    : allocation.assets > currentAssets ? allocation.assets - currentAssets : 0;

                if (suppliedAssets == 0) continue;

                MockMorpho(address(MORPHO)).supply(allocation.marketParams, suppliedAssets, 0, address(this), hex"");
                totalSupplied += suppliedAssets;
            }
        }
    }

    function _findId(MarketParams memory marketParams) internal pure returns (bytes32 marketId) {
        assembly ("memory-safe") {
            marketId := keccak256(marketParams, 160)
        }
    }
}

contract MockVaultV2 is IVaultV2 {
    MockERC20 internal immutable asset;

    mapping(address account => bool) public isAllocator;

    constructor(address asset_) {
        asset = MockERC20(asset_);
    }

    function setAllocator(address account, bool newIsAllocator) external {
        isAllocator[account] = newIsAllocator;
    }

    function deallocate(address adapter, bytes memory data, uint256 assets) external {
        require(isAllocator[msg.sender], "unauthorized");
        MockMorphoMarketV1AdapterV2(adapter).deallocate(data, assets, msg.sig, msg.sender);
        asset.transferFrom(adapter, address(this), assets);
    }
}

contract MockMorphoMarketV1AdapterV2 {
    MockERC20 internal immutable asset;
    address public immutable parentVault;
    address public immutable morpho;

    mapping(bytes32 marketId => uint256) public supplyShares;

    constructor(address parentVault_, address asset_, IMorpho morpho_) {
        parentVault = parentVault_;
        asset = MockERC20(asset_);
        morpho = address(morpho_);
        asset.approve(parentVault_, type(uint256).max);
    }

    function setSupplyShares(bytes32 marketId, uint256 shares) external {
        supplyShares[marketId] = shares;
    }

    function deallocate(bytes memory data, uint256 assets, bytes4, address)
        external
        returns (bytes32[] memory ids, int256 change)
    {
        require(msg.sender == parentVault, "unauthorized");

        MarketParams memory marketParams = abi.decode(data, (MarketParams));
        bytes32 marketId = _findId(marketParams);

        (, uint256 burnedShares) = MockMorpho(morpho).withdraw(marketParams, assets, 0, address(this), address(this));
        supplyShares[marketId] -= burnedShares;

        ids = new bytes32[](1);
        ids[0] = marketId;
        change = -int256(assets);
    }

    function _findId(MarketParams memory marketParams) internal pure returns (bytes32 marketId) {
        assembly ("memory-safe") {
            marketId := keccak256(marketParams, 160)
        }
    }
}
