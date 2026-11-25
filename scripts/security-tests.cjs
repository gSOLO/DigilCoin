/**
 * Node-only security/economic regressions, including interface and boundary checks.
 * Each registered test starts from the common funded fixture via VM checkpoints.
 * Command: npm run test:security (do not use --diagnostic for release validation).
 */
const assert = require('node:assert/strict');
const { compile, sourcesIn, checkSizes } = require('./compile.cjs');
const { createHarness, bootstrap, gasLimit, unit, floor, ethers } = require('./evm.cjs');

async function main() {
  const contracts = compile({
    ...sourcesIn('contracts'),
    ...sourcesIn('tests', (f) => f === 'SecurityActors.sol'),
  });
  const diagnostic = process.argv.includes('--diagnostic');
  if (diagnostic)
    console.warn('DIAGNOSTIC ONLY: code-size exemptions enabled; not a deployment validation.');
  else checkSizes(contracts);
  const h = await createHarness(contracts, diagnostic);
  const { coin, token } = await bootstrap(h);
  const [admin, alice, bob, carol, dave] = h.users;
  for (const user of h.users.slice(0, 5)) {
    await h.send(coin, admin, 'mint', [user.address, 1000000n * unit]);
    await h.send(coin, user, 'approve', [token.address, ethers.MaxUint256]);
  }
  const spender = await h.deploy('FeeSpender', [], true, 'tests/SecurityActors.sol');
  const timelock = await h.deploy('DigilTimelock', [1, [], [ethers.ZeroAddress], admin.address]);
  const governor = await h.deploy('DigilGovernor', [coin.address, timelock.address, token.address]);
  await h.send(timelock, admin, 'grantRole', [ethers.id('PROPOSER_ROLE'), governor.address]);
  await h.send(timelock, admin, 'grantRole', [ethers.id('CANCELLER_ROLE'), governor.address]);
  await h.send(timelock, admin, 'grantRole', [ethers.id('CANCELLER_ROLE'), admin.address]);
  await h.send(coin, admin, 'delegate', [admin.address]);
  for (const user of h.users.slice(0, 5))
    await h.send(coin, user, 'approve', [governor.address, ethers.MaxUint256]);
  const balance = async (user) => (await h.read(coin, 'balanceOf', [user.address]))[0];
  const points = async (user) => (await h.read(coin, 'getUserEpoch', [user.address, 0]))[0].points;
  const create = async (user = alice, iv = 0n, threshold = 0n, plane = 0, data = '0x') =>
    h.result(
      token,
      'createToken',
      await h.send(token, user, 'createToken', [iv, threshold, false, plane, data], floor)
    )[0];
  const withdraw = async (user) =>
    h.result(token, 'withdraw', await h.send(token, user, 'withdraw'));
  const mintId = (result) =>
    h.events(token, result, 'Transfer').find((event) => event.from === ethers.ZeroAddress).tokenId;
  const proposal = async (
    description,
    targets = [coin.address],
    calldatas = [coin.iface.encodeFunctionData('approve', [dave.address, 0])]
  ) => {
    const values = targets.map(() => 0);
    await h.send(governor, admin, 'propose', [targets, values, calldatas, description]);
    const hash = ethers.id(description);
    const id = (await h.read(governor, 'hashProposal', [targets, values, calldatas, hash]))[0];
    return { id, targets, values, calldatas, hash };
  };
  const finishVote = async (p, support = 1) => {
    h.time = (await h.read(governor, 'proposalSnapshot', [p.id]))[0];
    if (support !== null)
      await h.send(governor, admin, 'castVoteWithReasonAndParams', [
        p.id,
        support,
        '',
        ethers.AbiCoder.defaultAbiCoder().encode(['uint256'], [0]),
      ]);
    h.time = (await h.read(governor, 'proposalDeadline', [p.id]))[0] + 1n;
  };
  const queue = (p) =>
    h.send(governor, admin, 'queue(address[],uint256[],bytes[],bytes32)', [
      p.targets,
      p.values,
      p.calldatas,
      p.hash,
    ]);
  const cancelQueued = async (p) => {
    const salt = ethers.toBeHex((BigInt(governor.address) << 96n) ^ BigInt(p.hash), 32);
    const operation = (
      await h.read(timelock, 'hashOperationBatch', [
        p.targets,
        p.values,
        p.calldatas,
        ethers.ZeroHash,
        salt,
      ])
    )[0];
    await h.send(timelock, admin, 'cancel', [operation]);
  };
  const linkCost = (efficiency, count, fresh, bonus = 0n) => {
    const excess =
      BigInt(efficiency) > 200n / BigInt(count) ? BigInt(efficiency) - 200n / BigInt(count) : 0n;
    let cost = (BigInt(efficiency) + (excess * (excess + 1n)) / 2n) * 100n * unit;
    if (bonus > 0n) cost = (cost * 100n) / (100n + bonus);
    if (fresh && count <= 2) cost /= 2n;
    return cost;
  };
  const tests = [];
  const test = (name, run) => tests.push({ name, run });

  test('Interfaces retain matching function, event, and error signatures', async () => {
    for (const [interfaceName, implementation] of [
      ['IDigilToken', 'DigilToken'],
      ['IDigilCoin', 'DigilCoin'],
    ]) {
      const expected = contracts[`contracts/${interfaceName}.sol`][interfaceName].abi;
      const actual = contracts[`contracts/${implementation}.sol`][implementation].abi;
      const key = (entry) =>
        `${entry.type}:${entry.name}(${(entry.inputs || []).map((x) => x.type).join(',')})`;
      for (const entry of expected.filter((x) => ['function', 'event', 'error'].includes(x.type))) {
        const found = actual.find((x) => key(x) === key(entry));
        assert.ok(found, key(entry));
        assert.deepEqual(
          (found.outputs || []).map((x) => x.type),
          (entry.outputs || []).map((x) => x.type)
        );
        if (entry.type === 'event')
          assert.deepEqual(
            found.inputs.map((x) => !!x.indexed),
            entry.inputs.map((x) => !!x.indexed)
          );
      }
    }
  });

  test('Only explicit weighted fees earn points; allowance, pause, and payer attribution hold', async () => {
    await h.send(coin, admin, 'setSpendWeight', [spender.address, 5000]);
    await h.send(coin, alice, 'approve', [spender.address, 1000n * unit]);
    await h.send(spender, bob, 'deposit', [coin.address, alice.address, 200n * unit]);
    assert.equal(await points(alice), 0n);
    await h.send(spender, bob, 'refund', [coin.address, alice.address, 200n * unit]);
    await h.send(coin, alice, 'transfer', [spender.address, unit]);
    await h.send(coin, alice, 'burn', [unit]);
    assert.equal(await points(alice), 0n);
    await h.send(spender, bob, 'pay', [coin.address, alice.address, 100n * unit]);
    assert.equal(await points(alice), 100n * unit * 5000n);
    assert.equal(await points(bob), 0n);
    assert.equal(
      (await h.read(coin, 'allowance', [alice.address, spender.address]))[0],
      700n * unit
    );
    await h.send(coin, admin, 'setSpendWeight', [spender.address, 0]);
    await h.send(spender, bob, 'pay', [coin.address, alice.address, 50n * unit]);
    assert.equal(await points(alice), 100n * unit * 5000n);
    await h.send(coin, admin, 'pause');
    await h.reverts(spender, bob, 'pay', [coin.address, alice.address, unit]);
    await h.send(coin, admin, 'unpause');
    await h.send(coin, alice, 'approve', [spender.address, 0]);
    await h.reverts(spender, bob, 'pay', [coin.address, alice.address, unit]);
  });

  test('Feature-fee integrations include paid alignment, metadata, links, prime, stabilize, and vault', async () => {
    await h.send(coin, admin, 'setRewardParameters', [
      unit,
      1000000n * unit,
      10000000n * unit,
      100,
      20,
    ]);
    const before = await balance(alice);
    const id = await create(alice, 0n, 1000n * unit, 8);
    const dest = await create(alice);
    await h.send(
      token,
      alice,
      'updateToken',
      [id, 0, 1000n * unit, '0x1234', 'ipfs://paid'],
      floor
    );
    await h.send(token, alice, 'linkToken', [id, dest, 1]);
    await h.send(token, alice, 'linkToken', [id, dest, 2]);
    await h.send(token, alice, 'primeToken', [id]);
    await h.send(token, alice, 'activateToken', [dest]);
    await h.send(token, alice, 'overchargeToken', [dest, unit], 2n * floor);
    await h.send(token, alice, 'stabilizeToken', [dest]);
    const nft = await h.deploy('NFT');
    await h.send(nft, admin, 'mint', [alice.address, 1]);
    await h.send(nft, alice, 'safeTransferFrom(address,address,uint256)', [
      alice.address,
      token.address,
      1,
    ]);
    await h.send(token, alice, 'vaultToken', [nft.address, 1, '0x']);
    assert.equal(await points(alice), (before - (await balance(alice))) * 10000n);
    assert.ok((await points(alice)) > 0n);
  });

  test('Refunded, sponsored, and active charges earn no donor rewards', async () => {
    const id = await create(alice, 0n, 1000n * unit);
    const before = await balance(bob);
    await h.send(coin, admin, 'donate', [], unit);
    await h.send(token, bob, 'chargeToken', [id, 500n * unit]);
    await h.send(token, alice, 'dischargeToken', [id], floor);
    assert.equal((await withdraw(bob))[0], 500n * unit);
    assert.equal(await balance(bob), before);
    assert.equal(await points(bob), 0n);
    await h.send(token, bob, 'chargeTokenAs', [carol.address, id, unit], floor);
    assert.equal(await points(bob), 0n);
    assert.equal(await points(carol), 0n);
    const active = await create(alice);
    await h.send(token, alice, 'activateToken', [active]);
    await h.send(token, bob, 'chargeToken', [active, unit]);
    assert.equal(await points(bob), 0n);
    h.time += 30n * 86400n;
    await h.send(coin, bob, 'claim', [0]);
    assert.equal((await h.read(coin, 'totalClaimedEth'))[0], 0n);
  });

  test('Exact protocol ETH fees reject short and excess payments and credit the full fee', async () => {
    const id = await create(alice, 3n * floor);
    await h.send(token, bob, 'chargeToken', [id, unit], 3n * floor);
    h.time += 90n * 86400n;

    async function checkFee(user, method, args, fee) {
      for (const value of [fee - 1n, fee + 1n]) {
        const failed = await h.send(token, user, method, args, value, true);
        assert.equal(failed.execResult.exceptionError?.error, 'revert');
        assert.equal(
          ethers.hexlify(failed.execResult.returnValue),
          token.iface.encodeErrorResult('InsufficientFunds', [fee])
        );
      }
      await h.send(token, user, method, args, fee);
      // Spend the protocol credit on a different token. Each check starts with an empty pool.
      await h.reverts(token, admin, 'createValue', [0, fee + 1n], 0n, 'InsufficientFunds');
      await h.send(token, admin, 'createValue', [0, fee]);
    }

    await checkFee(bob, 'setOptStatus', [true], 100n * floor);
    await checkFee(bob, 'setOptStatus', [false], 100n * floor);
    await checkFee(bob, 'reclaimContribution', [id], 3n * floor);
    assert.equal((await withdraw(bob))[1], 3n * floor);
    await checkFee(admin, 'overchargeToken', [1, 3n * unit], 6n * floor);
    assert.equal((await h.read(token, 'tokenCharge', [1])).activeCharge, 3n * unit);
  });

  test('Epoch caps, rollover, claims, and replay guards still apply to explicit fees', async () => {
    await h.send(coin, admin, 'setSpendWeight', [spender.address, 10000]);
    await h.send(coin, alice, 'approve', [spender.address, ethers.MaxUint256]);
    await h.send(coin, admin, 'donate', [], unit);
    await h.send(spender, bob, 'pay', [coin.address, alice.address, 600n * unit]);
    assert.equal(await points(alice), 500n * unit * 10000n);
    await h.send(spender, bob, 'pay', [coin.address, alice.address, unit]);
    assert.equal(await points(alice), 500n * unit * 10000n);
    h.time += 86400n;
    await h.send(spender, bob, 'pay', [coin.address, alice.address, 50n * unit]);
    assert.equal(await points(alice), 550n * unit * 10000n);
    h.time += 30n * 86400n;
    await h.send(coin, alice, 'claim', [0]);
    assert.equal((await h.read(coin, 'totalClaimedEth'))[0], unit);
    await h.reverts(coin, alice, 'claim', [0], 0n, 'AlreadyClaimed');
    h.time += 13n * 30n * 86400n;
    await h.send(spender, bob, 'pay', [coin.address, alice.address, unit]);
    assert.ok((await h.read(coin, 'currentEpochId'))[0] >= 14n);
    await h.reverts(coin, alice, 'claim', [0]);
  });

  test('User epoch history follows retained global slots and preserves the epoch-zero sentinel', async () => {
    const start = (await h.read(coin, 'currentEpochStart'))[0];
    const length = (await h.read(coin, 'EPOCH_LENGTH'))[0];
    const read = async (user, epoch) =>
      (await h.read(coin, 'getUserEpoch', [user.address, epoch]))[0];
    const sync = async (epoch) => {
      h.time = start + BigInt(epoch) * length;
      await h.send(coin, admin, 'syncEpoch');
      assert.equal((await h.read(coin, 'currentEpochId'))[0], BigInt(epoch));
    };
    await create(alice, 0n, 0n, 8);
    await h.send(coin, admin, 'donate', [], unit);
    const earned = (await read(alice, 0)).points;
    assert.ok(earned > 0n);
    assert.ok((await read(dave, 0)).every((field) => field === 0n));
    await sync(1);
    const zeroClaim = await h.send(coin, bob, 'claimMany', [[0]]);
    const [zeroEvent] = h.events(coin, zeroClaim, 'Claim');
    assert.equal(zeroEvent.account.toLowerCase(), bob.address);
    assert.equal(zeroEvent.epochId, 0n);
    assert.equal(zeroEvent.amount, 0n);
    assert.equal(zeroEvent.userEff, 0n);
    await h.reverts(coin, bob, 'claim', [0], 0n, 'AlreadyClaimed');
    const paidClaim = await h.send(coin, alice, 'claim', [0]);
    const [paidEvent] = h.events(coin, paidClaim, 'Claim');
    assert.equal(paidEvent.account.toLowerCase(), alice.address);
    assert.equal(paidEvent.epochId, 0n);
    assert.equal(paidEvent.amount, unit);
    assert.equal(paidEvent.userEff, paidEvent.totalEff);
    assert.equal(paidEvent.totalEff, zeroEvent.totalEff);
    assert.equal((await h.read(coin, 'totalClaimedEth'))[0], unit);
    for (const epoch of [4, 11]) {
      await sync(epoch);
      assert.equal((await read(alice, 0)).points, earned);
      assert.equal((await read(bob, 0)).flags, 1n);
      assert.ok((await read(dave, 0)).every((field) => field === 0n));
      await h.reverts(coin, admin, 'getUserEpoch', [dave.address, epoch], 0n, 'NothingToClaim');
    }
    await sync(12);
    for (const user of [alice, bob, dave]) {
      await h.reverts(coin, admin, 'getUserEpoch', [user.address, 0], 0n, 'EpochNotFound');
    }
    await create(carol, 0n, 0n, 8);
    assert.ok((await read(carol, 12)).points > 0n);
    await sync(40); // A single jump exceeds the normal rollover threshold.
    await h.reverts(coin, admin, 'getUserEpoch', [carol.address, 12], 0n, 'EpochNotFound');
  });

  test('Welcome gifts require paid creation and share eligibility with paid vaulting', async () => {
    assert.equal((await withdraw(admin))[0], 0n, 'Constructor planar mints grant no gift');
    const id = await create(alice);
    assert.equal((await withdraw(alice))[0], unit);
    let owner = alice;
    for (const recipient of [bob, carol, dave]) {
      await h.send(token, owner, 'transferFrom', [owner.address, recipient.address, id]);
      assert.equal((await withdraw(recipient))[0], 0n);
      owner = recipient;
    }
    const nft = await h.deploy('NFT');
    await h.send(nft, admin, 'mint', [bob.address, 1]);
    await h.send(nft, bob, 'safeTransferFrom(address,address,uint256)', [
      bob.address,
      token.address,
      1,
    ]);
    await h.send(token, bob, 'vaultToken', [nft.address, 1, '0x']);
    assert.equal((await withdraw(bob))[0], unit, 'A former recipient can earn the paid-vault gift');
    await create(bob);
    assert.equal((await withdraw(bob))[0], 0n, 'Vault and create share eligibility');
    await create(alice);
    assert.equal((await withdraw(alice))[0], 0n, 'Selling all NFTs does not reset eligibility');
    await create(carol);
    assert.equal((await withdraw(carol))[0], unit, 'A former recipient can earn the creation gift');
  });

  test('Superseded wrappers never report custody or regain recall rights', async () => {
    const nft = await h.deploy('NFT');
    await h.send(nft, admin, 'mint', [bob.address, 0]);
    const wrap = async () => {
      await h.send(nft, bob, 'safeTransferFrom(address,address,uint256)', [
        bob.address,
        token.address,
        0,
      ]);
      return mintId(await h.send(token, bob, 'vaultToken', [nft.address, 0, '0x']));
    };
    const oldId = await wrap();
    await h.send(token, bob, 'activateToken', [oldId]);
    await h.send(token, bob, 'recallToken', [nft.address, 0]);
    const newId = await wrap();
    await h.send(token, bob, 'deactivateToken', [oldId]);
    await h.send(token, bob, 'activateToken', [oldId]);
    const old = await h.read(token, 'tokenAttachment', [oldId]);
    assert.equal(old[0].toLowerCase(), nft.address.toLowerCase());
    assert.deepEqual(Array.from(old).slice(2), [false, false]);
    assert.deepEqual(Array.from(await h.read(token, 'tokenAttachment', [newId])).slice(2), [
      false,
      true,
    ]);
    await h.reverts(token, bob, 'recallToken', [nft.address, 0]);
    await h.send(token, bob, 'activateToken', [newId]);
    await h.send(token, bob, 'recallToken', [nft.address, 0]);
    assert.equal((await h.read(nft, 'ownerOf', [0]))[0].toLowerCase(), bob.address.toLowerCase());
  });

  test('Failed creation fees roll back minting, reward points, and welcome eligibility', async () => {
    const before = await balance(bob);
    await h.send(coin, bob, 'approve', [token.address, 0]);
    await h.reverts(token, bob, 'createToken', [0, 0, false, 8, '0x'], floor, 'CoinTransferFailed');
    await h.send(coin, bob, 'approve', [token.address, ethers.MaxUint256]);
    await h.send(coin, admin, 'pause');
    await h.reverts(token, bob, 'createToken', [0, 0, false, 8, '0x'], floor, 'CoinTransferFailed');
    await h.send(coin, admin, 'unpause');
    assert.equal((await h.read(token, 'balanceOf', [bob.address]))[0], 0n);
    assert.equal(await balance(bob), before);
    assert.equal(await points(bob), 0n);
    await create(bob, 0n, 0n, 8);
    assert.equal((await withdraw(bob))[0], unit);
  });

  test('Dynamic metadata and vault payloads preserve contents across storage-word boundaries', async () => {
    await h.send(coin, admin, 'mint', [alice.address, 2000000n * unit]);
    const nft = await h.deploy('NFT');
    for (const length of [0, 1, 31, 32, 33, 1024, 4096]) {
      const payload = '0x' + 'ab'.repeat(length);
      const id = await create(alice, 0n, 0n, 0, payload);
      assert.equal((await h.read(token, 'tokenData', [id]))[8], payload);
      const uri = 'ipfs://' + 'x'.repeat(length);
      await h.send(token, alice, 'updateToken', [id, 0, 0, payload, uri], floor);
      assert.equal((await h.read(token, 'tokenData', [id]))[8], payload);
      assert.equal((await h.read(token, 'tokenURI', [id]))[0], uri);
      await h.send(nft, admin, 'mint', [alice.address, length]);
      await h.send(nft, alice, 'safeTransferFrom(address,address,uint256,bytes)', [
        alice.address,
        token.address,
        length,
        payload,
      ]);
      const wrapper = mintId(
        await h.send(token, alice, 'vaultToken', [nft.address, length, payload])
      );
      assert.equal((await h.read(token, 'tokenData', [wrapper]))[8], payload);
      assert.equal((await h.read(token, 'tokenAttachment', [wrapper]))[3], true);
    }
  });

  test('No-op updates, whitelist entries, self-transfers, and zero enrichment do not postpone reclaim', async () => {
    const id = await create(alice, floor, 100n * unit, 0, '0x1234');
    await h.send(token, alice, 'updateToken', [id, floor, 100n * unit, '0x', 'ipfs://same'], floor);
    await h.send(token, alice, 'restrictToken', [id, [bob.address]], floor);
    await h.send(token, bob, 'chargeToken', [id, unit], floor);
    h.time += 90n * 86400n;
    await h.send(token, alice, 'updateToken', [id, floor, 100n * unit, '0x', '']);
    await h.send(
      token,
      alice,
      'updateToken',
      [id, floor, 100n * unit, '0x1234', 'ipfs://same'],
      floor
    );
    await h.send(token, alice, 'restrictToken', [id, [bob.address]]);
    await h.send(token, alice, 'transferFrom', [alice.address, alice.address, id]);
    await h.send(token, admin, 'createValue', [id, 0], floor);
    await h.send(token, bob, 'reclaimContribution', [id], floor);
    assert.equal((await withdraw(bob))[1], floor);
    await h.reverts(token, bob, 'reclaimContribution', [id], floor);
  });

  test('Genuine metadata, whitelist, enrichment, and ownership changes restart inactivity', async () => {
    const actions = [
      (id) => h.send(token, alice, 'updateToken', [id, floor, 100n * unit, '0x01', ''], floor),
      (id) => h.send(token, alice, 'restrictToken', [id, [bob.address, carol.address]]),
      (id) => h.send(token, admin, 'createValue', [id, floor], floor),
      (id) => h.send(token, alice, 'transferFrom', [alice.address, carol.address, id]),
    ];
    for (const action of actions) {
      const id = await create(alice, floor, 100n * unit);
      await h.send(token, alice, 'restrictToken', [id, [bob.address]], floor);
      await h.send(token, bob, 'chargeToken', [id, unit], floor);
      h.time += 90n * 86400n;
      await action(id);
      await h.reverts(token, bob, 'reclaimContribution', [id], floor);
      h.time += 90n * 86400n;
      await h.send(token, bob, 'reclaimContribution', [id], floor);
    }
  });

  test('Permanent affinity acquired during attunement survives expiry', async () => {
    const source = await create(alice, 0n, 0n, 4);
    const dest = await create(alice, 0n, 0n, 4);
    await h.send(token, alice, 'activateToken', [source]);
    await h.send(token, alice, 'overchargeToken', [source, 1000n * unit], 2000n * floor);
    await h.send(token, alice, 'buffToken', [source, 0, 17, 0, 0, 0, 1]);
    await h.send(token, alice, 'linkToken', [source, dest, 100]);
    assert.equal((await h.read(token, 'tokenLinkAt', [source, 1]))[2], 400n);
    h.time += 120n;
    assert.equal((await h.read(token, 'tokenLinkAt', [source, 1]))[2], 400n);
  });

  test('Maximum link efficiency, buff discount, ten-link settlement, and last-element removal remain bounded', async () => {
    await h.send(coin, admin, 'mint', [alice.address, 100000000n * unit]);
    const source = await create(alice);
    const targets = [];
    for (let count = 1; count <= 10; count++) {
      const destination = await create(alice);
      targets.push(destination);
      const before = await balance(alice);
      await h.send(token, alice, 'linkToken', [source, destination, 254]);
      assert.equal(before - (await balance(alice)), linkCost(254, count, true));
    }
    const extra = await create(alice);
    await h.reverts(token, alice, 'linkToken', [source, extra, 255]);
    assert.equal((await h.read(token, 'tokenData', [source]))[4], 10n);
    await h.send(token, alice, 'activateToken', [source]);
    await h.send(token, alice, 'overchargeToken', [source, 5000n * unit], 10000n * floor);
    await h.send(token, alice, 'buffToken', [source, 100, 0, 0, 0, 0, 2]);
    for (const destination of targets) {
      const before = await balance(alice);
      await h.send(token, alice, 'linkToken', [source, destination, 255]);
      assert.equal(
        before - (await balance(alice)),
        linkCost(255, 10, false, 100n) - linkCost(254, 10, false, 100n)
      );
      await h.send(token, alice, 'activateToken', [destination]);
    }
    await h.reverts(token, alice, 'linkToken', [source, targets[0], 255]);
    const charge = (await h.read(token, 'tokenCharge', [source]))[1];
    await h.send(token, alice, 'dischargeToken', [source], 10n * floor);
    for (const destination of targets)
      assert.equal((await h.read(token, 'tokenCharge', [destination]))[1], charge / 10n);
    assert.equal((await h.read(token, 'tokenCharge', [source]))[1], 0n);
    for (let i = 0; i < targets.length; i++) {
      await h.send(token, alice, 'unlinkToken', [source, targets[i]]);
      assert.equal((await h.read(token, 'tokenData', [source]))[4], BigInt(9 - i));
    }
    await h.reverts(token, alice, 'unlinkToken', [source, targets[0]]);
  });

  test('Linked pricing skips an overflowing destination and settles the other shares', async () => {
    const price = unit; // One ETH per DIGIL.
    const source = await create(alice);
    const first = await create(bob);
    const priced = await create(bob, price);
    const last = await create(bob);
    await h.send(token, alice, 'activateToken', [source]);
    for (const id of [first, priced, last]) {
      await h.send(token, alice, 'linkToken', [source, id, 100], id === priced ? price : 0n);
    }
    await withdraw(alice); // Clear the source owner's creation and activation payouts.

    // Each link receives one DIGIL and one ETH. The priced link accepts its exact quote.
    await h.send(token, bob, 'chargeToken', [source, 3n * unit], 3n * price);
    const paid = await h.read(token, 'tokenContribution', [priced, bob.address]);
    assert.equal(paid.charge, unit);
    assert.equal(paid.value, price);

    // Use a fixture-minted balance to exercise the upper bound at the same ordinary price.
    const share = 1n << 200n;
    const deposit = 3n * share;
    await h.send(coin, admin, 'mint', [carol.address, deposit]);
    const before = await balance(carol);
    await h.send(token, carol, 'chargeToken', [source, deposit], 3n * price + 1n);
    assert.equal(before - (await balance(carol)), deposit);
    assert.equal((await h.read(token, 'tokenCharge', [source])).activeCharge, share);
    assert.equal((await h.read(token, 'tokenContribution', [priced, carol.address])).exists, false);
    for (const id of [first, last]) {
      const received = await h.read(token, 'tokenContribution', [id, carol.address]);
      assert.equal(received.charge, share);
      assert.equal(received.value, price);
    }
    const unusedETH = price + 1n; // Skipped share plus the one-wei split remainder.
    assert.equal((await withdraw(alice))[1], unusedETH - unusedETH / 20n); // Default 5% fee.
  });

  test('Affinity arithmetic preserves strong, moderate, weak, ethereal, and stronger-destination bounds', async () => {
    await h.send(coin, admin, 'mint', [alice.address, 100000000n * unit]);
    const pairs = [
      [4, 5],
      [4, 4],
      [4, 18],
      [4, 10],
      [4, 1],
      [12, 2],
      [12, 12],
      [17, 1],
      [17, 17],
      [18, 17],
    ];
    let maximum = 0n;
    for (const [sourcePlane, destinationPlane] of pairs) {
      const source = await create(alice, 0n, 0n, sourcePlane);
      const destination = await create(alice, 0n, 0n, destinationPlane);
      const s = ethers.getBytes((await h.read(token, 'tokenData', [sourcePlane]))[8]);
      const d = ethers.getBytes((await h.read(token, 'tokenData', [destinationPlane]))[8]);
      for (const efficiency of [1n, 255n]) {
        let expected = 0n;
        if (s[1] === d[0] || s[2] === d[0]) expected = efficiency * 2n;
        else if (sourcePlane === destinationPlane || sourcePlane > 16) expected = efficiency;
        else if (s[3] === d[0]) expected = efficiency / 2n;
        else if (s[4] === d[0]) expected = efficiency / 4n;
        if (sourcePlane > 16) expected *= 4n;
        else if (sourcePlane > 11 || destinationPlane === 18) expected *= 2n;
        await h.send(token, alice, 'linkToken', [source, destination, efficiency]);
        const actual = (await h.read(token, 'tokenLinkAt', [source, 1]))[2];
        assert.equal(actual, expected);
        assert.ok(actual <= 2040n);
        if (actual > maximum) maximum = actual;
      }
    }
    assert.equal(maximum, 2040n);
    await h.send(token, admin, 'overchargeToken', [5, unit], 2n * floor);
    const source = await create(alice, 0n, 0n, 4);
    const destination = await create(alice, 0n, 0n, 5);
    await h.send(token, alice, 'linkToken', [source, destination, 255]);
    assert.equal((await h.read(token, 'tokenLinkAt', [source, 1]))[2], 255n);
  });

  test('New-link buff charges stop exactly at expiry and insufficient active charge still reverts', async () => {
    const source = await create(alice);
    const first = await create(alice);
    const second = await create(alice);
    await h.send(token, alice, 'activateToken', [source]);
    await h.send(token, alice, 'overchargeToken', [source, 1000n * unit], 2000n * floor);
    await h.send(token, alice, 'buffToken', [source, 100, 0, 0, 0, 0, 1]);
    const expiry = (await h.read(token, 'tokenBuff', [source]))[0];
    const beforeCharge = (await h.read(token, 'tokenCharge', [source]))[1];
    let beforeCoins = await balance(alice);
    h.time = expiry - 2n; // h.send advances the timestamp by one second.
    await h.send(token, alice, 'linkToken', [source, first, 255]);
    assert.equal(beforeCoins - (await balance(alice)), linkCost(255, 1, true, 100n));
    assert.equal((await h.read(token, 'tokenCharge', [source]))[1], beforeCharge - 100n * unit);
    beforeCoins = await balance(alice);
    await h.send(token, alice, 'linkToken', [source, second, 254]);
    assert.equal(h.time, expiry);
    assert.equal(beforeCoins - (await balance(alice)), linkCost(254, 2, true));
    assert.equal((await h.read(token, 'tokenCharge', [source]))[1], beforeCharge - 100n * unit);
    const depleted = await create(alice);
    await h.send(token, alice, 'activateToken', [depleted]);
    await h.send(token, alice, 'overchargeToken', [depleted, 100n * unit], 200n * floor);
    await h.send(token, alice, 'buffToken', [depleted, 100, 0, 0, 0, 0, 1]);
    beforeCoins = await balance(alice);
    await h.reverts(
      token,
      alice,
      'linkToken',
      [depleted, first, 1],
      0n,
      'InsufficientActiveCharge'
    );
    assert.equal(await balance(alice), beforeCoins);
    assert.equal((await h.read(token, 'tokenData', [depleted]))[4], 0n);
    assert.equal((await h.read(token, 'tokenCharge', [depleted]))[1], 0n);
  });

  test('Buff discounts preserve link upgrade rounding and the stabilization price floor', async () => {
    for (const [charge, bonus, expire] of [
      [1000n * unit, 0n, false],
      [1000n * unit, 37n, false],
      [10000n * unit + 23n, 37n, false],
      [10000n * unit + 23n, 37n, true],
    ]) {
      const source = await create(alice);
      const peer = await create(alice);
      await h.send(token, alice, 'activateToken', [source]);
      await h.send(token, alice, 'overchargeToken', [source, charge], (2n * floor * charge) / unit);
      if (bonus) await h.send(token, alice, 'buffToken', [source, bonus, 0, 0, 0, 0, 1]);

      let before = await balance(alice);
      await h.send(token, alice, 'linkToken', [source, peer, 7]);
      assert.equal(before - (await balance(alice)), linkCost(7, 1, true, bonus));
      before = await balance(alice);
      await h.send(token, alice, 'linkToken', [source, peer, 11]);
      assert.equal(
        before - (await balance(alice)),
        linkCost(11, 1, false, bonus) - linkCost(7, 1, false, bonus)
      );

      if (expire) h.time = (await h.read(token, 'tokenBuff', [source])).expiresAt - 1n;
      const { activeCharge } = await h.read(token, 'tokenCharge', [source]);
      const baseCost = activeCharge / 4n > 1000n * unit ? activeCharge / 4n : 1000n * unit;
      const expected = (baseCost * 100n) / (100n + (expire ? 0n : bonus));
      before = await balance(alice);
      await h.send(token, alice, 'stabilizeToken', [source]);
      assert.equal(before - (await balance(alice)), expected);
    }
  });

  test('Discharge keepers share only the fixed ETH fee, including final batches across repeated cycles', async () => {
    await h.send(token, admin, 'configure', [100, floor, 95000000000000n, 32]);
    const id = await create(alice, floor, 1000n * unit);
    await withdraw(alice);
    const contributors = h.users.slice(10, 43);
    for (let cycle = 0; cycle < 2; cycle++) {
      for (const user of contributors)
        await h.send(token, admin, 'chargeTokenAs', [user.address, id, unit], floor);
      await h.send(token, alice, 'dischargeToken', [id], floor);
      const first = await withdraw(alice);
      assert.equal(first[0], 0n);
      assert.equal(first[1], ((floor / 10n) * 32n) / 33n);
      await h.reverts(token, carol, 'dischargeToken', [id], 1n);
      await h.reverts(token, alice, 'transferFrom', [alice.address, bob.address, id]);
      await h.reverts(token, admin, 'chargeToken', [id, unit]);
      await h.send(token, admin, 'configure', [100, floor, 95000000000000n, 64]);
      await h.send(token, dave, 'dischargeToken', [id]);
      const last = await withdraw(dave);
      assert.equal(last[0], 0n);
      assert.equal(first[1] + last[1], floor / 10n);
      for (const user of contributors) {
        const refund = await withdraw(user);
        assert.equal(refund[0], unit);
        assert.equal(refund[1], floor);
      }
      assert.equal((await h.read(token, 'tokenData', [id]))[7], 0n);
      assert.equal((await h.read(token, 'tokenData', [id]))[6], BigInt(cycle + 1));
      await withdraw(alice); // Any residual owner intrinsic value is separate from keeper rewards.
      await h.send(token, admin, 'configure', [100, floor, 95000000000000n, 32]);
    }
  });

  test('Activation rewards use actual direct deposits, exclude linked charge, and pay final-batch rounding', async () => {
    await h.send(token, admin, 'configure', [100, floor, 95000000000000n, 32]);
    const id = await create(alice);
    await withdraw(alice);
    const source = await create(bob);
    await h.send(token, bob, 'activateToken', [source]);
    await h.send(token, bob, 'linkToken', [source, id, 200]);
    await h.send(token, bob, 'chargeToken', [source, 100n * unit]);
    // Linked efficiency can create more charge than the directly deposited coins.
    for (const user of h.users.slice(10, 43)) {
      await h.send(coin, admin, 'mint', [user.address, unit + 16n]);
      await h.send(coin, user, 'approve', [token.address, unit + 16n]);
      await h.send(token, user, 'chargeToken', [id, unit + 16n]);
    }
    await h.send(token, alice, 'activateToken', [id]);
    const first = await withdraw(alice);
    assert.equal(first[0], (31n * (unit + 16n)) / 100n);
    await h.send(token, admin, 'configure', [100, floor, 95000000000000n, 64]);
    await h.send(token, dave, 'activateToken', [id]);
    const last = await withdraw(dave);
    assert.equal(first[0] + last[0], (33n * (unit + 16n)) / 100n);
    assert.equal(
      last[0],
      (2n * (unit + 16n)) / 100n + 1n,
      'Final batch receives the rounding carry'
    );
    assert.ok(last[0] > 0n);
    await h.reverts(token, dave, 'activateToken', [id]);
  });

  test('Single-batch and empty settlements grant no keeper allocation', async () => {
    const id = await create(alice);
    // Keep the operator separate from the owner and contributor's ordinary payouts.
    await h.send(token, alice, 'approve', [bob.address, id]);
    await h.send(token, carol, 'chargeToken', [id, 100n * unit]);
    await h.send(token, bob, 'dischargeToken', [id], floor);
    assert.deepEqual(Array.from(await withdraw(bob)), [0n, 0n]);
    assert.deepEqual(Array.from(await withdraw(carol)), [100n * unit, 0n]);
    await h.reverts(token, bob, 'dischargeToken', [id], floor);
    await h.send(token, carol, 'chargeToken', [id, 100n * unit]);
    await h.send(token, bob, 'activateToken', [id]);
    assert.deepEqual(Array.from(await withdraw(bob)), [0n, 0n]);
    const empty = await create(alice);
    await h.send(token, alice, 'approve', [bob.address, empty]);
    await h.send(token, bob, 'activateToken', [empty]);
    assert.deepEqual(Array.from(await withdraw(bob)), [0n, 0n]);
    await h.reverts(token, bob, 'activateToken', [empty]);
  });

  test('A temporarily underfunded DIGIL refund pays ETH and can be funded and collected once', async () => {
    const id = await create(alice, floor);
    await h.send(coin, admin, 'revokeRole', [ethers.id('MINTER_ROLE'), token.address]);
    await h.send(token, bob, 'chargeToken', [id, unit], floor);
    assert.equal((await withdraw(alice))[0], unit); // The existing welcome credit uses available DIGIL.
    await h.send(token, alice, 'dischargeToken', [id], floor);
    assert.deepEqual(Array.from(await withdraw(bob)), [0n, floor]);
    await h.send(coin, carol, 'transfer', [token.address, unit]);
    assert.deepEqual(Array.from(await withdraw(bob)), [unit, 0n]);
    assert.deepEqual(Array.from(await withdraw(bob)), [0n, 0n]);
  });

  test('Exact batch endpoints complete once and preserve starter authorization and keeper totals', async () => {
    await h.send(token, admin, 'configure', [100, floor, 95000000000000n, 32]);
    for (const count of [31, 32, 64]) {
      const id = await create(alice);
      await h.send(token, alice, 'approve', [bob.address, id]);
      for (let i = 0; i < count; i++) {
        const contributor = ethers.getAddress(ethers.toBeHex(1000 + i, 20));
        await h.send(token, admin, 'chargeTokenAs', [contributor, id, unit], floor);
      }
      await h.reverts(token, carol, 'activateToken', [id]);
      const first = await h.send(token, bob, 'activateToken', [id]);
      assert.equal(h.result(token, 'activateToken', first)[0], count <= 32);
      if (count === 64) {
        const pending = await h.read(token, 'tokenData', [id]);
        assert.equal(pending[1], true);
        assert.equal(pending[7], 32n);
        assert.equal((await withdraw(bob))[0], (32n * unit) / 100n);
        const last = await h.send(token, dave, 'activateToken', [id]);
        assert.equal(h.result(token, 'activateToken', last)[0], true);
        assert.equal((await withdraw(dave))[0], (32n * unit) / 100n);
      } else {
        assert.equal((await withdraw(bob))[0], 0n);
      }
      const finished = await h.read(token, 'tokenData', [id]);
      assert.equal(finished[0], true);
      assert.equal(finished[1], false);
      assert.equal(finished[5], 0n);
      assert.equal(finished[6], 1n);
      assert.equal(finished[7], 0n);
      await h.reverts(token, bob, 'activateToken', [id]);
    }
  });

  test('Recommended settlement batches fit Osaka with fresh payouts and ten outgoing links', async () => {
    const recommendedBatch = 256;
    const count = 3 * recommendedBatch;
    const configure = (size) =>
      h.send(token, admin, 'configure', [100, floor, (floor * 95n) / 100n, size]);
    await h.reverts(token, admin, 'configure', [100, floor, (floor * 95n) / 100n, 31]);
    await configure(2048);
    await h.reverts(token, admin, 'configure', [100, floor, (floor * 95n) / 100n, 2049]);
    const id = await create(alice, floor);
    await h.send(token, alice, 'activateToken', [id]);
    await h.send(token, alice, 'overchargeToken', [id, 100n * unit], 200n * floor);
    await h.send(token, alice, 'deactivateToken', [id]);
    for (let i = 0; i < 10; i++) {
      const peer = await create(alice);
      await h.send(token, alice, 'linkToken', [id, peer, 1], floor);
    }
    const funding = BigInt(count) * floor;
    await h.send(token, admin, 'createValue', [id, funding], funding);
    await h.send(token, alice, 'approve', [bob.address, id]);
    const [first, last] = h.users.slice(10, 12);
    for (let i = 0; i < count; i++) {
      const beneficiary =
        i === 0 ? first.address : i === count - 1 ? last.address : ethers.toBeHex(10000 + i, 20);
      await h.send(token, admin, 'chargeTokenAs', [beneficiary, id, unit], floor);
    }
    const share = (await h.read(token, 'tokenCharge', [id])).value / BigInt(count);
    for (const method of ['activateToken', 'dischargeToken']) {
      const discharge = method === 'dischargeToken';
      const keeperBudget = discharge ? floor : (BigInt(count) * unit) / 100n;
      for (const [initial, following] of [
        [128, 128],
        [recommendedBatch, recommendedBatch],
        [recommendedBatch + 1, 128],
      ]) {
        const { time, height } = h;
        await h.vm.stateManager.checkpoint();
        try {
          await configure(initial);
          const gas = [];
          let processed = 0;
          while (processed < count) {
            const starting = processed === 0;
            const result = await h.send(
              token,
              starting ? bob : carol,
              method,
              [id],
              starting && discharge ? 10n * floor : 0n
            );
            gas.push(result.totalGasSpent);
            processed = Math.min(count, processed + (starting ? initial : following));
            assert.equal(h.result(token, method, result)[0], processed === count);
            if (starting && initial !== following) {
              const coinsBefore = await balance(bob);
              const pointsBefore = await points(bob);
              if (discharge) {
                await h.reverts(token, bob, 'stabilizeToken', [id]);
                assert.equal(await balance(bob), coinsBefore);
                assert.equal(await points(bob), pointsBefore);
              } else {
                await h.send(token, bob, 'stabilizeToken', [id]);
                assert.ok((await balance(bob)) < coinsBefore);
                assert.ok((await points(bob)) > pointsBefore);
              }
              await configure(following);
            }
          }
          assert.ok(gas.every((used) => used <= gasLimit));
          if (initial === following)
            console.log(`${method} at batch ${initial}, gas per receipt: ${gas.join(', ')}`);
          const asset = discharge ? 1 : 0;
          const starter = (await withdraw(bob))[asset];
          assert.equal(starter, (keeperBudget * BigInt(initial)) / BigInt(count));
          assert.equal(starter + (await withdraw(carol))[asset], keeperBudget);
          for (const user of [first, last]) {
            const refund = await withdraw(user);
            assert.equal(refund[0], discharge ? unit : (share / floor) * unit);
            assert.equal(refund[1], discharge ? floor : share - share / 20n);
          }
        } finally {
          await h.vm.stateManager.revert();
          h.time = time;
          h.height = height;
        }
      }
    }
  });

  test('Markets refund early cancellations even when first claimed after the deadline', async () => {
    const p = await proposal('Early cancellation');
    await h.send(governor, alice, 'stake', [p.id, true, 100n * unit]);
    await h.send(governor, bob, 'stake', [p.id, false, 100n * unit]);
    await h.reverts(governor, carol, 'cancel(address[],uint256[],bytes[],bytes32)', [
      p.targets,
      p.values,
      p.calldatas,
      p.hash,
    ]);
    await h.reverts(governor, dave, 'finalizeMarket', [p.id], 0n, 'MarketNotFinalized');
    await h.send(governor, admin, 'cancel(address[],uint256[],bytes[],bytes32)', [
      p.targets,
      p.values,
      p.calldatas,
      p.hash,
    ]);
    assert.equal((await h.read(governor, 'marketOutcome', [p.id]))[0], 3n);
    h.time += 9n * 86400n;
    const before = await balance(alice);
    await h.send(governor, alice, 'claim', [p.id]);
    assert.equal((await balance(alice)) - before, 100n * unit);
    await h.send(governor, bob, 'claim', [p.id]);
    await h.reverts(governor, alice, 'claim', [p.id], 0n, 'NoStake');
    await h.reverts(governor, admin, 'burn', [p.id], 0n, 'NoOrphanedStakes');
    await h.reverts(governor, admin, 'finalizeMarket', [123], 0n, 'GovernorNonexistentProposal');
  });

  test('Executed governance protects DIGIL custody and recovers unrelated tokens', async () => {
    const amount = 100n * unit;
    await h.send(governor, carol, 'lockCoins', [amount, 7n * 86400n]);
    // Even no-op DIGIL calls must be refused, irrespective of their selector.
    for (const [method, args] of [
      ['transfer', [alice.address, 0]],
      ['approve', [alice.address, 0]],
      ['delegate', [ethers.ZeroAddress]],
    ]) {
      const relay = governor.iface.encodeFunctionData('relay', [
        coin.address,
        0,
        coin.iface.encodeFunctionData(method, args),
      ]);
      const p = await proposal('DIGIL custody policy: ' + method, [governor.address], [relay]);
      await h.send(governor, bob, 'stake', [p.id, true, amount]);
      await finishVote(p);
      await queue(p);
      h.time = (await h.read(governor, 'proposalEta', [p.id]))[0];
      await h.reverts(governor, dave, 'execute(uint256)', [p.id], 0n, 'ProtectedToken');
      assert.equal(await balance(governor), 2n * amount);
      assert.equal((await h.read(coin, 'allowance', [governor.address, alice.address]))[0], 0n);
      const before = await balance(bob);
      await h.send(governor, bob, 'claim', [p.id]);
      assert.equal((await balance(bob)) - before, amount);
    }
    const unrelated = await h.deploy('FailingCoin', [], false, 'tests/SecurityActors.sol');
    await h.send(unrelated, admin, 'mint', [governor.address, amount]);
    await h.send(coin, admin, 'mint', [timelock.address, amount]);
    const recovery = governor.iface.encodeFunctionData('relay', [
      unrelated.address,
      0,
      unrelated.iface.encodeFunctionData('transfer', [alice.address, amount]),
    ]);
    const p = await proposal(
      'Recover the test asset and spend treasury DIGIL',
      [governor.address, coin.address],
      [recovery, coin.iface.encodeFunctionData('transfer', [alice.address, amount])]
    );
    await finishVote(p);
    await queue(p);
    h.time = (await h.read(governor, 'proposalEta', [p.id]))[0];
    const before = await balance(alice);
    await h.send(governor, dave, 'execute(uint256)', [p.id]);
    assert.equal((await balance(alice)) - before, amount);
    assert.equal((await h.read(unrelated, 'balanceOf', [alice.address]))[0], amount);
    assert.equal(await balance(governor), amount);
    const locked = await balance(carol);
    await h.send(governor, carol, 'unlockCoins');
    assert.equal((await balance(carol)) - locked, amount);
    assert.equal(await balance(governor), 0n);
  });

  test('Large winning stakes use full-precision payouts with the same floor rounding', async () => {
    const share = (1n << 144n) + 1n;
    const lost = share + 2n;
    const p = await proposal('Proportional settlement');
    for (const [user, side, amount] of [
      [alice, false, share],
      [bob, false, 2n * share],
      [carol, true, lost],
    ]) {
      await h.send(coin, admin, 'mint', [user.address, amount]);
      await h.send(governor, user, 'stake', [p.id, side, amount]);
    }
    await finishVote(p, null);
    for (const [user, amount] of [
      [bob, 2n * share],
      [alice, share],
    ]) {
      const before = await balance(user);
      await h.send(governor, user, 'claim', [p.id]);
      assert.equal((await balance(user)) - before, amount + (amount * lost) / (3n * share));
    }
    assert.equal(await balance(governor), lost - lost / 3n - (2n * lost) / 3n);
  });

  test('Late timelock cancellation cannot reopen refunds before or after winner claims', async () => {
    await h.send(governor, carol, 'lockCoins', [1000n * unit, 7n * 86400n]);
    for (const cancelFirst of [false, true]) {
      const p = await proposal(`Late cancellation ${cancelFirst}`);
      await h.send(governor, alice, 'stake', [p.id, true, 100n * unit]);
      await h.send(governor, bob, 'stake', [p.id, false, 100n * unit]);
      await finishVote(p);
      await queue(p);
      if (cancelFirst) await cancelQueued(p);
      const before = await balance(alice);
      await h.send(governor, alice, 'claim', [p.id]);
      assert.equal((await balance(alice)) - before, 200n * unit);
      if (!cancelFirst) await cancelQueued(p);
      assert.equal((await h.read(governor, 'marketOutcome', [p.id]))[0], 2n);
      await h.reverts(governor, bob, 'claim', [p.id], 0n, 'StakeLostOrNothingToClaim');
      const repeat = await h.send(governor, dave, 'finalizeMarket', [p.id]);
      assert.equal(h.events(governor, repeat, 'MarketFinalized').length, 0);
    }
    assert.equal(await balance(governor), 1000n * unit);
    await h.send(governor, carol, 'unlockCoins');
    assert.equal(await balance(governor), 0n);
  });

  test('Orphan burns remain final and do not consume lock principal', async () => {
    await h.send(governor, carol, 'lockCoins', [1000n * unit, 7n * 86400n]);
    const p = await proposal('Orphaned losers');
    await h.send(governor, bob, 'stake', [p.id, false, 100n * unit]);
    await finishVote(p);
    await queue(p);
    const before = await balance(dave);
    await h.send(governor, dave, 'burn', [p.id]);
    assert.equal((await balance(dave)) - before, unit);
    await cancelQueued(p);
    await h.reverts(governor, bob, 'claim', [p.id], 0n, 'StakeLostOrNothingToClaim');
    await h.reverts(governor, dave, 'burn', [p.id], 0n, 'NoOrphanedStakes');
    assert.equal(await balance(governor), 1000n * unit);
    await h.send(governor, carol, 'unlockCoins');
  });

  test('Vote buckets preserve quorum boundaries, ties, replay guards and invalid-ballot retries', async () => {
    const quorum = (await h.read(governor, 'quorum', [h.time - 1n]))[0];
    const voters = h.users.slice(5, 11);
    const weights = [5n, quorum - 5n, 3n, 2n, 1n, 1n];
    const choices = [0, 1, 2, 0, 1, 2]; // Two ballots in each bucket.
    const ballot = (id, support, nft) => [
      id,
      support,
      '',
      ethers.AbiCoder.defaultAbiCoder().encode(['uint256'], [nft]),
    ];
    // Transfer existing coins so the snapshot supply (and hence quorum) stays fixed.
    for (const [i, voter] of voters.entries()) {
      await h.send(coin, admin, 'transfer', [voter.address, weights[i] ** 2n]);
      await h.send(coin, voter, 'delegate', [voter.address]);
      await h.send(token, admin, 'approve', [voter.address, i + 1]);
    }
    await h.send(token, admin, 'approve', [voters[0].address, 7]);

    const below = (await proposal('One vote below quorum')).id;
    const exact = (await proposal('Exactly at quorum')).id;
    const tied = (await proposal('Tied majority with quorum')).id;
    h.time = (await h.read(governor, 'proposalSnapshot', [tied]))[0];
    const method = 'castVoteWithReasonAndParams';
    for (const invalid of [3, 255]) {
      await h.reverts(
        governor,
        voters[0],
        method,
        ballot(exact, invalid, 1),
        0n,
        'InvalidVoteType'
      );
    }
    assert.deepEqual(Array.from(await h.read(governor, 'proposalVotes', [exact])), [0n, 0n, 0n]);
    assert.equal((await h.read(governor, 'hasVoted', [exact, voters[0].address]))[0], false);

    for (const [id, count] of [
      [below, 5],
      [exact, 6],
    ]) {
      for (let i = 0; i < count; i++) {
        await h.send(governor, voters[i], method, ballot(id, choices[i], i + 1));
      }
      const totals = await h.read(governor, 'proposalVotes', [id]);
      const expected = [7n, quorum - 4n, id === below ? 3n : 4n];
      assert.deepEqual(Array.from(totals), expected);
      assert.deepEqual([totals.againstVotes, totals.forVotes, totals.abstainVotes], expected);
    }
    await h.reverts(governor, voters[0], method, ballot(exact, 1, 7), 0n, 'AlreadyCastVote');
    await h.reverts(governor, voters[1], method, ballot(exact, 1, 1), 0n, 'AlreadyUsedNft');

    // One For, one Against, and sufficient Abstain votes to reach quorum.
    for (const [i, support] of [
      [4, 1],
      [5, 0],
      [1, 2],
      [0, 2],
    ]) {
      await h.send(governor, voters[i], method, ballot(tied, support, i + 1));
    }
    h.time = (await h.read(governor, 'proposalDeadline', [tied]))[0] + 1n;
    assert.equal((await h.read(governor, 'state', [below]))[0], 3n); // Defeated
    assert.equal((await h.read(governor, 'state', [exact]))[0], 4n); // Succeeded
    assert.equal((await h.read(governor, 'state', [tied]))[0], 3n); // Defeated
  });

  test('Deadline boundary, no-quorum defeat, voting replay, and lock bounds remain enforced', async () => {
    const p = await proposal('No quorum');
    await h.send(governor, bob, 'stake', [p.id, false, unit]);
    h.time = (await h.read(governor, 'proposalDeadline', [p.id]))[0] - 1n;
    await h.reverts(governor, dave, 'finalizeMarket', [p.id], 0n, 'MarketNotFinalized');
    await h.send(governor, dave, 'finalizeMarket', [p.id]);
    assert.equal((await h.read(governor, 'marketOutcome', [p.id]))[0], 1n);
    await h.send(governor, bob, 'claim', [p.id]);
    await h.reverts(governor, carol, 'lockCoins', [1n << 208n, 7n * 86400n], 0n, 'InvalidParams');
    const p2 = await proposal('Replay');
    h.time = (await h.read(governor, 'proposalSnapshot', [p2.id]))[0];
    const params = ethers.AbiCoder.defaultAbiCoder().encode(['uint256'], [0]);
    await h.send(governor, admin, 'castVoteWithReasonAndParams', [p2.id, 1, '', params]);
    await h.reverts(governor, admin, 'castVoteWithReasonAndParams', [p2.id, 1, '', params]);
  });

  let failed = 0;
  for (const { name, run } of tests) {
    h.scenario = name;
    const time = h.time,
      height = h.height;
    await h.vm.stateManager.checkpoint();
    try {
      await run();
      console.log(`PASS ${name}`);
    } catch (error) {
      failed++;
      console.error(`FAIL ${name}\n${error.stack}`);
    } finally {
      await h.vm.stateManager.revert();
      h.time = time;
      h.height = height;
    }
  }
  console.log(`Security regressions: ${tests.length - failed} passed; ${failed} failed`);
  h.writeCoverage();
  assert.equal(failed, 0);
}
main().catch((error) => {
  console.error(error);
  process.exitCode = 1;
});
