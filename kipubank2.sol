// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

/// @title KipuBank — bóvedas personales para ETH con límites globales y por retiro
/// @author Pilu Bianchini
/// @notice Contrato seguro para depositar y retirar ETH 
/// @dev Usa errores personalizados, patrón checks-effects-interactions, eventos, NatSpec y funciones bien documentadas
contract KipuBank {

    
    error BankCapExceeded(uint256 attempted, uint256 available);
    error InsufficientBalance(uint256 available, uint256 requested);
    error WithdrawExceedsPerTxLimit(uint256 requested, uint256 limit);
    error ZeroWithdrawal();
    error NativeTransferFailed(address to, uint256 amount);

   
    uint256 public immutable bankCap;          // límite global
    uint256 public immutable maxWithdrawPerTx; // límite por retiro

    uint256 public totalDeposited;             // ETH total depositado
    uint256 public depositCount;               // contador de depósitos
    uint256 public withdrawCount;              // contador de retiros

    mapping(address => uint256) private _balances; // saldos de usuarios

 

    event Deposit(address indexed user, uint256 amount, uint256 newBalance);
    event Withdraw(address indexed user, uint256 amount, uint256 newBalance);

   
    constructor(uint256 _bankCap, uint256 _maxWithdrawPerTx) {
        bankCap = _bankCap;
        maxWithdrawPerTx = _maxWithdrawPerTx;
    }

    

    modifier nonZero(uint256 value) {
        if (value == 0) revert ZeroWithdrawal();
        _;
    }

  

    /// @notice Deposita ETH en la bóveda del usuario
    function deposit() external payable {
        _deposit(msg.sender, msg.value);
    }

    /// @notice Retira ETH de la bóveda del usuario
    /// @param amount Cantidad a retirar en wei
    function withdraw(uint256 amount) external nonZero(amount) {
        uint256 bal = _balances[msg.sender];

        // Checks
        if (amount > bal) revert InsufficientBalance(bal, amount);
        if (amount > maxWithdrawPerTx) revert WithdrawExceedsPerTxLimit(amount, maxWithdrawPerTx);

        // Effects
        _balances[msg.sender] = bal - amount;
        totalDeposited -= amount;
        unchecked { withdrawCount++; }

        // Interactions
        _safeTransfer(msg.sender, amount);

        emit Withdraw(msg.sender, amount, _balances[msg.sender]);
    }

    /// @notice Consulta el balance de un usuario
    function balanceOf(address user) external view returns (uint256) {
        return _balances[user];
    }

   

    /// @dev Lógica de depósito compartida por deposit() y receive()
    function _deposit(address user, uint256 amount) private {
        uint256 newTotal = totalDeposited + amount;

        // Checks
        if (newTotal > bankCap) revert BankCapExceeded(newTotal, bankCap - totalDeposited);

        // Effects
        _balances[user] += amount;
        totalDeposited = newTotal;
        unchecked { depositCount++; }

        emit Deposit(user, amount, _balances[user]);
    }

    /// @dev Transferencia segura de ETH
    function _safeTransfer(address to, uint256 amount) private {
        (bool ok, ) = to.call{value: amount}("");
        if (!ok) revert NativeTransferFailed(to, amount);
    }

   

    /// @notice Permite recibir ETH directamente como depósito
    receive() external payable {
        _deposit(msg.sender, msg.value);
    }
}
