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
- **Batched workflows**: `activateToken`, `dischargeToken` process contributors in pages using `distributionIndex`/`dischargeIndex` and a configurable `_batchSize`.
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
- `MAX_LINKS = 10`
- Rescue windows: `STALLED_TIMEOUT = 30 days`, `INACTIVITY_PERIOD = 365 days`

**Why it matters**: these dials shape costs (fees), minimum ETH coupling per coin, payout fairness, and throughput of batch operations.

---

## Per-Token Properties

**Economics**
- `charge` — pre-activation coins (base units); grows via `chargeToken/As` on inactive tokens.
- `distributionCharge` / `distributionValue` — snapshots used when a distribution is in progress.
- `activeCharge` — post-activation working coins; also accrues from link inflows.
- `value` — intrinsic ETH the token holds.
- `incrementalValue` — per-coin ETH requirement for *this* token (can be 0 but must be ≥ global min if set).
- `activationThreshold` — required coins to allow activation.

**Workflow state**
- `activating` / `discharging` — multi-tx operation flags.
- `distributionIndex` / `dischargeIndex` — cursor into `contributors[]` for paging.
- `lastActivity` — updated on meaningful operations; used by rescue logic.

**Links & contributors**
- `links[]` (≤ 10) • `linkEfficiency[linkId].base` and `.affinityBonus` (percent-like integers).
- `contributors[]` plus per-address `TokenContribution { charge, value, exists, distributed, whitelisted }`.

**Metadata & flags**
- `data` (bytes) and `uri` (string). Planar tokens require `data.length ≥ 4` to preserve affinity codec.
- `active` and `restricted`. New owners are **auto-whitelisted** for the token.

This is a **mini-ledger** per token: balances, connections, contributors, and progress cursors for safe, resumable payouts.

---

## Lifecycle

High-level: **Create** → **Charge** → **Activate**. Later: **Deactivate** or **Discharge**.

### Create
`createToken(incrementalValue, activationThreshold, restricted, plane, data)`
- Enforces `incrementalValue == 0 || incrementalValue ≥ globalMin`.
- If `restricted = true`, caller must send `ETH ≥ max(token.incrementalValue, globalMin)`; sets `restricted = true`.
- If `plane ∈ [1..18]`, charges a one-time **coin fee tier** (see Admin & Security Notes) and records the alignment with base 100% link to that plane (internal only).
- Any `msg.value` becomes token `value`.
- Returns the new `tokenId` minted to the caller.

### Charge
`chargeToken(tokenId, coins)` and `chargeTokenAs(contributor, tokenId, coins)` (the latter is `nonReentrant`)
- **Inputs**: coins (base units) and `msg.value` (ETH). If contributor ≠ caller (proxy), call must include at least **one full increment** of ETH: `max(token.incrementalValue, globalMin)`.
- **Inactive token path**:
  - Minimum ETH consumed per coin: `minValue = token.incrementalValue × (coins / coinMultiplier)` (rounded down).
  - Records `minValue` as contributor **value**; excess ETH → token `value`.
  - If provided coins > minimum coins implied by ETH, surplus coins → `activeCharge`.
  - Emits `Contribute`, `ContributeValueAs`, `Charge` as applicable.
- **Active token path**:
  - If the token has **links**, splits ETH evenly across links; coins are apportioned by `base` efficiency and global **affinity bonus** (below). Each eligible linked target is charged via the **linked** mode (no ERC-20 pull; constraints enforced).
  - Unused link slices fall back as `activeCharge` on the source. Remaining ETH (not consumed by links) becomes a pending distribution for the source **owner**.
  - Without links, all coins credit `activeCharge` directly.

### Activate
`activateToken(tokenId)` (multi-tx)
- Requires `!active` and `charge ≥ activationThreshold` (or currently `activating`).
- Runs `_distribute(..., discharge=false)` in pages:
  - **Contributors** receive ETH **pro-rata** from `distributionValue` according to contributed `charge`.
  - **Owner** receives the “required contribution” slice (derived from per-coin floors).
  - `distributionCharge` is moved to **`activeCharge`**.
