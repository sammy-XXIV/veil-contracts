# VEIL Finance

**Confidential lending protocol built on Zama FHEVM**

VEIL lets users deposit cWETH as encrypted collateral and borrow against it. Liquidation bots cannot compute health factors — all individual position data is encrypted onchain using Fully Homomorphic Encryption.

---

## Live Demo

**Frontend:** https://sammy-xxiv.github.io/veil-finance
**Network:** Ethereum Sepolia Testnet

---

## How It Works

Traditional lending protocols store collateral and debt in plaintext. Any bot can call `getUserAccountData()`, compute your health factor, and liquidate you the moment you slip below threshold.

VEIL changes this at the protocol level:

- Collateral stored as encrypted `euint64` — no plaintext ever written to storage
- Debt stored as encrypted `euint64` — same
- Health factor computed inside the FHE coprocessor — result is an encrypted `ebool`, never exposed
- Liquidation bots can only call `hasPosition(address)` — returns true/false, nothing else
- Bot calls `liquidate()` on a healthy position — contract silently returns 0 via `FHE.select`. Bot wastes gas and learns nothing.

**What bots see:** `hasPosition = true`. That's it.
**What bots need:** collateral amount, debt amount, health factor. All encrypted.

---

## Contracts

| Contract | Address |
|----------|---------|
| VeilLending (final) | `0x8B694DD1B76B39c30CE5106a4752dD2729482bEB` |
| cWETHMock | `0x46208622DA27d91db4f0393733C8BA082ed83158` |
| Underlying WETH | `0xff54739b16576FA5402F211D0b938469Ab9A5f3F` |

---

## Protocol Parameters

| Parameter | Value |
|-----------|-------|
| Max LTV | 66% |
| Liquidation Threshold | 150% |
| Collateral Token | cWETH (ERC-7984) |
| Debt Token | cWETH (ERC-7984) |
| Network | Sepolia Testnet |

---

## How to Test

1. Connect MetaMask to Sepolia Testnet
2. Get test ETH from `sepoliafaucet.com`
3. Go to Deposit page — click **Get cWETH — Faucet**
4. Click **Decrypt** on collateral metric — sign EIP-712 to see your wallet balance
5. Enter deposit amount — click **Deposit & Open Position**
6. Dashboard shows position — amounts show Encrypted until decrypted
7. Click **Decrypt** on collateral — sign to see deposited amount
8. Click **Decrypt** on debt — sign to see outstanding debt
9. Click **Decrypt** on Liq. Price — auto-decrypts both collateral and debt, shows liquidation price
10. Borrow up to 66% of collateral on Borrow page
11. Repay on Repay page before closing position

---

## Architecture

```
Frontend (GitHub Pages)
    ↓ encrypt request
Backend (Render — Node.js)
    ↓ @zama-fhe/relayer-sdk
Zama Relayer (Sepolia Testnet)
    ↓ FHE proof + handle
VeilLending Contract (Sepolia)
    ↓ confidentialTransferFrom → returns euint64
cWETHMock ERC-7984 (Sepolia)
```

**Frontend** — Single HTML file, ethers.js v6, no framework
**Backend** — Node.js on Render, handles FHE encryption and user decryption
**Contracts** — Solidity 0.8.24, `@fhevm/solidity`, Zama FHEVM coprocessor

---

## Key FHE Operations

| Operation | FHE Function |
|-----------|-------------|
| Store collateral | `confidentialTransferFrom` return value → `euint64` |
| Add collateral | `FHE.add()` |
| LTV check | `FHE.le(FHE.mul(debt,100), FHE.mul(collateral,66))` → `ebool` |
| Borrow enforcement | `FHE.select(withinLTV, amount, _encryptedZero)` |
| Close position check | `FHE.eq(debt, _encryptedZero)` → `FHE.select` |
| Liquidation decision | `FHE.lt()`, `FHE.and()`, `FHE.select()` |
| Repay cap | `FHE.min(received, debt)` |
| Decrypt balance | `userDecrypt()` via Zama Relayer + EIP-712 signature |

---

## Key Technical Decisions

**1. `confidentialTransferFrom` return value**

Deposits and repayments are cryptographically verified. The contract stores the actual encrypted amount returned by the token — not a user-supplied value. Users cannot lie about how much they deposited.

```solidity
euint64 received = collateralToken.confidentialTransferFrom(
    msg.sender, address(this), amount
);
_positions[msg.sender].collateral = received;
```

**2. `_encryptedZero` stored at contract level**

Inline `FHE.asEuint64(0)` comparisons create new handles without ACL permissions — causing unreliable FHE zero comparisons. VEIL stores encrypted zero once in the constructor and reuses it everywhere.

```solidity
_encryptedZero = FHE.asEuint64(0);
FHE.allowThis(_encryptedZero);
```

This fixes the close position bug where collateral was returned even with outstanding debt.

**3. No `FHE.div` — multiply both sides**

`FHE.div` does not exist in Zama's library. VEIL rewrites all division as cross-multiplication:

```solidity
// Instead of: debt <= collateral * 66 / 100
// VEIL does:  debt * 100 <= collateral * 66
ebool withinLTV = FHE.le(
    FHE.mul(newDebt, FHE.asEuint64(100)),
    FHE.mul(collateral, FHE.asEuint64(MAX_LTV_PCT))
);
```

**4. No oracle dependency**

VEIL has no price feed. Liquidation is based purely on the encrypted collateral-to-debt ratio computed in FHE. Bots cannot combine public price data with event timing to infer position health.

---

## Security Design

**Deposit** — Cryptographically verified via `confidentialTransferFrom` return value. No user-supplied plaintext.

**Repay** — Same. Actual received amount reduces debt. No user-supplied plaintext.

**Borrow** — LTV enforced in FHE via `FHE.select`. Exceeding 66% silently returns 0. Frontend enforces LTV before sending tx.

**Close Position** — FHE checks `debt == _encryptedZero`. If debt exists, returns 0 collateral. Frontend shows warning modal before close.

**Liquidation** — Full health factor computed in FHE. Liquidator gets collateral only if position is underwater. Healthy positions return 0 silently.

---

## Known Limitations

**`plainAmount` in borrow** — The borrow function has no `plainAmount` parameter. Pool accounting is removed entirely — the cWETH token balance is the source of truth. Users cannot borrow more than what exists in the pool because `confidentialTransfer` silently sends 0 if the pool is empty.

**FHE cannot revert on encrypted conditions** — LTV violations and debt-on-close return 0 silently instead of reverting. Frontend catches these cases with pre-flight checks and warnings.

**Testnet only** — cWETH and Sepolia ETH have no real monetary value.

---

## Roadmap

Once Zama ships:
1. **Encrypted return values from `confidentialTransfer`** — verifies borrow amounts cryptographically
2. **FHE-based conditionals with revert** — allows onchain LTV enforcement with proper error messages

---

## Tech Stack

- Solidity 0.8.24
- Zama FHEVM (`@fhevm/solidity`)
- OpenZeppelin Confidential Contracts (ERC-7984)
- `@zama-fhe/relayer-sdk`
- ethers.js v6
- Node.js + Express (backend)
- GitHub Pages (frontend)
- Render (backend hosting)

---

