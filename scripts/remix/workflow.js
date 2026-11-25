/**
 * Shared dispatcher for the six Remix Run Script entry points. Each mode first
 * validates a fresh compilation. Portable test logic belongs in scenarios, while
 * provider-specific operations and deployment recovery belong in runtime.js.
 * only filters smoke scenarios by exact ID; [] runs the complete smoke registry.
 */
async function run(mode, { ethers, remix, log = console.log, only = [] }) {
  const load = async (path) => {
    const module = { exports: {} };
    // Only execute explicitly named, checked-in workspace modules.
    new Function('module', await remix.call('fileManager', 'readFile', path))(module);
    return module.exports;
  };
  const { createRuntime, invariant } = await load('scripts/remix/runtime.js');
  const runtime = await createRuntime({
    ethers,
    call: (...args) => remix.call(...args),
    on: (...args) => remix.on(...args),
    off: (...args) => remix.off(...args),
    log,
  });
  await runtime.compile();
  if (mode === 'preflight') {
    await runtime.capabilities();
    log(
      'PASS deployment preflight. Timing-dependent coverage is provided by npm test, not by this VM smoke suite.'
    );
  } else if (mode === 'deploy') {
    await runtime.deployRecorded();
    log('PASS deployment. Record: .remix/deployment.json. Bootstrap admin control is retained.');
  } else if (mode === 'verify') {
    await runtime.verifyRecorded();
    log('PASS current deployment verified against current sources.');
  } else if (mode === 'test') {
    const { scenarios } = await load('scripts/functional-scenarios.js');
    const selected = scenarios().filter((scenario) => !only.length || only.includes(scenario.id));
    invariant(
      selected.length && only.every((id) => selected.some((scenario) => scenario.id === id)),
      'Unknown or empty smoke scenario selection'
    );
    const results = [];
    for (const scenario of selected) {
      log(`RUN ${scenario.id} (fresh fixture)`);
      try {
        const fixture = await runtime.bootstrap();
        await scenario.run({ h: runtime.h, ...fixture });
        results.push({ id: scenario.id, passed: true });
        log(`PASS ${scenario.id}`);
      } catch (error) {
        results.push({ id: scenario.id, passed: false, error: String(error.message || error) });
        log(`FAIL ${scenario.id}: ${error.message || error}`);
      }
    }
    await runtime.writeFile('.remix/smoke-results.json', {
      scope: 'Remix VM smoke subset only',
      results,
      omitted: [
        'Node security regressions',
        'Solidity legacy suites',
        'time boundaries',
        'typed signatures',
        'full governance handoff',
        'adversarial actors',
      ],
    });
    const failed = results.filter((result) => !result.passed).length;
    log(
      `Remix smoke subset: ${results.length - failed} passed, ${failed} failed. Full protocol validation still requires npm test.`
    );
    invariant(failed === 0, `${failed} smoke scenarios failed`);
  } else if (mode === 'seed-demo') {
    const { coin, token } = await runtime.verifyRecorded('demo-');
    const { h } = runtime;
    const record = await runtime.loadRecord();
    const unit = 10n ** 18n;
    for (const user of h.users.slice(1, 3)) {
      await h.send(
        coin,
        h.users[0],
        'mint',
        [user.address, 20000n * unit],
        0n,
        record,
        `demo-mint-${user.address}`
      );
      await h.send(
        coin,
        user,
        'delegate',
        [user.address],
        0n,
        record,
        `demo-delegate-${user.address}`
      );
      await h.send(
        coin,
        user,
        'approve',
        [token.address, (1n << 256n) - 1n],
        0n,
        record,
        `demo-approve-${user.address}`
      );
      await h.send(
        token,
        user,
        'createToken',
        [0, 0, false, 0, '0x'],
        100000000000000n,
        record,
        `demo-nft-${user.address}`
      );
    }
    log(
      'PASS demo balances, delegation, allowances, and NFTs. Re-running does not mint duplicate demo balances.'
    );
  } else if (mode === 'handoff') {
    const fixture = await runtime.verifyRecorded();
    log(
      JSON.stringify(
        {
          status: 'BLOCKED',
          ownerDestination: fixture.timelock.address,
          coinRoles: ['DEFAULT_ADMIN_ROLE', 'PAUSER_ROLE', 'MINTER_ROLE', 'CONFIG_ROLE'],
          retain: 'DigilToken MINTER_ROLE and spend weight 10000',
          revokeLast: 'deployer timelock DEFAULT_ADMIN_ROLE',
          reason:
            'Remix VM cannot fast-forward the required governance rehearsal. No grants, ownership transfers, or revocations were sent. Run npm test for the complete isolated handoff rehearsal.',
        },
        null,
        2
      )
    );
    throw new Error(
      'Handoff blocked: no verified real governance rehearsal on this deployment. Admin control was not changed.'
    );
  } else throw new Error(`Unknown workflow ${mode}`);
}
module.exports = { run };
