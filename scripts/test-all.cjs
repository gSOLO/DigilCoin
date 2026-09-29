const fs = require('node:fs');
const path = require('node:path');
const { spawnSync } = require('node:child_process');
const { compile, root } = require('./compile.cjs');
const { Interface } = require('ethers');

const run = `${Date.now()}-${process.pid}`;
const suites = ['security-tests.cjs', 'remix-tests.cjs', 'functional-tests.cjs', 'extended-tests.cjs', 'remix-runtime-tests.cjs'];
let failed = false;
for (const suite of suites) {
  const result = spawnSync(process.execPath, [path.join(__dirname, suite)], {
    cwd: root, stdio: 'inherit', env: { ...process.env, DIGIL_COVERAGE_RUN: run },
  });
  if (result.status !== 0 || result.error) { failed = true; console.error(`FAILED suite ${suite}`, result.error || result.status); }
}

// This is an exercised-entrypoint inventory, not statement/branch coverage or
// proof that every possible behavior of an exercised function was asserted.
const calls = {};
for (const suite of suites.filter(suite => suite !== 'remix-runtime-tests.cjs')) {
  try {
    const data = JSON.parse(fs.readFileSync(path.join(root, '.remix/coverage', suite + '.json'), 'utf8'));
    if (data.run !== run) throw new Error('stale coverage data');
    for (const [key, scenarios] of Object.entries(data.calls)) calls[key] = [...new Set([...(calls[key] || []), ...scenarios])];
  } catch (error) { failed = true; console.error(`Missing current coverage for ${suite}: ${error.message}`); }
}
const contracts = compile();
const unexercised = [];
for (const name of ['DigilCoin', 'DigilToken', 'DigilGovernor', 'DigilTimelock']) {
  const iface = new Interface(contracts[`contracts/${name}.sol`][name].abi);
  const signatures = iface.fragments.filter(fragment => fragment.type === 'function').map(fragment => `${name}.${fragment.format('sighash')}`);
  const missing = signatures.filter(signature => !calls[signature]);
  unexercised.push(...missing);
  console.log(`${name}: ${signatures.length - missing.length}/${signatures.length} ABI entrypoints exercised by behavioral scenarios`);
  for (const signature of missing) console.log(`  NOT EXERCISED: ${signature}`);
}
fs.mkdirSync(path.join(root, '.remix/coverage'), { recursive: true });
fs.writeFileSync(path.join(root, '.remix/coverage/inventory.json'), JSON.stringify({ run, suitesPassed: !failed, calls, unexercised,
  limitation: 'Execution inventory only, including negative calls; not exhaustive behavior or branch coverage.' }, null, 2));
console.log('Coverage gaps are listed explicitly; passing tests are not a claim of exhaustive coverage.');
if (failed) process.exitCode = 1;
