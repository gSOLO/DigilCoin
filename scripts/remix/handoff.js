// Remix Run Script: preview governance handoff, then deliberately report BLOCKED.
// Sends no grants/transfers/revocations; never bypass the missing-rehearsal guard.
(async () => {
  const module = { exports: {} };
  new Function('module', await remix.call('fileManager', 'readFile', 'scripts/remix/workflow.js'))(
    module
  );
  await module.exports.run('handoff', { ethers: require('ethers'), remix });
})().catch((error) => {
  console.error('BLOCKED handoff:', error.message || error);
  throw error;
});
