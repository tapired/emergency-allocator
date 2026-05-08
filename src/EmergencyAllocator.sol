// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity ^0.8.20;

type Id is bytes32;

struct MarketParams {
    address loanToken;
    address collateralToken;
    address oracle;
    address irm;
    uint256 lltv;
}

struct MarketAllocation {
    MarketParams marketParams;
    uint256 assets;
}

struct Position {
    uint256 supplyShares;
    uint128 borrowShares;
    uint128 collateral;
}

struct MarketState {
    uint128 totalSupplyAssets;
    uint128 totalSupplyShares;
    uint128 totalBorrowAssets;
    uint128 totalBorrowShares;
    uint128 lastUpdate;
    uint128 fee;
}

interface IERC20Minimal {
    function balanceOf(address account) external view returns (uint256);
}

interface IMorpho {
    function accrueInterest(MarketParams memory marketParams) external;
    function idToMarketParams(Id id) external view returns (MarketParams memory);
    function market(Id id) external view returns (MarketState memory);
    function position(Id id, address user) external view returns (Position memory);
}

interface IMetaMorphoV1_1 {
    function MORPHO() external view returns (IMorpho);
    function reallocate(MarketAllocation[] calldata allocations) external;
}

interface IVaultV2 {
    function deallocate(address adapter, bytes memory data, uint256 assets) external;
}

interface IMorphoMarketV1AdapterV2 {
    function morpho() external view returns (address);
    function supplyShares(bytes32 marketId) external view returns (uint256);
}

