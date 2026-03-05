# AGENTS.md

This file provides guidance for AI coding agents and contributors working in this repository.

> Goal: make safe, consistent changes to DigilCoin protocol contracts and tests, with clear validation and change summaries.

---

## 1) Repository Identity

- **Project**: DigilCoin / Digital Sigils smart-contract suite.
- **Domain**: Ethereum smart contracts (ERC-20, ERC-721, governance, timelock).
- **Primary language**: Solidity (`^0.8.34`).
- **Current repo shape**:
  - `contracts/` — protocol contracts and interfaces.
  - `tests/` — Solidity tests intended for Remix test runner style.
  - `remix.config.json` — compiler/output configuration.
  - `.prettierrc.json` — formatting rules (notably for `*.sol`).

---

## 2) First-Read Context (Before Editing)

Agents should read these files first, in order:

1. `README.md` (system behavior and terminology).
2. `remix.config.json` (compiler settings, EVM target, optimizer/debug config).
3. `.prettierrc.json` (formatting defaults, Solidity print width/tab style).
4. The specific contract(s) and related interfaces being changed.
5. Relevant tests under `tests/`.

If behavior is unclear, prefer deriving intent from existing NatSpec comments and event/state naming patterns before introducing new mechanics.

---

## 3) Environment & Setup

This repo is currently structured for Remix-compatible Solidity development.

### Minimal prerequisites

- Solidity-aware editor (or Remix IDE).
- Node.js only if using local automation tools (optional in current repo state).

### Recommended setup flow

1. Open contracts in Remix or local editor.
2. Use compiler settings aligned with `remix.config.json`.
3. Keep Solidity formatting consistent with `.prettierrc.json`.
4. Run/adjust relevant `tests/*.sol` suites when behavior changes.

### Compiler profile (from `remix.config.json`)

- Language: Solidity
- EVM version: `prague`
- Optimizer detail flags enabled (with `yul: false`)
- Revert strings: `strip`
- Rich output selection including ABI, metadata, docs, storage layout, bytecode, gas estimates

Do not silently change these defaults in unrelated PRs.

---

## 4) Working Agreements for Agents

### 4.1 Scope discipline

- Make the smallest change that fully solves the requested task.
- Avoid opportunistic refactors unless they are necessary for correctness/safety.
- Do not rename public functions/events/errors without explicit request.

### 4.2 Contract safety expectations

When editing Solidity:

- Preserve access-control boundaries and role checks.
- Preserve accounting invariants (balances, pools, claims, caps, epoch snapshots).
- Preserve replay/batching guards and state flags.
- Prefer custom errors for new revert branches (unless surrounding code uses string reverts).
- Emit events for critical state transitions and admin changes.

### 4.3 Gas and storage considerations

- Avoid unnecessary storage writes in hot paths.
- Cache repeated storage reads in local variables where meaningful.
- Keep loop bounds explicit and safe.
- Maintain packing-aware struct field ordering style unless migration is intended.

### 4.4 Comments and NatSpec

- Add/update NatSpec when changing externally visible behavior.
- After any code change, review affected NatSpec and inline comments to confirm they still match runtime behavior.
- Keep comments factual and behavior-focused (not speculative).
- After any code change, update `README.md` in the same PR when behavior, setup, or operator flow changes.
- If you change assumptions, update both code comments and README-relevant sections.

---

## 5) Testing & Validation Expectations

For any logic change, agents should validate using the strongest available checks in environment.

### Minimum validation checklist

- Compile the touched contracts (or verify syntax/consistency if compiler unavailable).
- Run the most relevant Solidity tests in `tests/`.
- Verify no obvious formatting regressions.
- Provide exact commands run and outcomes.

### Test targeting guidance

- `DigilCoin.sol` changes → run `tests/DigilCoin_test.sol` first.
- `DigilToken.sol` changes → run matching `tests/DigilToken*_test.sol` files.
- Shared interfaces/libs changes → run all impacted suites.

### Desktop Remix IDE deployment order for `DigilToken` testing

When validating `DigilToken` behavior in the Desktop Remix IDE, use this strict bootstrap sequence:

- `DigilTestLibrary.sol`, `IDigilToken.sol`, and `NFT.sol` are testing-only contracts/files and should be treated as test support.

1. Deploy `DigilCoin` first with the default admin account (generally Remix account 0: `0x5B38Da6a701c568545dCfcB03FcB875f56beddC4`).
2. Deploy `DigilToken` with:
   - the same default admin as initial owner,
   - the deployed `DigilCoin` contract address,
   - `18` as the decimals constructor argument.
3. On the deployed `DigilCoin`, call `grantRole` with:
   - `role`: `0x9f2df0fed2c77648de5860a4cc508cd0818c85b8b8a1ab4ceeef8d981c8956a6` (`MINTER_ROLE`),
   - `account`: the deployed `DigilToken` contract address.
4. After both deployments are complete, set helper address references as follows:
   - put the deployed `DigilCoin` address into `getCoins`
   - put the deployed `DigilToken` address into `getToken`

This role assignment is required before `DigilToken` flows that mint DIGIL can succeed.

If environment lacks required tooling, state limitation clearly and provide a follow-up command list for maintainers.

---

## 6) File & Architecture Notes

- `contracts/DigilCoin.sol` — ERC-20 + permit + votes + donor-funded rewards accounting.
- `contracts/DigilToken.sol` — core NFT lifecycle/mechanics (charge/activate/link/buff/discharge/vault flows).
- `contracts/DigilGovernor.sol` + `contracts/DigilTimelock.sol` — governance and execution controls.
- `contracts/*Interface*.sol`/`I*.sol` — integration boundaries; preserve compatibility unless intentionally versioned.
- `tests/remix_tests.sol`, `tests/remix_accounts.sol` — Remix testing harness helpers.

When adding new contract files, follow existing naming style (`PascalCase.sol`, interfaces prefixed with `I`).

---

## 7) Change Management Standards

### Commit expectations

- Use clear, imperative commit messages.
- Group related code and test updates in the same commit when practical.
- Do not include generated artifacts unless requested.

### PR expectations

PR descriptions should include:

1. What changed.
2. Why it changed.
3. Risk/safety notes.
4. Validation commands + results.
5. Any environment limitations encountered.

---

## 8) Preferred AGENTS.md Extension Pattern

As this repository evolves, extend this file using this order:

1. **Project identity and stack**
2. **How to run/build/test**
3. **Architecture map**
4. **Code style and safety constraints**
5. **Review and PR checklist**
6. **Subdirectory overrides**

For complex areas, add nested `AGENTS.md` files in subdirectories (e.g., `contracts/AGENTS.md`, `tests/AGENTS.md`) with stricter local rules. Nested files override parent instructions for their subtree.

---

## 9) Subdirectory Overrides (Template)

Use this snippet for future nested guidance:

```md
# AGENTS.md (subdirectory)

## Scope
Applies to this folder and all descendants.

## Additional rules
- Rule 1...
- Rule 2...

## Validation
- Command A
- Command B
```

---

## 10) Quick Agent Checklist

Before finalizing:

- [ ] Read README + touched contracts/tests.
- [ ] Kept behavior changes minimal and explicit.
- [ ] Reviewed and updated NatSpec + inline comments so they match new behavior.
- [ ] Ran relevant validation commands (or documented environment blockers).
- [ ] Updated README when behavior/setup/flows changed.
- [ ] Summarized risks, assumptions, and follow-ups in final output.
