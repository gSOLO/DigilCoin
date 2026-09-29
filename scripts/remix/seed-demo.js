(async () => {
  const module = { exports: {} };
  new Function('module', await remix.call('fileManager', 'readFile', 'scripts/remix/workflow.js'))(module);
  await module.exports.run('seed-demo', { ethers: require('ethers'), remix });
})().catch(error => { console.error('FAIL demo setup:', error.message || error); throw error; });
