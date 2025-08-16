# Digital Sigils on the Ethereum Blockchain
The Web3 Layer of the [Digil Project](https://digil.app)  
**Website**: [digil.co.in](https://digil.co.in)

## What is a Digil?
A **Digil** (Digital Sigil) is an ERC-721-based **dynamic NFT** (dNFT). Unlike static collectibles, Digils have **intrinsic value (ETH)** and **charge (ERC-20 coins)**, a lifecycle of **charging → activation → linking**, and rich interactions that can redistribute value and coins across holders.

---

## Table of Contents
- [Contracts](#contracts)
- [Planar Tokens & Base URI](#planar-tokens--base-uri)
- [Global Configuration](#global-configuration)
- [Per-Token Properties](#per-token-properties)
- [Lifecycle](#lifecycle)
  - [Create](#create)
  - [Charge](#charge)
  - [Activate](#activate)
  - [Deactivate](#deactivate)
  - [Discharge](#discharge)
- [Linking & Affinity](#linking--affinity)
- [Vaulting External ERC-721s](#vaulting-external-erc-721s)
- [Distributions, Withdrawals & Bonuses](#distributions-withdrawals--bonuses)
- [Opt-Out / Blacklist](#opt-out--blacklist)
- [Rescue & Recovery](#rescue--recovery)
- [Admin & Security Notes](#admin--security-notes)
- [How it Works: End-to-End Examples](#how-it-works-end-to-end-examples)

---

## Contracts

### Digil Coin | ERC-20
**Symbol**: DIGIL  
**Address**: TBD

Utility token used for charging, paying feature fees (e.g., linking, metadata updates, opt-out), and bonus rewards.

### Digil Token | ERC-721
**Symbol**: DDIGIL  
**Address**: TBD

Core NFT contract that mints Digils, tracks charge/value, enforces planar policy, processes activation / discharge in batches, manages links, and vaults external NFTs.

---

## Planar Tokens & Base URI

**Planar set (IDs 0-20)** is minted at deployment to the initial owner with on-chain “plane” metadata:

- Core: **Void(1), Karma(2), Kaos(3)**
- Elemental: **Fire(4), Air(5), Earth(6), Water(7)**
- Paraelemental: **Ice(8), Lightning(9), Metal(10), Nature(11)**
- Energy: **Harmony(12), Discord(13), Entropy(14), Exergy(15), Magick(16)**
- Ethereal: **Aether(17), World(18)**
- Extended: **Virtual(19), ILXR(20)**

**Custody rule (admin-locked):** planar tokens must always be held by `owner()` and **cannot be burned**. Operator/per-token approvals are **ignored** for them. A temporary window during `transferOwnership` moves any planar tokens held by the current admin to the new admin, preserving custody.

**Base URI:** `_baseURI()` returns token **#0**’s URI, so the admin indirectly controls the base via token #0.

> **Linking domain:** “Foundational planes” are `0..18` and **cannot** be link *targets*. Link targets must have `id > 18` (user Digils and/or extended planes `19-20`).

---

## Global Configuration

Owner-set parameters (`configure`):

| Parameter | Purpose | Default |
|---|---|---|
| **Coin rate** (`_coinRate`) | Fees (linking, metadata updates, opt-out) and the cap for withdrawal bonuses | `100 × 10^decimals` |
| **Incremental value** (`_incrementalValue`) | Minimum ETH per “coin unit” for charging | `100,000 gwei` |
| **Transfer value** (`_transferValue`) | Share of the incremental value that accrues to users (90-100% of incremental) | `95,000 gwei` |
| **Batch size** (`_batchSize`) | Contributors processed per tx during activation/discharge | `350` |

---

## Per-Token Properties

- **charge** - coins contributed to an *inactive* token.  
- **activeCharge** - coins accumulated by an *active* token and via links.  
- **value** - intrinsic ETH held by the token.  
- **incrementalValue** - min ETH per coin unit for this token (≥ global minimum if non-zero).  
- **activationThreshold** - coins required to activate.  
- **links** - up to **10** outgoing links to other tokens (by ID).  
- **contributors** - addresses that contributed to charge/value (used for distribution).  
- **restricted** - only whitelisted accounts may contribute. Current owner is auto-whitelisted on transfer.

Internal batch state (`distributionIndex`, `dischargeIndex`) tracks progress across large contributor sets.

---

## Lifecycle

### Create
Creating a Digil mints a new ERC-721 with optional restrictions and an optional alignment to a foundational plane. You can set its per-coin ETH floor (`incrementalValue`) and the coins required to activate (`activationThreshold`). If you align it to a plane, a one-time coin fee applies and the token is seeded with a base link to that plane. Any ETH you send at creation time is stored as the token’s intrinsic `value`.
`createToken(incrementalValue, activationThreshold, restricted, plane, data)`
- Optional **restriction**: requires an ETH deposit (≥ max(token incremental, global minimum)).
- Optional **plane** link at mint time: `plane ∈ [1..18]` charges a **coin fee** tiered by plane group and seeds a link (base efficiency 100).
- Any sent ETH becomes token `value`.

### Charge
Charging supplies **coins** (via the ERC-20) and **ETH** (meeting the token’s per-coin floor). Restricted tokens only accept charges from whitelisted accounts. The contract records each contributor; for inactive tokens it accumulates `charge` toward activation, and for active tokens it may route value/coins through existing links to other Digils based on efficiency and affinity.
`chargeToken` / `chargeTokenAs(contributor, tokenId, coins)`
- Enforces **minimum ETH** per coin unit (token’s incremental or global).
- If the token is **restricted**, contributor must be whitelisted.
- Pulls **coins** (ERC-20 `transferFrom`) from contributor.
- **Inactive tokens:** records contributor, books minimum ETH as **Contribute** (meets charging floor), surplus ETH → `value`; coins above floor → `activeCharge`.
- **Active tokens:** routes coins/ETH through links (see next section); leftover ETH → owner distribution.

### Activate
Activation transforms a sufficiently charged token from a pending state into an active one. During activation, the contract processes contributors in batches, migrating `charge` into `activeCharge`, sharing a portion of the token’s `value` with contributors proportionally to their charge, and crediting the owner with the required contribution portion. Once all batches finish, the token’s `active` flag is set.
`activateToken(tokenId)`
- Requires `charge ≥ activationThreshold` (or already in progress).  
- **Batched distribution:** converts `charge → activeCharge`, pays contributors a slice of `value` proportional to their charge, and credits the owner with the “minimum ETH” portion of contributions.  
- Sets `active = true` on completion.

### Deactivate
Deactivation is a lightweight operation that turns off an active Digil when it has no remaining `charge`. It requires a minimal ETH payment (the token’s own `incrementalValue`) to proceed, updates activity timestamps, and flips the token’s `active` state to false.
`deactivateToken(tokenId)`
- Requires `active == true`, `charge == 0`, and **ETH ≥ token.incrementalValue**.

### Discharge
Discharge unwinds a token’s state and contributor records. It’s also batched and requires a fee that scales with the number of links. For **inactive** tokens, contributors are refunded their coins and ETH while any remaining `value` goes to the owner. For **active** tokens, contributors receive a pro-rata share of `value` and the owner is credited with the required contribution portion—similar to activation’s distribution phase.
`dischargeToken(tokenId)`
- Requires a **per-link scaled ETH** fee.
- **Batched** reset of contributor records and value distribution:  
  - If **inactive**: refund each contributor’s coins + ETH; remaining token `value` to owner.  
  - If **active**: distribute token `value` to contributors (proportional to charge) and credit owner with contributed portion (similar to activation).

---

## Linking & Affinity
`linkToken(tokenId, linkId, efficiency)`
- Source must be approved; **destination must have id > 18**. Max **10** links per token.
- Requires **ETH ≥ (source.incremental + dest.incremental)**, split 50/50 into both tokens’ `value`.
- If destination is restricted, caller must be whitelisted there.
- Sets/raises **base efficiency** and computes an **affinity bonus** using each token’s foundational plane (`0..18`), with multipliers for same/strong/weak/ethereal relationships and a balancing adjustment if the destination’s `activeCharge` exceeds the source’s.
- Charges a **coin fee** that scales with efficiency and current link count.

Active-token charging distributes coins/ETH to each link according to base efficiency and affinity bonus; unconsumed ETH flows to the source owner.

`unlinkToken(tokenId, linkId)` removes a link and clears its efficiency parameters.

---

## Vaulting External ERC-721s
The contract implements `IERC721Receiver`:

- **Deposit** - Safe-transfer an external NFT to this contract. The contract verifies custody and **mints a new Digil** representing the vaulted NFT (token data is appended to the Digil’s URI as `?account=...&tokenId=...`). The external NFT’s contract address is recorded as the first “contributor” for book-keeping.
- **Recall** - After distributions mark it recallable, `recallToken(collection, digilId)` safely returns the external NFT to the current Digil owner and credits them the Digil’s `activeCharge` in coins.

---

## Distributions, Withdrawals & Bonuses

**Where value goes**
- `_addDistributedValue(addr, value)` splits `value` into a **contract fee** and **user value** (based on `transferValue` vs `incrementalValue`) and mints **bonus coins** per **full** multiples of the global `_incrementalValue`.

**Withdrawals**
- Call `withdraw()` to claim pending **ETH** and **coins**.
- **Time bonus:** if you hold any Digil or any Coin balance, you accrue **+1 coin unit every 15 minutes** since your last withdrawal, **capped by `_coinRate` per withdrawal**.

---

## Opt-Out / Blacklist
Users can toggle their status with `setOptStatus(bool)` (fee required: `_incrementalValue * _coinRate / 10^decimals`).  
Blacklisted addresses cannot receive tokens or interact where blocked. Opt-in is allowed later by calling the same function.

---

## Rescue & Recovery
Owner can `rescueToken(tokenId, to)` when:
- **Blacklisted owner**, or
- **Stalled** in a batch op for **≥ 30 days**, or
- **Inactive** for **≥ 365 days** **and** the token still holds value/charge or unresolved contributions.

Approvals are cleared before/after rescue transfer.

---

## Admin & Security Notes
- **Planar policy:** planar tokens `0..20` are admin-locked and non-burnable; only moved during `transferOwnership` via a temporary window. Token #0 controls the base URI.
- **Batched ops:** activation/discharge scale to many contributors via `_batchSize` windows; repeated calls progress the operation.
- **Reentrancy guard:** critical flows are protected.
- **Approvals on planar tokens:** ignored by design; no third party can operate them.

---

## How it Works: End-to-End Examples

> The examples use defaults: `_coinRate = 100 * 10^decimals`, `_incrementalValue = 100,000 gwei`, `_transferValue = 95,000 gwei`. Exact numbers vary with your configuration and token settings.

### 1) Create a token aligned to a Plane
Alice calls:
```solidity
createToken(
  incrementalValue = 200_000 gwei,   // per-coin ETH floor for this token
  activationThreshold = 10 * 10^dec, // needs 10 coin units to activate
  restricted = false,
  plane = 12,                        // Harmony
  data = "ipfs://..."
)
```
- She pays the **plane fee** (since plane ∈ 12..16, fee = `25 × _coinRate` coins).  
- Any `msg.value` she sends is added to the token’s `value`.  
- The token stores a foundational plane link (base efficiency 100).

### 2) Charge an inactive token
Bob contributes to Alice’s token:
```solidity
chargeToken(tokenId, coins = 5 * 10^dec) with msg.value >= 5 × 200_000 gwei
```
- Minimum ETH per coin is enforced.  
- The “floor” ETH is recorded as **Contribute** (meets charging requirement).  
- Any **excess ETH** raises the token’s `value`.  
- `charge` increases by 5 coin units (any extra coins above the floor would go to `activeCharge`).  
- Bob gets recorded as a **contributor**.

### 3) Activate
Alice calls `activateToken(tokenId)` once `charge ≥ activationThreshold`.  
- In **batches**, contributors receive slices of the token’s `value` proportional to their charge.  
- The sum of contributed “floor ETH” is credited to the owner via distribution.  
- `charge → activeCharge`, and the token becomes **active**.

### 4) Link to another Digil (or extended plane)
Alice links her active token to Carol’s token (id > 18):
```solidity
linkToken(srcId, dstId, efficiency = 120) with msg.value >= src.incremental + dst.incremental
```
- The ETH is split 50/50 into both tokens’ `value`.  
- The link records **base efficiency** and an **affinity bonus** derived from their foundational planes.  
- A **coin fee** is charged that scales with efficiency and existing link count.

### 5) Charge an active, linked token
Dana charges Alice’s now-active token:
```solidity
chargeToken(tokenId, coins = 3 * 10^dec) with msg.value >= 3 × 200_000 gwei
```
- Coins/ETH are **fanned out** across links using each link’s base efficiency and affinity bonus.  
- If a destination cannot be charged (e.g., restricted), the proportional coins are retained as the source’s `activeCharge`.  
- Any **leftover ETH** becomes a distribution for Alice (the owner).

### 6) Discharge
If Alice calls `dischargeToken(tokenId)`:
- Pays a fee that scales with link count.  
- In **batches**:
  - If **inactive**: each contributor gets their coins + ETH back; remaining token `value` goes to owner.  
  - If **active**: contributors receive token `value` proportional to charge; the “floor ETH” portion accrues to the owner.  
- Contributor records are reset.

### 7) Vault and recall an external NFT
Eve safe-transfers her ERC-721 to the Digil contract. The contract:
- Verifies custody, **mints a new Digil**, and appends `?account=<collection>&tokenId=<id>` to the Digil’s URI.
- Once distributions mark it recallable, Eve (or the Digil owner) calls:
```solidity
recallToken(collection, digilId)
```
- The external NFT is safely returned, and the Digil’s `activeCharge` is paid out to the owner in coins.

---

## Notes for Integrators
- Planar tokens are not tradable on marketplaces (admin-locked). User Digils are standard ERC-721s.
- Bonus coins accrue only when the caller holds **any** Digil or **any** Coin balance.
- Whitelists are **append-only** (addresses cannot be removed). The recipient of a token is always auto-whitelisted on receipt.
- Long-running activation/discharge must be **continued** in subsequent txs until completion (watch `Activate(..., complete)` / `Discharge(..., complete)` events).

---

© Digil - Dynamic NFTs for programmable value and intent.