# Digital Sigils on the Ethereum Blockchain
The Web3 Layer of the [Digil Project](https://digil.app)  
**Website**: [digil.co.in](https://digil.co.in)

## What is a Digil?
A **Digil** (Digital Sigil) is an ERC-721 **dynamic NFT** that can hold **intrinsic value (ETH)** and accumulate **energy (ERC-20 “coins”)**. Owners and contributors can **charge**, **activate**, **link**, **deactivate**, and **discharge** Digils; the contract fairly tracks and redistributes ETH/coins using on-chain rules and events. Conceptually, a Digil behaves like a **rechargeable node** that can power neighboring nodes when linked.

> A sigil is a type of symbol used in magic. In modern usage, especially in the context of chaos magic, sigil refers to a symbolic representation of the practitioner's desired outcome.<sup>[?](https://en.wikipedia.org/wiki/Sigil)</sup>

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
**Symbol**: DIGIL • **Address**: TBD

Used for **charge units**, feature fees (linking, metadata updates, opt-out), and **bonuses**. Internally the contract normalizes coin math with a **coin multiplier**: `10**decimals`. Where we say “coins,” we mean base units at this precision.

### Digil Token | ERC-721
**Symbol**: DDIGIL • **Address**: TBD

Implements core NFT logic plus:
- **Economics**: per-token `charge`, `activeCharge`, and ETH `value`; per-address contribution ledgers; pending distributions.
- **Batched workflows**: `activateToken`, `dischargeToken` process contributors in pages using `distributionIndex` and a configurable `_batchSize`.
- **Link graph**: up to 10 links per token with `LinkEfficiency { base %, affinityBonus }` and plane-driven bonuses.
- **Vaulting**: accepts external ERC-721s via `onERC721Received` and exposes `recallToken`.
- **Access & safety**: blacklist gating; planar invariants; `nonReentrant` on sensitive paths; robust event surface; custom errors.

In short, it’s both the **scoreboard** and the **settlement engine**.

---

## Planar Tokens & Base URI

At deployment the contract mints **21 planar tokens** (IDs `0..20`) to the admin. These embed compact **affinity metadata** (bytes) used by the link bonus algorithm:

- Core: **Void (1), Karma (2), Kaos (3)**
- Elemental: **Fire (4), Air (5), Earth (6), Water (7)**
- Para-elemental: **Ice (8), Lightning (9), Metal (10), Nature (11)**
- Energy: **Harmony (12), Discord (13), Entropy (14), Exergy (15), Magick (16)**
- Ethereal: **Aether (17), World (18)**
- Extended: **Virtual (19), ILXR (20)**

**Invariants**
- Planar IDs are **admin-locked**: non-burnable; only `owner()` or the contract can operate them. Approvals are ignored for these IDs.
- During `transferOwnership`, a short **planar transfer window** opens so planar tokens held by the outgoing admin can be moved to the new admin. Otherwise, planar tokens are **non-transferable**.
- Token **#0** controls the collection **base URI**; `_baseURI()` returns token #0’s URI. Updating #0 updates the effective base for default `tokenURI`s.

**Practical note**: End-user Digils may **align** to a foundational plane during creation (see Create). That alignment doesn’t create a user-visible token transfer—it sets internal state used by the **affinity** algorithm.

---

## Global Configuration

Owner-only `configure(coins, incrementalValue, transferValue, batchSize)` with checks:
- `_coinRate = coins × coinMultiplier` • `coins ∈ (0, 1e9]`
- `_incrementalValue > 0` (global per-coin ETH floor)
- `_transferValue ∈ [0.9, 1.0] × _incrementalValue`
- `_batchSize > 0`

**Constants**
- `BONUS_INTERVAL = 15 minutes` → withdraw time bonus step
- `VALUE_MULTIPLIER = 1000 gwei`
- `PLANAR_MAX_ID = 18`, `PLANAR_TRANSFER_MAX_ID = 20`
- `MAX_LINKS = 10`
- Rescue windows: `STALLED_TIMEOUT = 30 days`, `INACTIVITY_PERIOD = 365 days`
- Affinity helpers: `AFFINITY_BOOST = 2`, `AFFINITY_REDUCTION = 2`

**Why it matters**: these dials shape costs (fees), minimum ETH coupling per coin, payout fairness, and throughput of batch operations.

---

## Per-Token Properties

**Economics**
- `charge` — pre-activation coins (base units); grows via `chargeToken/As` on inactive tokens.
- `distributionCharge` / `distributionValue` — snapshots used when a distribution is in progress.
- `activeCharge` — post-activation working coins; also accrues from link inflows and some overpay scenarios.
- `value` — intrinsic ETH the token holds.
- `incrementalValue` — per-coin ETH requirement for *this* token (can be 0 but must be ≥ global min if set).
- `activationThreshold` — required coins to allow activation.

**Workflow state**
- `activating` / `discharging` — multi-tx operation flags.
- `distributionIndex` — cursor into `contributors[]` for paging.
- `contributionEpoch` — logical epoch; incrementing this treats all prior `TokenContribution` entries as reset without clearing the mapping.
- `lastActivity` — updated on meaningful operations; used by rescue logic.

**Links & contributors**
- `links[]` (≤ 10) • `linkEfficiency[linkId].base` and `.affinityBonus` (percent-like integers).
- `contributors[]` plus per-address  
  `TokenContribution { charge, value, epoch, exists, distributed, whitelisted }`.

**Metadata & flags**
- `data` (bytes) and `uri` (string). Planar tokens require `data.length ≥ 4` to preserve the affinity codec.
- `active` and `restricted`. New owners are **auto-whitelisted** for the token.

This is a **mini-ledger** per token: balances, connections, contributors, and progress cursors for safe, resumable payouts and resets.

---

## Lifecycle

High-level: **Create** → **Charge** → **Activate**. Later: **Deactivate** and/or **Discharge**.

### Create

`createToken(incrementalValue, activationThreshold, restricted, plane, data)`

- Enforces `incrementalValue == 0 || incrementalValue ≥ globalMin`.
- If `restricted = true`, caller must send `ETH ≥ max(token.incrementalValue, globalMin)`; sets `restricted = true`.
- If `plane ∈ [1..PLANAR_MAX_ID]`, charges a one-time **coin fee tier** (see Admin & Security Notes) and records the alignment with base 100% link to that plane (internal only).
- Any `msg.value` becomes token `value`.
- Returns the new `tokenId` minted to the caller.

### Charge

`chargeToken(tokenId, coins)` and  
`chargeTokenAs(contributor, tokenId, coins)` (the latter is `nonReentrant`)

- **Inputs**: `coins` (base units) and `msg.value` (ETH).  
  If `contributor ≠ caller` (proxy), call must include at least one full ETH increment:  
  `requiredValue = max(token.incrementalValue, globalMin)`.
- **Inactive token path**:
  - Compute minimum ETH for the requested coins:  
    `minValue = token.incrementalValue × (coins / coinMultiplier)`.  
  - Record `minValue` as the contributor’s **value**; excess ETH → token `value`.
  - If provided coins exceed the minimum implied by ETH, surplus coins go to `activeCharge`.
  - Emits `Contribute`, `ContributeValueAs`, `Charge` as appropriate.
- **Active token path** (active charging):
  - If the token has **no links**, all coins (plus any `activeCoins` used in linked paths) credit `activeCharge`.
  - If the token **has links**:
    - ETH is split evenly across links: each link slice has `linkedValue = value / links.length`.
    - Coins are apportioned per link by:
      - `linkedCoins = (coins × baseEfficiency) / links.length / 100`
      - `bonusCoins = (coins × affinityBonus) / 100`
    - For each link, `_chargeToken` runs in **link mode**, which:
      - Does **not** pull ERC-20 from the contributor.
      - Still enforces restriction/whitelist and minimum ETH/coin logic.
    - If a target link cannot be charged (fails checks), its slice of coins falls back into the source’s `activeCharge`.
    - Unused ETH after linked charging becomes a pending distribution for the source **owner**.

### Activate

`activateToken(tokenId)` (multi-tx)

- Requires `active == false` and either `charge >= activationThreshold` or the token is already in `activating` mode.
- Also requires `!discharging`.
- Internally calls `_distribute(tokenId, discharge=false)` in batches:
  - For each contributor:
    - Their contributed ETH share (`distributableTokenValue`) is paid out using `_addDistributedValue`, based on `distributionValue` and `charge` proportions.
    - The token’s `value` is reduced by the same amount.
    - Their original contributed ETH (`contribution.value`) is accumulated into a pool `distribution`.
  - After all contributors:
    - `distributionCharge` is moved to `activeCharge`.
    - The owner receives `distribution` via `_addDistributedValue(owner, distribution)`.
    - Any remaining token `value` (if any) is absorbed by the contract pool via `_addValue(tValue)`.
- Emits `Activate(tokenId, false)` while in progress and `Activate(tokenId, true)` on completion.
- The token is then marked `active = true`, and `activating = false`.

### Deactivate

`deactivateToken(tokenId)`

- Requires `active == true` and `charge == 0`.
- Requires `msg.value ≥ token.incrementalValue` (credited to the contract’s pool).
- Requires no batch in progress (`distributionIndex == 0`).
- On success:
  - Credits `msg.value` to the contract via `_addValue`.
  - Applies a **thematic bleed**:  
    - Let `ac = activeCharge`. If `ac > 0`, compute `lost = ac / AFFINITY_REDUCTION` (currently half).  
    - New `activeCharge = ac - lost`.  
    - The lost portion is no longer tracked by any token, but the underlying ERC-20 coins remain held by the contract and can support future global distributions/bonuses.
  - Sets `active = false`.
  - Emits `Deactivate(tokenId)`.

This models the idea that **turning a sigil off** leaks some of its power back into the system.

### Discharge

`dischargeToken(tokenId)` (multi-tx; `nonReentrant`)

- Requires there is something meaningful to discharge:  
  `t.charge > 0 || t.value > 0 || t.discharging == true`.
- Requires `!activating`.
- Requires `msg.value ≥ max(globalMin, token.incrementalValue) × max(1, links.length)`.  
  This scales the discharge cost with link complexity.
- Sets `discharging = true`, credits `msg.value` to the contract, and calls:  
  `_distribute(tokenId, discharge = !t.active)`.

Two main modes:

1. **Inactive token discharge** (`active == false` → `discharge = true`)
   - For each contributor **once per epoch**:
     - Their contributed ETH (`contribution.value`) and coins (`contribution.charge`) are refunded directly via `_addValue(contributor, value, coins)`.
   - After all contributors:
     - Any remaining `t.value` is paid to the **owner** via `_addDistributedValue(owner, tValue)`.
     - `distributionCharge` and `distributionValue` are cleared.

2. **Active token discharge** (`active == true` → `discharge = false`)
   - The `_distribute` call behaves similarly to activation:
     - Contributors receive a **pro-rata share** of token `value` via `_addDistributedValue(contributor, distributableTokenValue)`.
     - The owner receives the pool of required-contribution ETH (`distribution`) via `_addDistributedValue(owner, distribution)`.
     - `distributionCharge` is added to `activeCharge`.
     - Any remaining `t.value` goes to the contract pool via `_addValue(tValue)`.
   - After this **value settlement**, the token still has `activeCharge`—but it is now treated as **surplus power to be pushed outward**.

After `_distribute` completes in either mode:

- All contributions for the current epoch are considered fully processed:
  - `contributors[]` is cleared (`delete t.contributors`).
  - `contributionEpoch` is incremented. Any future interaction with an existing `TokenContribution` mapping entry will logically see a “fresh” state, avoiding double-counting old contributions.
- If a contract token is attached (`contractTokenAddress != 0`) and still present, it becomes **non-recallable** and its address is reinserted as a placeholder contributor for future epochs.

Finally, for **both active and inactive tokens**, any remaining `activeCharge` on the discharged token is **redistributed into its links**:

- Let `ac = t.activeCharge`. If `ac > 0` and there are links:
  - Sum all linked base efficiencies:  
    `sumOfEfficiencies = Σ linkEfficiency[linkId].base` (only links with `base > 0`).
  - For each linked token:
    - `share = ac × baseEfficiency / sumOfEfficiencies`
    - `linkedToken.activeCharge += share`
    - Emit `ActiveCharge(linkId, share)`
  - Any rounding remainder from integer division is effectively **lost** as dust.
- The original token’s `activeCharge` is then set to **0**.

You can read this as: **discharging a sigil pushes its remaining power outward along its link graph**, weighted by link efficiency.

On completion, `discharging = false` and `Discharge(tokenId, true)` is emitted.

---

## Linking & Affinity

`linkToken(tokenId, linkId, efficiency)` (`nonReentrant`)

- Preconditions:
  - `tokenId != linkId`
  - `linkId > PLANAR_MAX_ID` (you cannot link *to* foundational plane tokens)
  - `links.length < MAX_LINKS`
  - `efficiency > currentBaseEfficiency` for that link (strict improvement)
- Value:
  - `msg.value ≥ source.incrementalValue + dest.incrementalValue`
  - ETH is split evenly between the two tokens: 50% → `tokenId.value`, 50% → `linkId.value`.
- Access:
  - If destination token is `restricted`, the **caller** must be whitelisted on the destination token.
- Affinity bonus:
  - Looks at the tokens’ **foundational planes** (the first link entry if present) and reads their compact `data` bytes.
  - Strong match (`s[1] == d[0]` or `s[2] == d[0]`): base bonus `= 2 × efficiency`.
  - Same plane or ethereal source (IDs > 16): base bonus `= 1 × efficiency`.
  - Weak match (`s[3] == d[0]`): base bonus `= efficiency / 2`.
  - No base bonus → final bonus is 0.
  - Multipliers:
    - Ethereal source (`sourceId > 16`): bonus × 4.
    - Energy source (`12–16`) or destination = World (18): bonus × 2.
  - Charge comparison:
    - If destination’s `activeCharge` > source’s, reduce bonus by half (`/ AFFINITY_REDUCTION`), favoring flows from stronger to weaker planes.
- Final link parameters:
  - `linkEfficiency[linkId].base = efficiency`
  - `linkEfficiency[linkId].affinityBonus = max(existingAffinityBonus, computedBonus)`
  - If this is a new link (previous base = 0), `linkId` is appended to the `links[]` array.
- Fees:
  - Additional coin fee scales with requested `efficiency` and the link count.
  - Uses a small triangular/quadratic term to keep ultra-high efficiencies expensive.

`unlinkToken(tokenId, linkId)`:

- Clears `linkEfficiency[linkId]` and removes `linkId` from the `links[]` array by swap-and-pop.
- Emits `Unlink(tokenId, linkId)`.

---

## Vaulting External ERC-721s

Implements `IERC721Receiver`.

### Deposit (vault)

When an external NFT is sent to the Digil contract:

```solidity
ERC721(externalCollection).safeTransferFrom(
  msg.sender,
  address(DigilToken),
  externalTokenId,
  data
);
```

The callback `onERC721Received`:

1. Verifies the Digil contract now owns `externalTokenId`.
2. Ensures this `(collection, externalTokenId)` pair was not previously vaulted.
3. Mints a **new Digil** to `from` with:
   - `incrementalValue = globalMin` (the minimum non-zero incremental value)
   - `activationThreshold = 0`
4. Appends query parameters to the new token’s URI:  
   `?account=<collection>&tokenId=<externalTokenId>`
5. Records:
   - `_contractTokens[collection][digilId].tokenId = externalTokenId`
   - `token.contractTokenAddress = collection`
   - Adds `collection` as the initial entry in `contributors[]`.

This Digil now represents the vaulted NFT.

### Recall

After the Digil goes through at least one distribution/activation cycle that marks it **recallable**, the current Digil owner can call:

```solidity
recallToken(collection, digilId)
```

- Safety check: `collection` must match `token.contractTokenAddress`.
- The contract retrieves the underlying `contractTokenId` and ensures it is currently recallable.
- State is cleared first:
  - `contractToken.tokenId = 0`
  - `contractToken.recallable = false`
  - `_contractTokenExists[collection][contractTokenId] = false`
  - `token.contractTokenAddress = address(0)`
- The external NFT is transferred back to the current Digil owner using `safeTransferFrom`, forwarding the Digil’s `data` bytes.
- The Digil’s `activeCharge` is **paid out to the owner** as coins via `_addValue(owner, 0, activeCharge)`, and `activeCharge` is reset to 0.

Vaulted NFTs thus become **chargeable artifacts** whose built-up energy can be reclaimed alongside the original asset.

---

## Distributions, Withdrawals & Bonuses

### Crediting value

`_addDistributedValue(addr, value)` splits an incoming ETH amount into:

- **Contract fee**:  
  `fee = value × ( (_incrementalValue − _transferValue) / _incrementalValue )`  
  (applied to the full `value` to minimize integer-division precision loss).
- **User value**:  
  `userValue = value − fee`

The fee is credited to the contract’s own distribution bucket; the user value is credited to `addr`.

**Bonus coins**: For each **full multiple** of the **global** `_incrementalValue` contained in `value`, the recipient gets:  

`bonusCoins = (coinRate / BONUS_RATE_DIVISOR) × fullIncrements`  

i.e. 1% of the coin rate per full increment.

### Withdrawals

`withdraw()` lets any address claim its pending ETH and coins.

- Looks up `Distribution { time, coins, value }` for `msg.sender`.
- Pays out all `value` (ETH) via a safe send.
- Attempts to transfer all `coins` from the contract to the user via `_coins.transferFrom`; if that fails, the coins are left pending and `coins` output is reported as 0.
- If the user holds **any Digils** (`balanceOf(addr) > 0`) or any **coins** (`_coins.balanceOf(addr) > 0`), they also receive a **time-based coin bonus**:
  - For each `BONUS_INTERVAL` since the last withdrawal, +`coinMultiplier` coins.
  - Capped at `_coinRate` per withdrawal call.

This structure allows the contract’s internal fee pool and “lost” power to fuel long-term participant bonuses.

### Admin value creation

`createValue(tokenId, value)` (owner-only):

- Optionally allows the admin to send additional ETH with the call (credited to the contract’s distribution pool).
- Requires that the contract’s distribution pool already has at least `value` ETH; otherwise reverts.
- Moves `value` from the contract’s pool to the token’s intrinsic `value` via `_createValue`.

---

## Opt-Out / Blacklist

`setOptStatus(bool optOut)` toggles an address’ participation:

- Requires `msg.value ≥ (_incrementalValue × _coinRate / _coinMultiplier)`.
- Adds that ETH to the contract pool via `_addValue(msg.value)`.
- Sets `_blacklisted[account] = optOut` and emits `OptOut` or `OptIn`.

Blacklisted addresses:

- Cannot send or receive Digils (`_update` enforces `_notOnBlacklist`).
- Cannot participate in charges or as `operator` in ERC-721 receptions.
- Still retain their existing distribution balances, which can be withdrawn if they later opt in again.

---

## Rescue & Recovery

Owner-only `rescueToken(tokenId, to)` supports recovering stuck or abandoned Digils.

A token can be rescued if **any** of the following holds:

1. The current owner is **blacklisted**.
2. The token is **stalled** mid-batch (i.e. `distributionIndex > 0`) and `now ≥ lastActivity + STALLED_TIMEOUT`.
3. The token is **inactive** (`active == false`) for ≥ `INACTIVITY_PERIOD` and:
   - `value > 0`, or
   - It has non-trivial contributor/charge history (contributors exist, `charge > 0`, and `incrementalValue > 0`).

Additional rules:

- `to` must be a non-zero address.
- Approvals are cleared before and after the transfer.
- Planar tokens are still constrained by planar policy: effectively, they must stay aligned with admin control.

This provides a bounded way for the admin to clean up truly abandoned or stuck sigils while respecting user opt-out status.

---

## Admin & Security Notes

- **Planar policy**:
  - IDs `0..PLANAR_TRANSFER_MAX_ID` are admin-controlled.
  - Non-burnable; approvals are ignored; transfer to non-admin addresses is blocked except during `transferOwnership`.
- **Foundational plane fees at mint** (applies when `plane ∈ [1..PLANAR_MAX_ID]`):
  - Void/Karma/Kaos (1–3): **5× coin rate**
  - Para-elemental (8–11): **1× coin rate**
  - Energy (12–16): **25× coin rate**
  - Ethereal (17–18): **100× coin rate**
- **Metadata updates** via `updateToken`:
  - Can change `uri` and/or `data` if the caller:
    - Sends `ETH ≥ (token.incrementalValue + globalMin)`, and
    - Pays `1000 × coinRate` per field updated (one fee for URI, one for `data`).
  - If a token has any `charge > 0`, its `incrementalValue` and `activationThreshold` cannot be changed.
  - Planar tokens must maintain:
    - `incrementalValue = 0`
    - `activationThreshold = 0`
    - `data.length ≥ 4`
- **Batching & epochs**:
  - Activation and discharge stream contributors in pages using `distributionIndex` and `_batchSize`.
  - After a full discharge completes, `contributors[]` is cleared and `contributionEpoch` increments, so old contributors cannot be double-counted.
- **Access guards**:
  - Transfers and operations require callers not be blacklisted.
  - Transfers auto-whitelist the new owner on that token.
  - Sensitive functions are `nonReentrant`.
  - Custom errors convey precise failure reasons.

---

## How it Works: End-to-End Examples

> The examples below demonstrate common flows with realistic numbers. Adjust coin decimals to your ERC-20 configuration (examples assume 18 decimals).

### 1) Create tokens (open vs. restricted) with and without plane alignment

**Open token with custom economics**

```solidity
createToken(
  incrementalValue      = 200_000 gwei,
  activationThreshold   = 10 * 10**18,
  restricted            = false,
  plane                 = 0,
  data                  = "ipfs://token-A"
)
```

**Restricted token (invite-only)**

```solidity
createToken(
  incrementalValue      = 300_000 gwei,
  activationThreshold   = 5 * 10**18,
  restricted            = true,
  plane                 = 0,
  data                  = "ipfs://token-B"
)
// send msg.value >= max(tokenB.incrementalValue, globalMin)
```

**Aligned token (energy tier fee @ 25× coin rate)**

```solidity
createToken(
  incrementalValue      = 150_000 gwei,
  activationThreshold   = 8 * 10**18,
  restricted            = false,
  plane                 = 12,              // Harmony
  data                  = "ipfs://token-C"
)
```

### 2) Whitelist management (restrict/unrestrict)

**Add whitelisted addresses** (enables restriction if not already)

```solidity
restrictToken(tokenB, [0xAlice, 0xBob]);
// send msg.value >= max(tokenB.incrementalValue, globalMin)
```

**Disable restriction** (open contributions again)

```solidity
restrictToken(tokenB, []);
```

### 3) Charging inactive tokens and proxy charging

**Direct charge (inactive token)**

```solidity
chargeToken(tokenA, coins = 5 * 10**18);
// with msg.value >= 5 × tokenA.incrementalValue
```

**Proxy charge on behalf of Alice**

```solidity
chargeTokenAs(
  0xAlice,
  tokenA,
  coins = 3 * 10**18
);
// with msg.value >= max(tokenA.incrementalValue, globalMin)
```

- Minimum ETH per coin is accounted as Alice’s contributed value on `tokenA`.
- Excess ETH → `tokenA.value`.
- Excess coins (beyond what ETH would imply) → `tokenA.activeCharge`.

### 4) Activate with multiple contributors (batched)

After several charges by Alice and Bob:

```solidity
activateToken(tokenA);
```

- Runs in pages controlled by `_batchSize`.
- Each page:
  - Pays contributors from `distributionValue` pro-rata by `charge` using `_addDistributedValue`.
  - Accumulates the “required contribution” slice in `distribution`, later paid to the owner.
- On completion:
  - All `distributionCharge` is added to `tokenA.activeCharge`.
  - Owner receives `distribution`.
  - Any leftover `tokenA.value` is taken as a fee to the contract pool.
  - `activateToken` emits `Activate(tokenA, true)` and marks `tokenA.active = true`.

### 5) Linking and affinity effects

**Create a link with efficiency and value split**

```solidity
linkToken(
  tokenA,
  tokenC,
  efficiency = 120
);
// with msg.value >= tokenA.incrementalValue + tokenC.incrementalValue
```

- ETH is split **50/50** into `tokenA.value` and `tokenC.value`.
- Base efficiency = 120%; affinity bonus is computed from their foundational planes (for example, Harmony ↔ Exergy may receive multipliers).
- A coin fee is charged that grows with both efficiency and link count.

**Charge the active, linked source**

```solidity
chargeToken(tokenA, coins = 4 * 10**18);
// with msg.value >= 4 × tokenA.incrementalValue
```

- If `tokenA` has links and is active:
  - ETH is evenly split across the links.
  - Each link receives coins based on `base` and `affinityBonus`.
  - If a target link is restricted and the caller isn’t whitelisted there, that slice fails and its coins fall back to `tokenA.activeCharge`.
- Remaining ETH (not consumed by linked charging) becomes a distribution to `ownerOf(tokenA)` via `_addDistributedValue`.

**Unlink**

```solidity
unlinkToken(tokenA, tokenC);
```

### 6) Deactivation with bleed

Assume `tokenA` is active with `activeCharge = 10 * 10**18` and `charge = 0`.

```solidity
deactivateToken(tokenA);
// with msg.value >= tokenA.incrementalValue
```

- `msg.value` is added to the contract pool.
- With `AFFINITY_REDUCTION = 2`:
  - `lost = activeCharge / 2 = 5 * 10**18`
  - New `activeCharge = 5 * 10**18`
- `tokenA.active` is set to false.

From a gameplay perspective, **half the sigil’s power is sacrificed** into the global system each time you power it down.

### 7) Discharge (inactive vs active)

**Inactive discharge (refund contributors)**

```solidity
dischargeToken(tokenB);
// with msg.value >= max(globalMin, tokenB.incrementalValue) × max(1, tokenB.links.length)
```

- Contributors get **all** of their contributed ETH and coins back.
- Any remaining `tokenB.value` is paid to the owner (less implicit contract fees).
- `contributors[]` is cleared and `contributionEpoch` increments, so old contributions are logically reset.

**Active discharge (settle value + push power into links)**

```solidity
dischargeToken(tokenA);
// with msg.value >= max(globalMin, tokenA.incrementalValue) × max(1, tokenA.links.length)
```

- `_distribute(..., discharge=false)`:
  - Contributors receive a pro-rata share of `tokenA.value`.
  - Owner receives the “required contribution” pool.
  - `distributionCharge` is added to `tokenA.activeCharge`.
  - Remaining `tokenA.value` is taken as a contract fee.
- Then any remaining `tokenA.activeCharge` is redistributed to linked tokens weighted by their base efficiencies.
- `tokenA.activeCharge` is set to 0; `contributors[]` cleared; `contributionEpoch` increments.

### 8) Withdrawals and time bonus

Suppose `0xAlice` has pending distributions:

```solidity
withdraw();
```

- Pays her ETH and coin balances.
- If Alice holds any Digil or any coin balance, she also receives a time-based bonus:
  - `+1 × coinMultiplier` per `BONUS_INTERVAL` (15 minutes) elapsed since her last withdrawal, capped at `_coinRate`.

### 9) Updating metadata (URI/data) and economic parameters

**Update a token’s URI and data**

```solidity
updateToken(
  tokenA,
  incrementalValue      = tokenA.incrementalValue,       // unchanged
  activationThreshold   = tokenA.activationThreshold,    // unchanged
  data                  = "0x1234...",
  uri                   = "ipfs://new-metadata"
);
// with msg.value >= (tokenA.incrementalValue + globalMin)
// and coins transferred = 1000×coinRate for URI + 1000×coinRate for data
```

- If `tokenA.charge > 0`, its `incrementalValue` and `activationThreshold` cannot be changed.
- Planar tokens must keep both values at 0 and `data.length ≥ 4`.

**Reconfigure global knobs (owner-only)**

```solidity
configure(
  coins            = 150,
  incrementalValue = 120_000 gwei,
  transferValue    = 110_000 gwei,
  batchSize        = 256
);
```

- Re-approves ERC-20 allowance internally and emits `Configure(...)`.

### 10) Opt-out / opt-in and rescue

**Opt-out**

```solidity
setOptStatus(true);
// with msg.value >= (_incrementalValue × _coinRate / coinMultiplier)
```

- Address becomes blacklisted; many operations are blocked.

**Opt-in**

```solidity
setOptStatus(false);
// with msg.value >= (_incrementalValue × _coinRate / coinMultiplier)
```

**Rescue an abandoned token (owner-only)**

```solidity
rescueToken(tokenId, to = 0xReceiver);
```

- Allowed if the current owner is blacklisted, the token is stalled for ≥ 30 days, or inactive ≥ 365 days with meaningful state.
- Approvals are cleared before/after.

### 11) Linked discharge with activeCharge redistribution (numerical sketch)

Assume:

- `tokenX.activeCharge = 100` (abstract coin units)
- `tokenX.links = [tokenY, tokenZ, tokenW]`
- Efficiencies:
  - `linkEfficiency[tokenY].base = 50`
  - `linkEfficiency[tokenZ].base = 100`
  - `linkEfficiency[tokenW].base = 150`

Total base efficiency:

```text
sumOfEfficiencies = 50 + 100 + 150 = 300
```

When `dischargeToken(tokenX)` finishes its `_distribute` phase and reaches the redistribution step:

- `tokenY` receives: `100 × 50 / 300 ≈ 16`
- `tokenZ` receives: `100 × 100 / 300 ≈ 33`
- `tokenW` receives: `100 × 150 / 300 = 50`

The total assigned is `16 + 33 + 50 = 99`; 1 unit is lost as rounding dust. `tokenX.activeCharge` becomes 0. Each of Y, Z, and W fires an `ActiveCharge` event with its assigned share.

From a lore standpoint, **discharging X sends a wave of power along its links**, strengthening its neighbors in proportion to how strong those links are.

---

© Digil — Dynamic NFTs for programmable value and intent.