- Emits `Activate(tokenId, complete)` on each step; sets `active = true` on completion.

### Deactivate
`deactivateToken(tokenId)`
- Requires `active == true` and `charge == 0`.
- Requires `msg.value ≥ token.incrementalValue` (credited to the contract’s pool).
- Sets `active = false`.

### Discharge
`dischargeToken(tokenId)` (multi-tx; `nonReentrant`)
- Requires some `charge`/`value` **or** currently `discharging`.
- Requires `msg.value ≥ max(globalMin, tokenMin) × max(1, linkCount)`.
- Two modes:
  - **Inactive token**: contributors are refunded their contributed **coins + ETH**; any remaining token `value` is distributed to the **owner**.
  - **Active token**: contributors receive a **pro-rata** share of token `value`; the **owner** receives the required contribution portion; **activeCharge is retained**.
- Clears contributor tallies and arrays in pages; emits `Discharge(tokenId, complete)` updates.

---

## Linking & Affinity

`linkToken(tokenId, linkId, efficiency)` (`nonReentrant`)
- Preconditions: `tokenId != linkId`; `linkId > 18` (no links to foundational planes); link count < 10; `efficiency` must strictly improve over current base.
- **Value**: `msg.value ≥ source.incrementalValue + dest.incrementalValue`; split 50/50 into both tokens’ `value`.
- **Access**: if destination token is `restricted`, caller must be whitelisted on **destination**.
- **Affinity bonus**: uses the tokens’ **foundational planes** to compute extra efficiency:
  - Strong match: `+ 2 × efficiency`; same plane or ethereal source (17–18): `+ 1 ×`; weak match: `+ efficiency / 2`.
  - Multipliers: ethereal source ×4; energy planes (12–16) or destination `World (18)` ×2.
  - Balancer: if destination’s `activeCharge` > source’s, **halve** the bonus.
- **Fees**: coin fee grows with the requested efficiency and current link count (includes a triangular/quadratic term).

`unlinkToken(tokenId, linkId)` removes the relationship and clears its efficiency parameters.

---

## Vaulting External ERC-721s

Implements `IERC721Receiver`:
- **Deposit**: safe-transfer an external NFT to the contract. The contract verifies custody, then **mints a new Digil** to the depositor with `incrementalValue = min-nonzero` and `activationThreshold = 0`. The external collection + tokenId are appended to the Digil’s **URI** as query parameters. The collection address is also recorded as an initial “contributor” marker.
- **Recall**: when distributions mark the vault **recallable**, `recallToken(collection, digilId)` transfers the external NFT back to the current Digil owner and credits them with the Digil’s **activeCharge** in coins. Any `data` bytes on the Digil are forwarded in the safe transfer.

---

## Distributions, Withdrawals & Bonuses

**Crediting value**
- `_addDistributedValue(addr, value)` splits a value amount into:
  - **Contract fee** = `value × ( (incrementalValue − transferValue) / incrementalValue )` (applied to the full `value` to avoid integer-division loss).
  - **User value** = `value − fee`, credited to `addr`.
- **Bonus coins**: for each **full multiple** of the **global** `_incrementalValue` inside a credited amount, the recipient gets `(_coinRate / 100)` coins (1% of coin rate) per multiple.

**Withdrawals**
- `withdraw()` pays out the caller’s pending **ETH** and **coins**. If the caller holds **any** Digil **or** has **any** coin balance, they also accrue a **time bonus** of `+1 coin unit` per **15 minutes** since last withdrawal, **capped at `_coinRate` per call**. If the ERC-20 transfer fails, coins remain pending; ETH always uses a safe native send.

**Admin value creation**
- `createValue(tokenId, value)` transfers ETH from the contract’s **distribution balance** to a token’s intrinsic `value` (reverts if the contract’s pool is short).

---

## Opt-Out / Blacklist

`setOptStatus(bool optOut)` toggles participation. Requires `ETH ≥ (_incrementalValue × _coinRate / coinMultiplier)`. Blacklisted addresses are blocked by guards on transfers, charges, and receiver hooks. Call again with the opposite flag to opt back in. Emits `OptOut`/`OptIn`.

