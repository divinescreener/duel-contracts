#!/usr/bin/env node
// Checks that the code deployed on Robinhood Chain is this repository's: for each contract of
// deployments/robinhood.json, the runtime code at its address against the one `forge build` made of its source, byte
// for byte. The immutables (values a contract receives at its deployment, such as the addresses it is linked to) are
// left aside in both, at the places the compiler says they are. Nothing is sent: it reads the code with eth_getCode.
//
//   forge build && node scripts/check-deployed.mjs
//
// ROBINHOOD_RPC_URL names another node than the public one.
import fs from 'node:fs'
import path from 'node:path'
import { fileURLToPath } from 'node:url'

const ROOT = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '..')
const RPC = process.env.ROBINHOOD_RPC_URL || 'https://rpc.mainnet.chain.robinhood.com'
const deployment = JSON.parse(fs.readFileSync(path.join(ROOT, 'deployments', 'robinhood.json'), 'utf8'))
/** Where each contract's source lies, for its artifact (out/<file>/<name>.json). */
const SOURCES = { DuelBootstrap: 'script/DuelBootstrap.sol' }

async function codeAt(address) {
  const response = await fetch(RPC, {
    method: 'POST',
    headers: { 'content-type': 'application/json' },
    body: JSON.stringify({ jsonrpc: '2.0', id: 1, method: 'eth_getCode', params: [address, 'latest'] }),
  })
  const { result, error } = await response.json()
  if (error) throw new Error(`${address}: ${error.message}`)
  return Buffer.from(result.slice(2), 'hex')
}

let same = true
for (const [name, address] of Object.entries(deployment.contracts)) {
  const source = SOURCES[name] ?? `src/${name}.sol`
  const artifact = JSON.parse(
    fs.readFileSync(path.join(ROOT, 'out', path.basename(source), `${name}.json`), 'utf8'),
  )
  const built = Buffer.from(artifact.deployedBytecode.object.slice(2), 'hex')
  const deployed = await codeAt(address)
  const immutables = Object.values(artifact.deployedBytecode.immutableReferences ?? {}).flat()
  for (const { start, length } of immutables) {
    built.fill(0, start, start + length)
    deployed.fill(0, Math.min(start, deployed.length), Math.min(start + length, deployed.length))
  }
  const identical = built.equals(deployed)
  same &&= identical
  console.log(
    `${name.padEnd(14)} ${address}  ${identical ? 'identical' : 'DIFFERENT'} (${built.length} bytes built, ${deployed.length} deployed, ${immutables.length} immutables aside)`,
  )
}
if (!same) {
  console.error('The deployed code differs from this build: same compiler settings? (foundry.toml)')
  process.exit(1)
}
console.log(`Robinhood Chain runs this repository's code (${Object.keys(deployment.contracts).length} contracts).`)
