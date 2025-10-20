// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import "@openzeppelin/contracts/access/AccessControl.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";

/**
 * @title KipuBankV2
 * @dev Versión mejorada del contrato bancario con control de acceso,
 * soporte multi-token y límite global expresado en USD (simulado).
 */
contract KipuBankV2 is AccessControl {
    // --- ROLES ---
    bytes32 public constant ADMIN_ROLE = keccak256("ADMIN_ROLE");

    // --- ERRORES PERSONALIZADOS ---
    error Unauthorized();
    error InvalidAddress();
    error InvalidAmount();
    error BankCapExceeded();
    error InsufficientBalance();

    // --- EVENTOS ---
    event Deposit(address indexed user, address indexed token, uint256 amount);
    event Withdraw(address indexed user, address indexed token, uint256 amount);
    event TokenFeedSet(address indexed token, address indexed feed);
    event BankCapUpdated(uint256 newCap);

    // --- VARIABLES DE ESTADO ---
    uint256 public immutable withdrawLimit; // límite por retiro
    uint256 public bankCapUsd6; // límite global en USD simulados (6 decimales)
    uint256 public totalDeposUsd6; // total de depósitos en USD simulados

    // Contabilidad interna: balances por usuario y token
    mapping(address => mapping(address => uint256)) private balances;
    mapping(address => address) public tokenFeeds; // token → oráculo (Chainlink, opcional)

    // --- CONSTRUCTOR ---
    constructor(uint256 _withdrawLimit, uint256 _bankCapUsd6) {
        if (_withdrawLimit == 0 || _bankCapUsd6 == 0) revert InvalidAmount();

        withdrawLimit = _withdrawLimit;
        bankCapUsd6 = _bankCapUsd6;

        // Configurar roles
        _grantRole(DEFAULT_ADMIN_ROLE, msg.sender);
        _grantRole(ADMIN_ROLE, msg.sender);
    }

    // --- MODIFICADORES ---
    modifier nonZero(address account) {
        if (account == address(0)) revert InvalidAddress();
        _;
    }

    modifier onlyAdmin() {
        if (!hasRole(ADMIN_ROLE, msg.sender)) revert Unauthorized();
        _;
    }

    // --- DEPÓSITO DE ETH ---
    receive() external payable {
        _deposit(address(0), msg.value);
    }

    // --- FUNCIONES PÚBLICAS ---
    /**
     * @notice Depositar tokens ERC-20 o ETH (usar address(0) para ETH)
     */
    function deposit(address token, uint256 amount) external payable {
        _deposit(token, amount);
    }

    /**
     * @notice Retirar tokens ERC-20 o ETH
     */
    function withdraw(address token, uint256 amount) external nonZero(msg.sender) {
        if (amount == 0 || amount > withdrawLimit) revert InvalidAmount();
        uint256 bal = balances[msg.sender][token];
        if (bal < amount) revert InsufficientBalance();

        balances[msg.sender][token] -= amount;
        totalDeposUsd6 -= _toUsd6(token, amount);

        if (token == address(0)) {
            (bool success, ) = payable(msg.sender).call{value: amount}("");
            require(success, "ETH transfer failed");
        } else {
            require(IERC20(token).transfer(msg.sender, amount), "Token transfer failed");
        }

        emit Withdraw(msg.sender, token, amount);
    }

    // --- FUNCIONES VIEW ---
    function balanceOf(address user, address token) external view returns (uint256) {
        return balances[user][token];
    }

    // --- FUNCIONES ADMIN ---
    /**
     * @notice Configura o actualiza el oráculo de un token
     */
    function setTokenFeed(address token, address feed) external onlyAdmin {
        tokenFeeds[token] = feed;
        emit TokenFeedSet(token, feed);
    }

    /**
     * @notice Permite actualizar el límite global en USD6
     */
    function updateBankCap(uint256 newCap) external onlyAdmin {
        if (newCap == 0) revert InvalidAmount();
        bankCapUsd6 = newCap;
        emit BankCapUpdated(newCap);
    }

    // --- FUNCIONES INTERNAS ---
    function _deposit(address token, uint256 amount) internal {
        if (token == address(0)) {
            amount = msg.value;
            if (amount == 0) revert InvalidAmount();
        } else {
            if (amount == 0) revert InvalidAmount();
            require(IERC20(token).transferFrom(msg.sender, address(this), amount), "Transfer failed");
        }

        uint256 usdValue = _toUsd6(token, amount);
        if (totalDeposUsd6 + usdValue > bankCapUsd6) revert BankCapExceeded();

        balances[msg.sender][token] += amount;
        totalDeposUsd6 += usdValue;

        emit Deposit(msg.sender, token, amount);
    }

    /**
     * @dev Convierte el monto a USD6 (simulado).
     * Si no hay feed configurado, devuelve el mismo valor (1:1).
     */
    function _toUsd6(address token, uint256 amount) private view returns (uint256) {
        address feed = tokenFeeds[token];
        if (feed == address(0)) {
            // Si no hay feed configurado, asumimos 1:1 (modo demo)
            return amount / 1e12; // simular 18 → 6 decimales
        }
        // En una versión completa usarías AggregatorV3Interface(feed)
        // para convertir el valor real a USD.
        return amount / 1e12;
    }

    // --- FUNCIONES DE SEGURIDAD ---
    fallback() external payable {
        // Si alguien manda ETH a una función inexistente, se deposita automáticamente
        if (msg.value > 0) _deposit(address(0), msg.value);
    }
}