---

## Rescue & Recovery

Owner can `rescueToken(tokenId, to)` if:
- Current owner **opted out** (blacklisted), or
- Token is **stalled** mid-batch for ≥ 30 days, or
- Token is **inactive** for ≥ 365 days **and** still has material state (non-zero `value` or meaningful contributor/charge/increment traces).

Approvals are cleared pre/post rescue. Planar tokens effectively must remain with the admin due to planar transfer rules.

---

## Admin & Security Notes

- **Planar policy**: IDs `0..20` are admin-locked; approvals ignored; non-burnable; short transfer window only during ownership change.
- **Foundational plane fees at mint** (applies when `plane ∈ [1..18]`):
  - Void/Karma/Kaos (1–3): **5× coin rate**
  - Para-elemental (8–11): **1× coin rate**
  - Energy (12–16): **25× coin rate**
  - Ethereal (17–18): **100× coin rate**
- **Metadata updates**: `updateToken` allows changing `uri` and/or `data` if caller sends `ETH ≥ (token.incrementalValue + globalMin)` and pays **1000× coin rate per field** updated. If token has any `charge`, `incrementalValue` and `activationThreshold` are **frozen**. Planar tokens must keep both at **0** and `data.length ≥ 4`.
- **Batching**: activation/discharge stream contributors in pages; activation uses effectively **double page size** during distribution; progress is evented.
- **Auto-whitelist on transfer**; **blacklist guards**; **reentrancy** on sensitive paths; **custom errors** for precise failures.

---

## How it Works: End-to-End Examples

> The examples below demonstrate common flows with realistic numbers. Adjust coin decimals to your ERC-20 configuration (examples assume 18 decimals).

### 1) Create tokens (open vs. restricted) with and without plane alignment

**Open token with custom economics**
```
createToken(
  incrementalValue = 200_000 gwei,
  activationThreshold = 10 * 10^18,
  restricted = false,
  plane = 0,
  data = "ipfs://token-A"
)
```

**Restricted token (invite-only)**
```
createToken(
  incrementalValue = 300_000 gwei,
  activationThreshold = 5 * 10^18,
  restricted = true,
  plane = 0,
  data = "ipfs://token-B"
)
```  
Send `msg.value >= max(token.incrementalValue, globalMin)` to enable restriction.

**Aligned token (energy tier fee @ 25× coin rate)**
```
createToken(
  incrementalValue = 150_000 gwei,
  activationThreshold = 8 * 10^18,
  restricted = false,
  plane = 12,              // Harmony
  data = "ipfs://token-C"
)
```

### 2) Whitelist management (restrict/unrestrict)

**Add whitelisted addresses** (enables restriction if not already)
```
restrictToken(tokenB, [0xAlice, 0xBob])   // send ETH >= max(tokenB.incremental, globalMin)
```

**Disable restriction** (open contributions again)
```
restrictToken(tokenB, [])
```

### 3) Charging inactive tokens and proxy charging

**Direct charge (inactive token)**
```
chargeToken(tokenA, coins = 5 * 10^18)
with msg.value >= 5 × tokenA.incrementalValue
```

**Proxy charge on behalf of Alice**
```
chargeTokenAs(0xAlice, tokenA, coins = 3 * 10^18)
with msg.value >= max(tokenA.incremental, globalMin)   // at least one full increment
```

- Minimum ETH per coin is accounted as Alice’s contributed value.
- Excess ETH → tokenA.value; excess coins → tokenA.activeCharge.

### 4) Activate with multiple contributors (batched)

After several charges by Alice and Bob:
```
activateToken(tokenA)
```
- Runs in pages. Each page:
  - Pays contributors from `distributionValue` **pro-rata** by their contributed `charge`.
  - Credits the owner with the required-contribution slice.
  - Moves `distributionCharge` to `activeCharge`.
- Emits `Activate(tokenA, false)` while in progress and `Activate(tokenA, true)` when finished.

### 5) Linking and affinity effects

