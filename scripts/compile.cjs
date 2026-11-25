/**
 * Node compiler adapter. Reads remix.config.json without changing its settings.
 * Used by every Node runner; direct execution runs the production size gate.
 * Command: npm run check:size
 */
const fs = require('node:fs');
const path = require('node:path');
const assert = require('node:assert/strict');
const solc = require('solc');
const pinnedVersion = require('../package.json').devDependencies.solc;

const root = path.resolve(__dirname, '..');
function sourcesIn(directory, predicate = (file) => file.endsWith('.sol')) {
  return Object.fromEntries(
    fs
      .readdirSync(path.join(root, directory))
      .filter(predicate)
      .map((file) => [
        `${directory}/${file}`,
        {
          content: fs.readFileSync(path.join(root, directory, file), 'utf8'),
        },
      ])
  );
}

/** Compile a source-name -> { content } map; return Solidity's contract artifacts. */
function compile(sources = sourcesIn('contracts')) {
  assert.ok(solc.version().startsWith(`${pinnedVersion}+`), `Expected Solidity ${pinnedVersion}`);
  const config = JSON.parse(fs.readFileSync(path.join(root, 'remix.config.json'), 'utf8'));
  // Use the repository profile unchanged, including optimizer details and output selection.
  const output = JSON.parse(
    solc.compile(
      JSON.stringify({
        language: config['solidity-compiler'].language,
        sources,
        settings: config['solidity-compiler'].settings,
      }),
      {
        import(name) {
          const candidates = [path.join(root, name), path.join(root, 'node_modules', name)];
          if (name === 'remix_tests.sol' || name === 'remix_accounts.sol') {
            candidates.push(path.join(root, 'tests', name));
          }
          if (name.startsWith('hardhat/')) candidates.push(path.join(root, '.deps/npm', name));
          if (name.startsWith('@openzeppelin/contracts/')) {
            candidates.push(
              path.join(root, '.deps/npm/@openzeppelin/contracts@5.6.1', name.slice(24))
            );
          }
          const file = candidates.find((candidate) => fs.existsSync(candidate));
          return file
            ? { contents: fs.readFileSync(file, 'utf8') }
            : { error: `Missing import: ${name}` };
        },
      }
    )
  );
  const errors = (output.errors || []).filter((error) => error.severity === 'error');
  assert.equal(errors.length, 0, errors.map((error) => error.formattedMessage).join('\n'));
  return output.contracts;
}

/** Check artifact sizes; deployment runners also account for constructor arguments. */
function checkSizes(contracts) {
  let valid = true;
  for (const name of ['DigilCoin', 'DigilToken', 'DigilGovernor', 'DigilTimelock']) {
    const artifact = contracts[`contracts/${name}.sol`][name];
    const runtime = artifact.evm.deployedBytecode.object.length / 2;
    const init = artifact.evm.bytecode.object.length / 2;
    console.log(`${name}: runtime ${runtime}/24576 bytes; creation ${init}/49152 bytes`);
    valid = valid && runtime <= 24576 && init <= 49152;
  }
  assert.ok(
    valid,
    'Production contracts must fit deployment limits with the unchanged compiler profile'
  );
}

module.exports = { root, sourcesIn, compile, checkSizes };
if (require.main === module) checkSizes(compile());
