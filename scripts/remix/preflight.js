(async () => {
  const module = { exports: {} };
  new Function('module', await remix.call('fileManager', 'readFile', 'scripts/remix/workflow.js'))(module);
  await module.exports.run('preflight', { ethers: require('ethers'), remix });
})().catch(error => { console.error('FAIL preflight:', error.message || error); throw error; });