**Create a link with efficiency and value split**
```
linkToken(tokenA, tokenC, efficiency = 120)
with msg.value >= tokenA.incremental + tokenC.incremental
```
- ETH is split **50/50** into tokenA.value and tokenC.value.
- Base efficiency = 120%; affinity bonus derived from planes (e.g., A aligned to 12 Harmony, C aligned to 15 Exergy may gain multipliers).
- Coin fee scales with efficiency and current link count on tokenA.

**Charge the active, linked source**
```
chargeToken(tokenA, coins = 4 * 10^18)
with msg.value >= 4 × tokenA.incremental
```
- ETH splits evenly across A’s links; coins flow per base+bonus.
- If tokenC is `restricted` and caller not whitelisted there, that slice reverts to tokenA.activeCharge.
- Residual ETH not consumed by linked charging becomes a distribution for tokenA’s owner.

**Unlink**
```
unlinkToken(tokenA, tokenC)
```

### 6) Discharge (inactive vs active)

**Inactive discharge (refund contributors)**
```
dischargeToken(tokenB)
with msg.value >= max(globalMin, tokenB.incremental) × max(1, tokenB.links.length)
```
- Refunds each contributor’s **coins + ETH**.
- Any remaining tokenB.value is distributed to its owner.
- Clears contributor arrays in pages; emits `Discharge(..., complete)`.

**Active discharge (settle value; keep activeCharge)**
```
dischargeToken(tokenA)
with msg.value >= max(globalMin, tokenA.incremental) × max(1, tokenA.links.length)
```
- Distributes tokenA.value **pro-rata** by contributed charge.
- Owner receives required-contribution slice.
- tokenA.activeCharge remains untouched.

### 7) Withdrawals and time bonus

Suppose 0xAlice has pending distributions:
```
withdraw()
```
- Pays ETH and coins.
- If Alice holds any Digil or any coin balance, bonus coins accrue at **+1 coin unit per 15 minutes** since her last withdrawal, **capped at `_coinRate` per call**.

### 8) Updating metadata (URI/data) and economic parameters

**Update a token’s URI and data**
```
updateToken(
  tokenA,
  incrementalValue = tokenA.incrementalValue,      // unchanged
  activationThreshold = tokenA.activationThreshold,// unchanged
  data = "0x1234...",
  uri = "ipfs://new-metadata"
)
with msg.value >= (tokenA.incrementalValue + globalMin)
and coins transferred = 1000×coinRate for URI + 1000×coinRate for data
```
- If token has **any charge**, `incrementalValue` and `activationThreshold` cannot change.
- Planar tokens must keep both zero and `data.length ≥ 4`.

**Reconfigure global knobs (owner-only)**
```
configure(coins = 150, incrementalValue = 120_000 gwei, transferValue = 110_000 gwei, batchSize = 400)
```
- Re-approves ERC-20 allowance internally and emits `Configure(...)`.

### 9) Opt-out / opt-in and rescue

**Opt-out**
```
setOptStatus(true)
with msg.value >= (_incrementalValue × _coinRate / coinMultiplier)
```
- Address becomes blacklisted; transfers/charges guarded.

**Opt-in**
```
setOptStatus(false)
with msg.value >= (_incrementalValue × _coinRate / coinMultiplier)
```

**Rescue an abandoned token (owner-only)**
```
rescueToken(tokenId, to = 0xReceiver)
```
- Allowed if the current owner is blacklisted, or the token is **stalled ≥ 30 days**, or **inactive ≥ 365 days** with meaningful state.
- Approvals are cleared before/after.

### 10) Vaulting and recalling an external NFT

**Deposit external NFT**  
From the external collection, safe-transfer to this contract:
```
ERC721(collection).safeTransferFrom(msg.sender, address(DigilToken), externalTokenId, data)
```
- Contract verifies custody, mints a new Digil to you (`activationThreshold = 0`, `incrementalValue = min-nonzero`) and appends `?account=<collection>&tokenId=<id>` to the URI.

**Recall later**
```
recallToken(collection, digilId)
```
- Transfers the external NFT back to the current Digil owner and credits them with the Digil’s **activeCharge** in coins.

---

© Digil — Dynamic NFTs for programmable value and intent.