contract EmergencyAllocator {
    error Unauthorized();
    error ZeroAddress();
    error IdenticalMarketIds();
    error UnknownMarket(bytes32 marketId);
    error NoPosition(bytes32 marketId);

    event OwnerSet(address indexed oldOwner, address indexed newOwner);
    event OperatorSet(address indexed account, bool isOperator);
    event VaultV1EmergencyReallocate(
        address indexed vault, bytes32 indexed marketId, bytes32 indexed idleMarketId, uint256 withdrawnAssets
    );
    event VaultV2EmergencyDeallocate(
        address indexed vault, address indexed adapter, bytes32 morphoMarketId, uint256 withdrawnAssets
    );

    address public owner;
    mapping(address account => bool) public isOperator;

    modifier onlyAuthorized() {
        if (msg.sender != owner && !isOperator[msg.sender]) revert Unauthorized();
        _;
    }

    constructor(address owner_) {
        if (owner_ == address(0)) revert ZeroAddress();
        owner = owner_;
        emit OwnerSet(address(0), owner_);
    }

    function setOwner(address newOwner) external {
        if (msg.sender != owner) revert Unauthorized();
        if (newOwner == address(0)) revert ZeroAddress();
        emit OwnerSet(owner, newOwner);
        owner = newOwner;
    }

    function setOperator(address account, bool newIsOperator) external onlyAuthorized {
        isOperator[account] = newIsOperator;
        emit OperatorSet(account, newIsOperator);
    }

    function previewMetaMorphoWithdrawable(address vault, bytes32 marketId)
        external
        view
        returns (uint256 positionAssets, uint256 availableLiquidity, uint256 withdrawableAssets)
    {
        IMorpho morpho = IMetaMorphoV1_1(vault).MORPHO();
        MarketParams memory marketParams = _resolveMarket(morpho, marketId);
        return _withdrawableForAccount(morpho, marketId, marketParams, vault);
    }

    function previewVaultV2Withdrawable(address adapter, MarketParams calldata marketParams)
        external
        view
        returns (
            bytes32 morphoMarketId,
            address morpho,
            uint256 positionAssets,
            uint256 availableLiquidity,
            uint256 withdrawableAssets
        )
    {
        morphoMarketId = _morphoMarketId(marketParams);

        IMorpho morpho_ = IMorpho(IMorphoMarketV1AdapterV2(adapter).morpho());
        uint256 supplyShares = IMorphoMarketV1AdapterV2(adapter).supplyShares(morphoMarketId);
        if (supplyShares == 0) revert NoPosition(morphoMarketId);

        (positionAssets, availableLiquidity, withdrawableAssets) =
            _withdrawable(morpho_, Id.wrap(morphoMarketId), marketParams, supplyShares);
        morpho = address(morpho_);
    }

    function emergencyReallocateVaultV1(address vault, bytes32 marketId, bytes32 idleMarketId)
        external
        onlyAuthorized
        returns (uint256 withdrawnAssets)
    {
        if (marketId == idleMarketId) revert IdenticalMarketIds();

        IMetaMorphoV1_1 metaMorpho = IMetaMorphoV1_1(vault);
        IMorpho morpho = metaMorpho.MORPHO();

        MarketParams memory marketParams = _resolveMarket(morpho, marketId);
        MarketParams memory idleMarketParams = _resolveMarket(morpho, idleMarketId);

        morpho.accrueInterest(marketParams);
        morpho.accrueInterest(idleMarketParams);

        (uint256 positionAssets,, uint256 withdrawableAssets) =
            _withdrawableForAccount(morpho, marketId, marketParams, vault);

        if (withdrawableAssets == 0) return 0;

        MarketAllocation[] memory allocations = new MarketAllocation[](2);
        allocations[0] = MarketAllocation({marketParams: marketParams, assets: positionAssets - withdrawableAssets});
        allocations[1] = MarketAllocation({marketParams: idleMarketParams, assets: type(uint256).max});

        metaMorpho.reallocate(allocations);

        emit VaultV1EmergencyReallocate(vault, marketId, idleMarketId, withdrawableAssets);
        return withdrawableAssets;
    }

    function emergencyDeallocateVaultV2(address vault, address adapter, bytes32 marketId)
        external
        onlyAuthorized
        returns (uint256 withdrawnAssets)
    {
        IMorpho morpho = IMorpho(IMorphoMarketV1AdapterV2(adapter).morpho());
        MarketParams memory marketParams = _resolveMarket(morpho, marketId);
        uint256 supplyShares = IMorphoMarketV1AdapterV2(adapter).supplyShares(marketId);
        if (supplyShares == 0) revert NoPosition(marketId);

        morpho.accrueInterest(marketParams);

        (,, withdrawnAssets) = _withdrawable(morpho, Id.wrap(marketId), marketParams, supplyShares);
        if (withdrawnAssets == 0) return 0;

        IVaultV2(vault).deallocate(adapter, abi.encode(marketParams), withdrawnAssets);

        emit VaultV2EmergencyDeallocate(vault, adapter, marketId, withdrawnAssets);
    }

    function _resolveMarket(IMorpho morpho, bytes32 marketId) internal view returns (MarketParams memory marketParams) {
        marketParams = morpho.idToMarketParams(Id.wrap(marketId));
        if (marketParams.loanToken == address(0)) revert UnknownMarket(marketId);
    }

    function _withdrawable(IMorpho morpho, Id marketId, MarketParams memory marketParams, uint256 supplyShares)
        internal
        view
        returns (uint256 positionAssets, uint256 availableLiquidity, uint256 withdrawableAssets)
    {
        MarketState memory market = morpho.market(marketId);
        if (supplyShares == 0 || market.totalSupplyShares == 0) return (0, 0, 0);

        positionAssets = supplyShares * uint256(market.totalSupplyAssets) / uint256(market.totalSupplyShares);
        availableLiquidity = _min(
            uint256(market.totalSupplyAssets) - uint256(market.totalBorrowAssets),
            IERC20Minimal(marketParams.loanToken).balanceOf(address(morpho))
        );
        withdrawableAssets = _min(positionAssets, availableLiquidity);
    }

    function _vaultSupplyShares(IMorpho morpho, Id marketId, address vault) internal view returns (uint256) {
        return morpho.position(marketId, vault).supplyShares;
    }

    function _withdrawableForAccount(
        IMorpho morpho,
        bytes32 marketId,
        MarketParams memory marketParams,
        address account
    ) internal view returns (uint256 positionAssets, uint256 availableLiquidity, uint256 withdrawableAssets) {
        Id id = Id.wrap(marketId);
        return _withdrawable(morpho, id, marketParams, _vaultSupplyShares(morpho, id, account));
    }

    function _min(uint256 x, uint256 y) internal pure returns (uint256) {
        return x < y ? x : y;
    }

    function _morphoMarketId(MarketParams memory marketParams) internal pure returns (bytes32 marketId) {
        assembly ("memory-safe") {
            marketId := keccak256(marketParams, 160)
        }
    }
}
