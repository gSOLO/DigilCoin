// Remix Run Script: seed accounts 1/2 after deploy.js for interactive experiments.
// Mint/delegate/approve/create steps are journaled so reruns do not duplicate them.
(async () => {
  const module = { exports: {} };
  new Function('module', await remix.call('fileManager', 'readFile', 'scripts/remix/workflow.js'))(
    module
  );
  await module.exports.run('seed-demo', { ethers: require('ethers'), remix });
})().catch((error) => {
  console.error('FAIL demo setup:', error.message || error);
  throw error;
});
