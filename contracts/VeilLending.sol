// SPDX-License-Identifier: BSD-3-Clause-Clear
pragma solidity ^0.8.24;

import { FHE, euint64, externalEuint64, ebool } from "@fhevm/solidity/lib/FHE.sol";
import { ZamaEthereumConfig } from "@fhevm/solidity/config/ZamaConfig.sol";
import { IERC7984 } from "@openzeppelin/confidential-contracts/interfaces/IERC7984.sol";

contract VeilLending is ZamaEthereumConfig {

    uint64 public constant LIQUIDATION_THRESHOLD = 150;
    uint64 public constant MAX_LTV_PCT           = 66;

    IERC7984 public immutable collateralToken;
    IERC7984 public immutable debtToken;

    struct Position {
        euint64 collateral;
        euint64 debt;
        bool    exists;
        uint256 openedAt;
    }

    address public owner;
    uint256 public totalPositions;
    euint64 private _encryptedZero;

    mapping(address => Position) private _positions;
    mapping(address => bool)     public  hasPosition;

    event PositionOpened(address indexed user, uint256 timestamp);
    event CollateralAdded(address indexed user, uint256 timestamp);
    event Borrowed(address indexed user, uint256 timestamp);
    event Repaid(address indexed user, uint256 timestamp);
    event PositionClosed(address indexed user, uint256 timestamp);
    event LiquidationAttempted(address indexed liquidator, address indexed target, uint256 timestamp);
    event PoolFunded(address indexed funder, uint256 timestamp);

    constructor(address _collateralToken, address _debtToken) {
        owner           = msg.sender;
        collateralToken = IERC7984(_collateralToken);
        debtToken       = IERC7984(_debtToken);
        _encryptedZero  = FHE.asEuint64(0);
        FHE.allowThis(_encryptedZero);
    }

    modifier onlyOwner() {
        require(msg.sender == owner, "VEIL: not owner");
        _;
    }

    modifier positionExists(address user) {
        require(_positions[user].exists, "VEIL: no position");
        _;
    }

    function openPosition(
        externalEuint64 encryptedAmount,
        bytes calldata  inputProof
    ) external {
        require(!_positions[msg.sender].exists, "VEIL: position already open");

        euint64 amount = FHE.fromExternal(encryptedAmount, inputProof);

        FHE.allowTransient(amount, address(collateralToken));
        euint64 received = collateralToken.confidentialTransferFrom(
            msg.sender, address(this), amount
        );

        _positions[msg.sender] = Position({
            collateral : received,
            debt       : _encryptedZero,
            exists     : true,
            openedAt   : block.timestamp
        });

        hasPosition[msg.sender] = true;
        totalPositions++;

        FHE.allowThis(_positions[msg.sender].collateral);
        FHE.allowThis(_positions[msg.sender].debt);
        FHE.allow(_positions[msg.sender].collateral, msg.sender);
        FHE.allow(_positions[msg.sender].debt, msg.sender);

        emit PositionOpened(msg.sender, block.timestamp);
    }

    function addCollateral(
        externalEuint64 encryptedAmount,
        bytes calldata  inputProof
    ) external positionExists(msg.sender) {

        euint64 amount = FHE.fromExternal(encryptedAmount, inputProof);

        FHE.allowTransient(amount, address(collateralToken));
        euint64 received = collateralToken.confidentialTransferFrom(
            msg.sender, address(this), amount
        );

        _positions[msg.sender].collateral = FHE.add(
            _positions[msg.sender].collateral,
            received
        );

        FHE.allowThis(_positions[msg.sender].collateral);
        FHE.allow(_positions[msg.sender].collateral, msg.sender);

        emit CollateralAdded(msg.sender, block.timestamp);
    }

    function borrow(
        externalEuint64 encryptedAmount,
        bytes calldata  inputProof
    ) external positionExists(msg.sender) {

        euint64 amount  = FHE.fromExternal(encryptedAmount, inputProof);
        euint64 newDebt = FHE.add(_positions[msg.sender].debt, amount);

        ebool withinLTV = FHE.le(
            FHE.mul(newDebt, FHE.asEuint64(100)),
            FHE.mul(_positions[msg.sender].collateral, FHE.asEuint64(MAX_LTV_PCT))
        );

        euint64 actualBorrow = FHE.select(withinLTV, amount, _encryptedZero);

        _positions[msg.sender].debt = FHE.add(
            _positions[msg.sender].debt,
            actualBorrow
        );

        FHE.allowThis(_positions[msg.sender].debt);
        FHE.allow(_positions[msg.sender].debt, msg.sender);

        FHE.allow(actualBorrow, address(debtToken));
        debtToken.confidentialTransfer(msg.sender, actualBorrow);

        emit Borrowed(msg.sender, block.timestamp);
    }

    function repay(
        externalEuint64 encryptedAmount,
        bytes calldata  inputProof
    ) external positionExists(msg.sender) {

        euint64 amount = FHE.fromExternal(encryptedAmount, inputProof);

        FHE.allowTransient(amount, address(debtToken));
        euint64 received = debtToken.confidentialTransferFrom(
            msg.sender, address(this), amount
        );

        euint64 repaid = FHE.min(received, _positions[msg.sender].debt);

        _positions[msg.sender].debt = FHE.sub(
            _positions[msg.sender].debt,
            repaid
        );

        FHE.allowThis(_positions[msg.sender].debt);
        FHE.allow(_positions[msg.sender].debt, msg.sender);

        emit Repaid(msg.sender, block.timestamp);
    }

    function closePosition() external positionExists(msg.sender) {

        ebool noDebt = FHE.eq(_positions[msg.sender].debt, _encryptedZero);
        euint64 collateralToReturn = FHE.select(
            noDebt,
            _positions[msg.sender].collateral,
            _encryptedZero
        );

        delete _positions[msg.sender];
        hasPosition[msg.sender] = false;
        totalPositions--;

        FHE.allow(collateralToReturn, address(collateralToken));
        collateralToken.confidentialTransfer(msg.sender, collateralToReturn);

        emit PositionClosed(msg.sender, block.timestamp);
    }

    function liquidate(address target) external positionExists(target) {
        require(target != msg.sender, "VEIL: cannot self-liquidate");

        Position storage pos = _positions[target];

        euint64 scaledCollateral = FHE.mul(pos.collateral, FHE.asEuint64(100));
        euint64 liquidationLevel = FHE.mul(pos.debt, FHE.asEuint64(LIQUIDATION_THRESHOLD));
        ebool   isLiquidatable   = FHE.lt(scaledCollateral, liquidationLevel);
        ebool   hasDebt          = FHE.gt(pos.debt, _encryptedZero);
        ebool   shouldLiquidate  = FHE.and(isLiquidatable, hasDebt);

        euint64 toSendLiquidator = FHE.select(shouldLiquidate, pos.collateral, _encryptedZero);
        euint64 toReturnTarget   = FHE.select(shouldLiquidate, _encryptedZero, pos.collateral);

        delete _positions[target];
        hasPosition[target] = false;
        totalPositions--;

        FHE.allow(toSendLiquidator, address(collateralToken));
        collateralToken.confidentialTransfer(msg.sender, toSendLiquidator);

        FHE.allow(toReturnTarget, address(collateralToken));
        collateralToken.confidentialTransfer(target, toReturnTarget);

        emit LiquidationAttempted(msg.sender, target, block.timestamp);
    }

    function addLiquidity(
        externalEuint64 encryptedAmount,
        bytes calldata  inputProof
    ) external onlyOwner {
        euint64 amount = FHE.fromExternal(encryptedAmount, inputProof);
        FHE.allowTransient(amount, address(collateralToken));
        collateralToken.confidentialTransferFrom(msg.sender, address(this), amount);
        emit PoolFunded(msg.sender, block.timestamp);
    }

    function getCollateralHandle(address user) external positionExists(user) returns (euint64) {
        FHE.allow(_positions[user].collateral, msg.sender);
        return _positions[user].collateral;
    }

    function getDebtHandle(address user) external positionExists(user) returns (euint64) {
        FHE.allow(_positions[user].debt, msg.sender);
        return _positions[user].debt;
    }

    function getStats() external view returns (uint256 positions) {
        return totalPositions;
    }
}
