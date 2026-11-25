/** Shared discovery, lifecycle-hook and assertion decoding for the Solidity runner. */
const assert = require('node:assert/strict');
const HOOKS = new Set(['beforeAll', 'beforeEach', 'afterEach', 'afterAll']);

/** Select source-ordered test methods and read their #sender/#value annotations. */
function discover(source, abi) {
  const functions = new Map(
    abi.filter((item) => item.type === 'function').map((item) => [item.name, item])
  );
  const methods = [];
  // Preserve this repository's source-ordered scenarios. The compiled ABI, not
  // source spelling, determines whether a discovered method is callable.
  for (const match of source.matchAll(/^\s*function\s+(\w+)\s*\(/gm)) {
    const name = match[1];
    if (!HOOKS.has(name) && !name.startsWith('test')) continue;
    const entry = functions.get(name);
    assert.ok(entry, `Test method ${name} must be public/external`);
    assert.equal(entry.inputs.length, 0, `Test method ${name} must not require arguments`);
    const lines = source.slice(0, match.index).trimEnd().split('\n');
    const comments = [];
    for (let i = lines.length - 1; i >= 0; i--) {
      const line = lines[i].trim();
      if (!line || line.startsWith('//')) comments.unshift(line);
      else break;
    }
    const annotation = comments.join('\n');
    const sender = Number(annotation.match(/#sender:\s*account-(\d+)/)?.[1] || 0);
    assert.ok(sender >= 0 && sender < 10, `Unsupported sender for ${name}`);
    methods.push({
      name,
      sender,
      value: BigInt(annotation.match(/#value:\s*(\d+)/)?.[1] || 0),
      hook: HOOKS.has(name),
      setup: HOOKS.has(name) || /^test(?:Prepare|ChargeBatch)/.test(name),
      returnsBool: entry.outputs?.length === 1 && entry.outputs[0].type === 'bool',
    });
  }
  return methods;
}

/** execute(method) must return false on failure; failed setup skips dependent tests. */
async function executeSuite(methods, execute) {
  const hook = (name) => methods.find((method) => method.name === name);
  const callHook = async (name) => !hook(name) || (await execute(hook(name)));
  if (await callHook('beforeAll')) {
    for (const method of methods.filter((method) => !method.hook)) {
      if (await callHook('beforeEach')) await execute(method);
      await callHook('afterEach');
    }
  }
  await callHook('afterAll');
}

/** Collect EVM failures, failed Remix Assert events and false boolean test returns. */
function assertionErrors(result, definition, iface, assertions, bytesToHex) {
  const errors = [];
  if (result.execResult.exceptionError)
    errors.push(
      `${result.execResult.exceptionError.error}: ${bytesToHex(result.execResult.returnValue)}`
    );
  for (const log of result.execResult.logs || []) {
    try {
      const event = assertions.parseLog({
        topics: log[1].map(bytesToHex),
        data: bytesToHex(log[2]),
      });
      if (event?.args.passed === false) errors.push(event.args.message || event.name);
    } catch {
      /* Ignore unrelated protocol events. */
    }
  }
  if (
    !result.execResult.exceptionError &&
    definition.returnsBool &&
    iface.decodeFunctionResult(definition.name, bytesToHex(result.execResult.returnValue))[0] !==
      true
  )
    errors.push('Test returned false');
  return errors;
}
module.exports = { discover, executeSuite, assertionErrors };
