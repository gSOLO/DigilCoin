/**
 * Portable scenario registry shared by Remix and Node. Add test(id, async fixture)
 * entries inside scenarios(); each receives { h, coin, token, governor, timelock }.
 * Keep IDs unique, amounts as bigint, and all chain access behind h. Do not use
 * Node imports, private keys, snapshots or simulated time in this shared module.
 * See README's Script Maintenance section for the harness API and an example.
 */
const UNIT = 10n ** 18n;
const FLOOR = 100000000000000n;
const ZERO = '0x' + '0'.repeat(40);
const MAX = (1n << 256n) - 1n;
function ok(value, message = 'assertion failed') {
  if (!value) throw new Error(message);
}
function eq(actual, expected, message = 'values differ') {
  if (actual !== expected)
    throw new Error(`${message}: expected ${String(expected)}, got ${String(actual)}`);
}
const sameAddress = (a, b) => eq(a.toLowerCase(), b.toLowerCase(), 'address mismatch');
async function rejects(run, message = 'expected failure') {
  let failed = false;
  try {
    await run();
  } catch {
    failed = true;
  }
  ok(failed, message);
}

/** Return new scenario definitions; runners own fixture creation and failure reporting. */
function scenarios() {
  const tests = [];
  const test = (id, run) => tests.push({ id, run });
  const create = async (
    h,
    token,
    user,
    threshold = 0n,
    data = '0x',
    restricted = false,
    plane = 0
  ) => {
    const result = await h.send(
      token,
      user,
      'createToken',
      [0, threshold, restricted, plane, data],
      FLOOR
    );
    return h.events(token, result, 'Transfer').find((event) => event[0] === ZERO)[2];
  };
  const balance = async (h, coin, user) => (await h.read(coin, 'balanceOf', [user.address]))[0];

  test('deployment-bootstrap', async ({ h, coin, token, governor, timelock }) => {
    const [admin, alice] = h.users;
    eq((await h.read(coin, 'name'))[0], 'Digil Coin');
    eq((await h.read(coin, 'symbol'))[0], 'DIGIL');
    eq((await h.read(coin, 'decimals'))[0], 18n);
    eq((await h.read(coin, 'totalSupply'))[0], 0n);
    eq((await h.read(token, 'name'))[0], 'Digital Sigils');
    eq((await h.read(token, 'symbol'))[0], 'DIGILS');
    sameAddress((await h.read(token, 'owner'))[0], admin.address);
    eq((await h.read(token, 'balanceOf', [admin.address]))[0], 21n);
    for (let id = 0; id < 21; id++)
      sameAddress((await h.read(token, 'ownerOf', [id]))[0], admin.address);
    for (const role of ['MINTER_ROLE', 'PAUSER_ROLE', 'CONFIG_ROLE']) {
      eq((await h.read(coin, 'hasRole', [h.id(role), admin.address]))[0], true);
      eq((await h.read(coin, 'hasRole', [h.id(role), alice.address]))[0], false);
    }
    eq((await h.read(coin, 'spendWeightBps', [token.address]))[0], 10000n);
    eq((await h.read(timelock, 'getMinDelay'))[0], 60n);
    sameAddress((await h.read(governor, 'token'))[0], coin.address);
    sameAddress((await h.read(governor, 'timelock'))[0], timelock.address);
    eq((await h.read(governor, 'votingDelay'))[0], 86400n);
    eq((await h.read(governor, 'votingPeriod'))[0], 604800n);
    eq((await h.read(governor, 'proposalThreshold'))[0], 10000n * UNIT);
    eq((await h.read(governor, 'CLOCK_MODE'))[0], (await h.read(coin, 'CLOCK_MODE'))[0]);
    for (const interfaceId of ['0x01ffc9a7', '0x80ac58cd', '0x5b5e139f'])
      eq((await h.read(token, 'supportsInterface', [interfaceId]))[0], true);
    eq((await h.read(token, 'supportsInterface', ['0xffffffff']))[0], false);
    await rejects(
      () => h.deploy('DigilToken', [ZERO, coin.address, 18]),
      'zero owner deployment should fail'
    );
    await rejects(
      () => h.deploy('DigilToken', [admin.address, alice.address, 18]),
      'EOA coin deployment should fail'
    );
  });

  test('roles-and-configuration', async ({ h, coin, token }) => {
    const [admin, alice] = h.users;
    for (const [method, args] of [
      ['mint', [alice.address, UNIT]],
      ['pause', []],
      ['unpause', []],
      ['setSpendWeight', [token.address, 0]],
      ['setRewardParameters', [1, 100, 1000, 100, 10]],
    ]) {
      await h.reverts(coin, alice, method, args, 0n, 'AccessControlUnauthorizedAccount');
    }
    await h.reverts(
      token,
      alice,
      'configure',
      [100, FLOOR, (FLOOR * 90n) / 100n, 32],
      0n,
      'OwnableUnauthorizedAccount'
    );
    await h.reverts(
      token,
      alice,
      'transferOwnership',
      [alice.address],
      0n,
      'OwnableUnauthorizedAccount'
    );
    for (const args of [
      [ZERO, 0],
      [alice.address, 100],
      [token.address, 10001],
    ])
      await h.reverts(coin, admin, 'setSpendWeight', args);
    for (const args of [
      [0, 0, 1, 0, 1],
      [0, 2, 1, 0, 1],
      [0, 1, 1, 0, 0],
      [0, 1, 1, 1001, 30],
    ])
      await h.reverts(coin, admin, 'setRewardParameters', args);
    const role = h.id('MINTER_ROLE');
    await h.send(coin, admin, 'grantRole', [role, alice.address]);
    await h.send(coin, alice, 'mint', [alice.address, UNIT]);
    await h.send(coin, admin, 'revokeRole', [role, alice.address]);
    await h.reverts(coin, alice, 'mint', [alice.address, UNIT]);
    await h.send(coin, admin, 'grantRole', [role, alice.address]);
    await h.send(coin, alice, 'renounceRole', [role, alice.address]);
    eq((await h.read(coin, 'hasRole', [role, alice.address]))[0], false);
    eq(await balance(h, coin, alice), UNIT);
  });

  test('public-configuration-and-receiver-policies', async ({ h, coin, governor, timelock }) => {
    const [admin] = h.users;
    for (const [method, expected] of [
      ['BASE_BPS', 10000n],
      ['STORED_EPOCHS', 12n],
      ['CLAIMABLE_EPOCHS', 3n],
      ['EPOCH_LENGTH', 30n * 86400n],
      ['minDailySpend', 50n * UNIT],
      ['dailyCap', 500n * UNIT],
      ['epochCap', 5000n * UNIT],
      ['dayBonusBps', 100n],
      ['maxActiveDays', 20n],
    ])
      eq((await h.read(coin, method))[0], expected);
    for (const [contract, roles] of [
      [coin, ['MINTER_ROLE', 'PAUSER_ROLE', 'CONFIG_ROLE']],
      [timelock, ['PROPOSER_ROLE', 'CANCELLER_ROLE', 'EXECUTOR_ROLE']],
    ]) {
      eq((await h.read(contract, 'DEFAULT_ADMIN_ROLE'))[0], '0x' + '0'.repeat(64));
      for (const role of roles) {
        eq((await h.read(contract, role))[0], h.id(role));
        eq((await h.read(contract, 'getRoleAdmin', [h.id(role)]))[0], '0x' + '0'.repeat(64));
      }
      eq((await h.read(contract, 'supportsInterface', ['0x01ffc9a7']))[0], true);
      eq((await h.read(contract, 'supportsInterface', ['0x7965db0b']))[0], true);
      eq((await h.read(contract, 'supportsInterface', ['0xffffffff']))[0], false);
    }
    eq((await h.read(governor, 'name'))[0], 'Digil Governor');
    eq((await h.read(governor, 'version'))[0], '1');
    ok((await h.read(governor, 'COUNTING_MODE'))[0].includes('support='));
    ok((await h.read(governor, 'clock'))[0] > 0n);
    eq((await h.read(governor, 'supportsInterface', ['0x01ffc9a7']))[0], true);
    eq((await h.read(governor, 'supportsInterface', ['0xffffffff']))[0], false);
    eq(
      (await h.read(governor, 'BALLOT_TYPEHASH'))[0],
      h.id('Ballot(uint256 proposalId,uint8 support,address voter,uint256 nonce)')
    );
    eq(
      (await h.read(governor, 'EXTENDED_BALLOT_TYPEHASH'))[0],
      h.id(
        'ExtendedBallot(uint256 proposalId,uint8 support,address voter,uint256 nonce,string reason,bytes params)'
      )
    );
    for (const contract of [coin, governor]) {
      const domain = await h.read(contract, 'eip712Domain');
      sameAddress(domain[4], contract.address);
      eq(domain[2], '1');
    }
    for (const [method, args, selector] of [
      ['onERC721Received', [admin.address, admin.address, 0, '0x'], '0x150b7a02'],
      ['onERC1155Received', [admin.address, admin.address, 0, 1, '0x'], '0xf23a6e61'],
      ['onERC1155BatchReceived', [admin.address, admin.address, [0], [1], '0x'], '0xbc197c81'],
    ]) {
      eq((await h.read(timelock, method, args))[0], selector);
      await h.reverts(governor, admin, method, args);
    }
  });

  test('erc20-allowance-burn-pause', async ({ h, coin }) => {
    const [admin, alice, bob] = h.users;
    const minted = await h.send(coin, admin, 'mint', [alice.address, 100n * UNIT]);
    eq(h.events(coin, minted, 'Transfer')[0][2], 100n * UNIT);
    await h.send(coin, alice, 'approve', [bob.address, 30n * UNIT]);
    await h.send(coin, bob, 'transferFrom', [alice.address, bob.address, 20n * UNIT]);
    eq((await h.read(coin, 'allowance', [alice.address, bob.address]))[0], 10n * UNIT);
    await h.send(coin, bob, 'burnFrom', [alice.address, 10n * UNIT]);
    await h.send(coin, bob, 'burn', [5n * UNIT]);
    eq((await h.read(coin, 'totalSupply'))[0], 85n * UNIT);
    eq(await balance(h, coin, alice), 70n * UNIT);
    eq(await balance(h, coin, bob), 15n * UNIT);
    await h.reverts(coin, bob, 'transferFrom', [alice.address, bob.address, 1]);
    await h.send(coin, alice, 'approve', [bob.address, MAX]);
    await h.send(coin, bob, 'transferFrom', [alice.address, bob.address, 1]);
    eq((await h.read(coin, 'allowance', [alice.address, bob.address]))[0], MAX);
    await h.send(coin, admin, 'pause');
    eq((await h.read(coin, 'paused'))[0], true);
    for (const [actor, method, args] of [
      [alice, 'transfer', [bob.address, 1]],
      [alice, 'burn', [1]],
      [admin, 'mint', [alice.address, 1]],
    ])
      await h.reverts(coin, actor, method, args);
    await h.send(coin, alice, 'approve', [bob.address, 0]);
    await h.send(coin, admin, 'unpause');
    await h.send(coin, alice, 'transfer', [bob.address, 1]);
  });

  test('delegation-and-checkpoints', async ({ h, coin }) => {
    const [admin, alice, bob] = h.users;
    await h.send(coin, admin, 'mint', [alice.address, 100n * UNIT]);
    eq((await h.read(coin, 'getVotes', [alice.address]))[0], 0n);
    await h.send(coin, alice, 'delegate', [alice.address]);
    eq((await h.read(coin, 'getVotes', [alice.address]))[0], 100n * UNIT);
    sameAddress((await h.read(coin, 'delegates', [alice.address]))[0], alice.address);
    await h.send(coin, bob, 'delegate', [bob.address]);
    await h.send(coin, alice, 'transfer', [bob.address, 7n * UNIT]);
    eq((await h.read(coin, 'getVotes', [alice.address]))[0], 93n * UNIT);
    eq((await h.read(coin, 'getVotes', [bob.address]))[0], 7n * UNIT);
    await h.send(coin, bob, 'burn', [UNIT]);
    eq((await h.read(coin, 'getVotes', [bob.address]))[0], 6n * UNIT);
    ok((await h.read(coin, 'numCheckpoints', [alice.address]))[0] > 0n);
    const checkpoint = (await h.read(coin, 'checkpoints', [alice.address, 0]))[0];
    ok(checkpoint[0] > 0n);
    await h.reverts(coin, alice, 'getPastVotes', [alice.address, MAX]);
    await h.reverts(coin, alice, 'getPastTotalSupply', [MAX]);
  });

  test('paid-fees-versus-deposits', async ({ h, coin, token }) => {
    const [admin, alice, bob] = h.users;
    await h.send(coin, admin, 'mint', [alice.address, 1000000n * UNIT]);
    await h.send(coin, alice, 'approve', [token.address, MAX]);
    const id = await create(h, token, alice, 100n * UNIT);
    await h.send(token, alice, 'chargeToken', [id, UNIT]);
    const before = (await h.read(coin, 'getUserEpoch', [alice.address, 0]))[0];
    eq(before[8], 0n);
    await h.send(token, alice, 'updateToken', [id, 0, 100n * UNIT, '0x12', ''], FLOOR);
    const after = (await h.read(coin, 'getUserEpoch', [alice.address, 0]))[0];
    ok(after[8] > 0n, 'metadata fee should earn points');
    await h.send(coin, alice, 'transfer', [bob.address, UNIT]);
    const unchanged = (await h.read(coin, 'getUserEpoch', [alice.address, 0]))[0];
    eq(unchanged[8], after[8]);
    await h.send(coin, admin, 'setSpendWeight', [token.address, 0]);
    await h.send(token, alice, 'updateToken', [id, 0, 100n * UNIT, '0x34', ''], FLOOR);
    const disabled = (await h.read(coin, 'getUserEpoch', [alice.address, 0]))[0];
    eq(disabled[8], after[8]);
  });

  test('metadata-payload-boundaries', async ({ h, coin, token }) => {
    const [admin, alice, bob] = h.users;
    await h.send(coin, admin, 'mint', [alice.address, 3000000n * UNIT]);
    await h.send(coin, alice, 'approve', [token.address, MAX]);
    for (const length of [0, 1, 31, 32, 33, 1024, 4096]) {
      const payload = '0x' + 'a5'.repeat(length);
      const id = await create(h, token, alice, 0n, payload);
      eq((await h.read(token, 'tokenData', [id]))[8], payload);
      await h.reverts(token, bob, 'updateToken', [id, 0, 0, payload, 'ipfs://denied'], FLOOR);
      await h.send(
        token,
        alice,
        'updateToken',
        [id, 0, 0, payload, 'ipfs://payload-' + length],
        FLOOR
      );
      eq((await h.read(token, 'tokenData', [id]))[8], payload);
      eq((await h.read(token, 'tokenURI', [id]))[0], 'ipfs://payload-' + length);
    }
  });

  test('nft-approval-transfer-restrictions', async ({ h, token }) => {
    const [, alice, bob, carol] = h.users;
    const id = await create(h, token, alice, 100n * UNIT, '0x', true);
    await h.reverts(token, bob, 'transferFrom', [alice.address, bob.address, id]);
    await h.send(token, alice, 'approve', [bob.address, id]);
    sameAddress((await h.read(token, 'getApproved', [id]))[0], bob.address);
    await h.send(token, bob, 'transferFrom', [alice.address, carol.address, id]);
    sameAddress((await h.read(token, 'ownerOf', [id]))[0], carol.address);
    sameAddress((await h.read(token, 'getApproved', [id]))[0], ZERO);
    eq(
      (await h.read(token, 'tokenContribution', [id, carol.address]))[4],
      true,
      'recipient auto whitelist'
    );
    await h.send(token, carol, 'setApprovalForAll', [bob.address, true]);
    eq((await h.read(token, 'isApprovedForAll', [carol.address, bob.address]))[0], true);
    await h.send(token, bob, 'safeTransferFrom(address,address,uint256)', [
      carol.address,
      alice.address,
      id,
    ]);
    sameAddress((await h.read(token, 'ownerOf', [id]))[0], alice.address);
    eq(
      (await h.read(token, 'tokenContribution', [id, carol.address]))[4],
      true,
      'whitelisting is persistent'
    );
    await h.send(token, alice, 'safeTransferFrom(address,address,uint256,bytes)', [
      alice.address,
      carol.address,
      id,
      '0x1234',
    ]);
    sameAddress((await h.read(token, 'ownerOf', [id]))[0], carol.address);
  });

  test('ownership-renunciation-is-explicit-and-final', async ({ h, token }) => {
    const [admin, alice] = h.users;
    await h.reverts(token, alice, 'renounceOwnership');
    await h.send(token, admin, 'renounceOwnership');
    sameAddress((await h.read(token, 'owner'))[0], ZERO);
    await h.reverts(token, admin, 'configure', [100, FLOOR, (FLOOR * 95n) / 100n, 32]);
    await h.reverts(token, admin, 'transferOwnership', [admin.address]);
  });

  test('inactive-refund-and-activation', async ({ h, coin, token }) => {
    const [admin, alice, bob] = h.users;
    await h.send(coin, admin, 'mint', [bob.address, 100n * UNIT]);
    await h.send(coin, bob, 'approve', [token.address, MAX]);
    const id = await create(h, token, alice, 1000n * UNIT);
    await h.send(token, bob, 'chargeTokenAs', [bob.address, id, 5n * UNIT]);
    eq((await h.read(token, 'tokenContribution', [id, bob.address]))[0], 5n * UNIT);
    await h.reverts(token, bob, 'activateToken', [id]);
    await h.reverts(token, alice, 'activateToken', [id]);
    await h.reverts(token, bob, 'dischargeToken', [id], FLOOR);
    await h.send(token, alice, 'dischargeToken', [id], FLOOR);
    await h.send(token, bob, 'withdraw');
    eq(await balance(h, coin, bob), 100n * UNIT, 'principal fully refunded');
    eq((await h.read(token, 'tokenData', [id]))[5], 0n);
    const active = await create(h, token, alice);
    await h.send(token, alice, 'activateToken', [active]);
    eq((await h.read(token, 'tokenData', [active]))[0], true);
    await h.send(token, bob, 'chargeToken', [active, UNIT]);
    ok((await h.read(token, 'tokenCharge', [active]))[1] >= UNIT);
    await h.send(token, alice, 'deactivateToken', [active]);
    eq((await h.read(token, 'tokenData', [active]))[0], false);
  });

  test('vault-payload-recall-and-rewrap', async ({ h, coin, token }) => {
    const [admin, alice, bob] = h.users;
    await h.send(coin, admin, 'mint', [alice.address, 100000n * UNIT]);
    await h.send(coin, alice, 'approve', [token.address, MAX]);
    const nft = await h.deploy('NFT');
    let externalId = 0;
    for (const length of [0, 1, 31, 32, 33, 1024, 4096]) {
      await h.send(nft, admin, 'mint', [alice.address, externalId]);
      await h.send(nft, alice, 'safeTransferFrom(address,address,uint256)', [
        alice.address,
        token.address,
        externalId,
      ]);
      await h.reverts(token, bob, 'recallToken', [nft.address, externalId]);
      await h.reverts(token, bob, 'vaultToken', [nft.address, externalId, '0x']);
      if (externalId === 0) {
        await h.send(token, alice, 'recallToken', [nft.address, externalId]);
        sameAddress((await h.read(nft, 'ownerOf', [externalId]))[0], alice.address);
        await h.send(nft, alice, 'safeTransferFrom(address,address,uint256)', [
          alice.address,
          token.address,
          externalId,
        ]);
      }
      const payload = '0x' + '3b'.repeat(length);
      const wrapped = await h.send(token, alice, 'vaultToken', [nft.address, externalId, payload]);
      const id = h.events(token, wrapped, 'Transfer').find((event) => event[0] === ZERO)[2];
      eq((await h.read(token, 'tokenData', [id]))[8], payload);
      eq((await h.read(token, 'tokenAttachment', [id]))[3], true);
      await h.reverts(token, alice, 'recallToken', [nft.address, externalId]);
      await h.send(token, alice, 'activateToken', [id]);
      await h.send(token, alice, 'recallToken', [nft.address, externalId]);
      eq((await h.read(token, 'tokenAttachment', [id]))[3], false);
      sameAddress((await h.read(nft, 'ownerOf', [externalId]))[0], alice.address);
      externalId++;
    }
  });

  test('missing-minter-and-best-effort-retry', async ({ h, coin, token }) => {
    const [admin, alice] = h.users;
    const id = await create(h, token, alice);
    await h.send(coin, admin, 'revokeRole', [h.id('MINTER_ROLE'), token.address]);
    await h.send(token, alice, 'withdraw');
    eq(await balance(h, coin, alice), 0n, 'failed mint must not fabricate a payout');
    sameAddress((await h.read(token, 'ownerOf', [id]))[0], alice.address);
    await h.send(coin, admin, 'grantRole', [h.id('MINTER_ROLE'), token.address]);
    await h.send(token, alice, 'withdraw');
    eq(await balance(h, coin, alice), UNIT, 'welcome payout survives failed mint');
    await h.send(token, alice, 'withdraw');
    eq(await balance(h, coin, alice), UNIT, 'no duplicate welcome payout');
  });

  test('governor-unauthorized-entry-points', async ({ h, governor, timelock }) => {
    const [, alice] = h.users;
    await h.reverts(governor, alice, 'setProposalThreshold', [0], 0n, 'GovernorOnlyExecutor');
    await h.reverts(
      governor,
      alice,
      'updateTimelock',
      [timelock.address],
      0n,
      'GovernorOnlyExecutor'
    );
    await h.reverts(governor, alice, 'relay', [alice.address, 0, '0x'], 0n, 'GovernorOnlyExecutor');
    await h.reverts(governor, alice, 'castVote', [0, 1]);
    await h.reverts(governor, alice, 'castVoteWithReason', [0, 1, '']);
    await h.reverts(governor, alice, 'castVoteBySig', [0, 1, alice.address, '0x']);
    await h.reverts(governor, alice, 'propose', [
      [alice.address],
      [0],
      ['0x'],
      'insufficient votes',
    ]);
    await h.reverts(governor, alice, 'lockCoins', [1, 0]);
    await h.reverts(governor, alice, 'unlockCoins');
    await h.reverts(governor, alice, 'finalizeMarket', [0]);
    await h.reverts(governor, alice, 'stake', [0, true, 0]);
    await h.reverts(governor, alice, 'claim', [0]);
    await h.reverts(governor, alice, 'burn', [0]);
    await h.reverts(timelock, alice, 'updateDelay', [0]);
    await h.reverts(timelock, alice, 'schedule', [
      alice.address,
      0,
      '0x',
      '0x' + '0'.repeat(64),
      h.id('unauthorized'),
      60,
    ]);
  });

  test('seeded-erc20-conservation', async ({ h, coin }) => {
    const [admin, ...users] = h.users.slice(0, 5);
    const model = users.map(() => 10000n);
    for (const user of users) await h.send(coin, admin, 'mint', [user.address, 10000]);
    let supply = 40000n,
      seed = 0xd1611;
    const next = () => {
      seed = (Math.imul(seed, 1664525) + 1013904223) >>> 0;
      return seed;
    };
    for (let i = 0; i < 48; i++) {
      const from = next() % 4,
        to = (from + 1 + (next() % 3)) % 4;
      const amount = BigInt(next() % 37);
      if (i % 5 === 0) {
        await h.send(coin, users[from], 'burn', [amount]);
        model[from] -= amount;
        supply -= amount;
      } else {
        await h.send(coin, users[from], 'transfer', [users[to].address, amount]);
        model[from] -= amount;
        model[to] += amount;
      }
      eq((await h.read(coin, 'totalSupply'))[0], supply, `seed 0xD1611 step ${i} supply`);
      for (let user = 0; user < 4; user++)
        eq(
          await balance(h, coin, users[user]),
          model[user],
          `seed 0xD1611 step ${i} account ${user}`
        );
    }
  });
  return tests;
}
module.exports = { scenarios, ok, eq, sameAddress, rejects, UNIT, FLOOR, MAX, ZERO };
