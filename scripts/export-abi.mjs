#!/usr/bin/env node
import { mkdirSync } from "node:fs";
import path from "node:path";
import { artifact, root, writeJson } from "./lib.mjs";

const outDir = path.resolve(root, "abi");
mkdirSync(outDir, { recursive: true });

const entries = [
  ["D17Factory.sol", "D17Factory"],
  ["D17TokenFactory.sol", "D17TokenFactory"],
  ["D17LaunchFactory.sol", "D17LaunchFactory"],
  ["D17LiquidityVaultFactory.sol", "D17LiquidityVaultFactory"],
  ["D17LockerFactory.sol", "D17LockerFactory"],
  ["D17Launch.sol", "D17Launch"],
  ["D17LiquidityVault.sol", "D17LiquidityVault"],
  ["D17Locker.sol", "D17Locker"],
  ["D17Token.sol", "D17Token"]
];

for (const [file, name] of entries) {
  const art = artifact(file, name);
  writeJson(path.join(outDir, `${name}.abi.json`), art.abi);
  writeJson(path.join(outDir, `${name}.artifact.json`), {
    contractName: name,
    abi: art.abi,
    bytecode: art.bytecode
  });
}

console.log(`Exported ABI and artifact files to ${outDir}`);
