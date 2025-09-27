KipuBank

KipuBank es un contrato inteligente en Solidity que permite a los usuarios depositar y retirar ETH de una bóveda personal, con límites de seguridad.

Descripción

- Los usuarios pueden depositar ETH en su bóveda personal.  
- Se puede retirar ETH hasta un límite fijo por transacción.  
- Existe un límite global de depósitos establecido al desplegar el contrato.  
- El contrato registra el número de depósitos y retiros.  
- Se emiten eventos en cada operación exitosa.  


Despliegue

1. Compilar el contrato en **Remix IDE** (https://remix.ethereum.org/).  
2. Seleccionar la red de prueba (por ejemplo, Sepolia Testnet).  
3. Configurar una wallet (como MetaMask) con ETH de prueba.  
4. Desplegar el contrato indicando:
   - `bankCap` → límite global de depósitos.  
   - `maxWithdrawPerTx` → límite de retiro por transacción.  

Uso

- Depositar ETH:
  ```solidity
  kipuBank.deposit{value: 1 ether}();
