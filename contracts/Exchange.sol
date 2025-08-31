// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "@openzeppelin/contracts-upgradeable/access/OwnableUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

contract Exchange is Initializable, OwnableUpgradeable, UUPSUpgradeable {
    using SafeERC20 for IERC20;

    IERC20 public abcToken;
    
    // 兑换比例 (ABC:CFX = ratio:1)，支持两位小数，实际存储为ratio*100
    uint256 public exchangeRatio; // 例如4.14存为414
    
    // 合约中的ABC余额
    uint256 public abcBalance;
    
    // 待兑换订单结构
    struct PendingOrder {
        address user;
        uint256 amount;
        bool isAbcToCfx; // true: ABC->CFX, false: CFX->ABC
        uint256 timestamp;
        bool executed;
    }
    
    // 待兑换订单映射
    mapping(uint256 => PendingOrder) public pendingOrders;
    uint256 public nextOrderId;
    
    // 事件
    event ExchangeRatioUpdated(uint256 newRatio);
    event AbcDeposited(uint256 amount);
    event CfxDeposited(uint256 amount);
    event AbcWithdrawn(uint256 amount);
    event CfxWithdrawn(uint256 amount);
    event ExchangeExecuted(address user, uint256 inputAmount, uint256 outputAmount, bool isAbcToCfx);
    event PendingOrderCreated(uint256 orderId, address user, uint256 amount, bool isAbcToCfx);
    event PendingOrderExecuted(uint256 orderId);

    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {
        _disableInitializers();
    }

    function initialize(address _abcToken, address initialOwner) public initializer {
        __Ownable_init();
        __UUPSUpgradeable_init();
        
        _transferOwnership(initialOwner);
        abcToken = IERC20(_abcToken);
        exchangeRatio = 500; // 默认比例 5.00:1
        nextOrderId = 1;
    }

    function _authorizeUpgrade(address newImplementation) internal override onlyOwner {}

    // 管理员设置兑换比例，ratio支持两位小数，传入如414代表4.14
    function setExchangeRatio(uint256 _ratio) external onlyOwner {
        require(_ratio > 0, "Ratio must be greater than 0");
        exchangeRatio = _ratio;
        emit ExchangeRatioUpdated(_ratio);
    }

    // 管理员存入ABC代币
    function depositAbc(uint256 amount) external onlyOwner {
        require(amount > 0, "Amount must be greater than 0");
        abcToken.safeTransferFrom(msg.sender, address(this), amount);
        abcBalance += amount;
        emit AbcDeposited(amount);
    }

    // 管理员存入CFX
    function depositCfx() external payable onlyOwner {
        require(msg.value > 0, "Must send CFX");
        emit CfxDeposited(msg.value);
    }

    // 管理员提取ABC代币
    function withdrawAbc(uint256 amount) external onlyOwner {
        require(amount > 0, "Amount must be greater than 01");
        require(amount <= abcBalance, "Insufficient ABC balance");
        abcBalance -= amount;
        abcToken.safeTransfer(owner(), amount);
        emit AbcWithdrawn(amount);
    }

    // 管理员提取CFX
    function withdrawCfx(uint256 amount) external onlyOwner {
        require(amount > 0, "Amount must be greater than 0");
        require(amount <= address(this).balance, "Insufficient CFX balance");
        (bool success, ) = owner().call{value: amount}("");
        require(success, "CFX transfer failed");
        emit CfxWithdrawn(amount);
    }

    // 用户用ABC兑换CFX
    function exchangeAbcToCfx(uint256 abcAmount) external {
        require(abcAmount > 0, "Amount must be greater than 0");
        // 修正：计算CFX数量，支持两位小数，abcAmount为18位精度，exchangeRatio为放大100倍的整数
        uint256 cfxAmount = abcAmount *exchangeRatio  /100 ;
        
        // 检查合约CFX余额是否足够
        if (address(this).balance >= cfxAmount) {
            // 直接兑换
            abcToken.safeTransferFrom(msg.sender, address(this), abcAmount);
            abcBalance += abcAmount;
            
            (bool success, ) = msg.sender.call{value: cfxAmount}("");
            require(success, "CFX transfer failed");
            
            emit ExchangeExecuted(msg.sender, abcAmount, cfxAmount, true);
        } else {
            // 创建待兑换订单
            abcToken.safeTransferFrom(msg.sender, address(this), abcAmount);
            abcBalance += abcAmount;
            
            pendingOrders[nextOrderId] = PendingOrder({
                user: msg.sender,
                amount: abcAmount,
                isAbcToCfx: true,
                timestamp: block.timestamp,
                executed: false
            });
            
            emit PendingOrderCreated(nextOrderId, msg.sender, abcAmount, true);
            nextOrderId++;
        }
    }

    // 用户用CFX兑换ABC
    function exchangeCfxToAbc() external payable {
        require(msg.value > 0, "Must send CFX");
        // 计算ABC数量，支持两位小数，除以100
        uint256 abcAmount = msg.value * 100 / exchangeRatio;
        
        // 检查合约ABC余额是否足够
        if (abcBalance >= abcAmount) {
            // 直接兑换
            abcBalance -= abcAmount;
            abcToken.safeTransfer(msg.sender, abcAmount);
            
            emit ExchangeExecuted(msg.sender, msg.value, abcAmount, false);
        } else {
            // 创建待兑换订单
            pendingOrders[nextOrderId] = PendingOrder({
                user: msg.sender,
                amount: msg.value,
                isAbcToCfx: false,
                timestamp: block.timestamp,
                executed: false
            });
            
            emit PendingOrderCreated(nextOrderId, msg.sender, msg.value, false);
            nextOrderId++;
        }
    }

    // 管理员执行待兑换订单
    function executePendingOrder(uint256 orderId) external onlyOwner {
        PendingOrder storage order = pendingOrders[orderId];
        require(order.user != address(0), "Order does not exist");
        require(!order.executed, "Order already executed");
        
        order.executed = true;
        
        if (order.isAbcToCfx) {
            // ABC -> CFX
            uint256 cfxAmount = order.amount * 100 / exchangeRatio;
            require(address(this).balance >= cfxAmount, "Insufficient CFX balance");
            
            (bool success, ) = order.user.call{value: cfxAmount}("");
            require(success, "CFX transfer failed");
            
            emit ExchangeExecuted(order.user, order.amount, cfxAmount, true);
        } else {
            // CFX -> ABC
            uint256 abcAmount = order.amount * 100 / exchangeRatio;
            require(abcBalance >= abcAmount, "Insufficient ABC balance");
            
            abcBalance -= abcAmount;
            abcToken.safeTransfer(order.user, abcAmount);
            
            emit ExchangeExecuted(order.user, order.amount, abcAmount, false);
        }
        
        emit PendingOrderExecuted(orderId);
    }

    // 获取待兑换订单信息
    function getPendingOrder(uint256 orderId) external view returns (
        address user,
        uint256 amount,
        bool isAbcToCfx,
        uint256 timestamp,
        bool executed
    ) {
        PendingOrder memory order = pendingOrders[orderId];
        return (order.user, order.amount, order.isAbcToCfx, order.timestamp, order.executed);
    }

    // 获取合约信息
    function getContractInfo() external view returns (
        uint256 _exchangeRatio,
        uint256 _abcBalance,
        uint256 _cfxBalance,
        uint256 _totalOrders
    ) {
        return (exchangeRatio, abcBalance, address(this).balance, nextOrderId - 1);
    }

    // 接收CFX
    receive() external payable {}
} 