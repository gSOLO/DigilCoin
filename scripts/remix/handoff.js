(async () => {
  const module = { exports: {} };
  new Function('module', await remix.call('fileManager', 'readFile', 'scripts/remix/workflow.js'))(module);
  await module.exports.run('handoff', { ethers: require('ethers'), remix });
})().catch(error => { console.error('BLOCKED handoff:', error.message || error); throw error; });
