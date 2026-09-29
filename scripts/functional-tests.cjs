const assert = require('node:assert/strict');
const { compile, sourcesIn, checkSizes } = require('./compile.cjs');
const { createHarness, bootstrap, ethers } = require('./evm.cjs');
const { scenarios } = require('./functional-scenarios.js');

async function fullBootstrap(h) {
  const fixture = await bootstrap(h);
  fixture.timelock = await h.deploy('DigilTimelock', [60, [], [], h.users[0].address]);
  fixture.governor = await h.deploy('DigilGovernor', [fixture.coin.address, fixture.timelock.address, fixture.token.address]);
  for (const role of ['PROPOSER_ROLE', 'CANCELLER_ROLE', 'EXECUTOR_ROLE']) {
    await h.send(fixture.timelock, h.users[0], 'grantRole', [ethers.id(role), fixture.governor.address]);
  }
  return fixture;
}
async function main() {
  const contracts = compile({ ...sourcesIn('contracts'), ...sourcesIn('tests', f => f === 'SecurityActors.sol') });
  checkSizes(contracts);
  const h = await createHarness(contracts);
  h.id = ethers.id;
  h.encode = (types, values) => ethers.AbiCoder.defaultAbiCoder().encode(types, values);
  let passed = 0, failed = 0;
  for (const scenario of scenarios()) {
    try {
      h.scenario = null;
      const fixture = await fullBootstrap(h);
      h.scenario = scenario.id;
      await scenario.run({ h, ...fixture });
      passed++;
      console.log(`PASS ${scenario.id}`);
    } catch (error) {
      failed++;
      console.error(`FAIL ${scenario.id}:`, error);
    }
  }
  console.log(`Portable functional scenarios: ${passed} passed; ${failed} failed`);
  h.writeCoverage();
  assert.equal(failed, 0);
}
module.exports = { fullBootstrap };
if (require.main === module) main().catch(error => { console.error(error); process.exitCode = 1; });
