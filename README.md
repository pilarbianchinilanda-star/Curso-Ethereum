KipuBankV3

KipuBankV3 es un contrato inteligente de vault multi-token que permite depositar ETH o tokens ERC20 y los convierte automáticamente a USDC usando Uniswap V2. Todos los depósitos se contabilizan en USD con 6 decimales.

Características principales

Acepta ETH, USDC o cualquier ERC20 con un par directo USDC en Uniswap V2.

Convierte automáticamente tokens no-USDC a USDC.

Control de acceso mediante OpenZeppelin AccessControl.

Prevención de reentradas con ReentrancyGuard.

Uso de Chainlink para obtener precios de tokens en USD (6 decimales).

Límites configurables:

bankCapUsd6: Cap total del banco en USD.

maxWithdrawPerTxUsd6: Máximo retiro por transacción en USD.
