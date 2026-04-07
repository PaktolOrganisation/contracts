import "@nomicfoundation/hardhat-toolbox";
import { subtask } from "hardhat/config.js";
import { TASK_COMPILE_SOLIDITY_GET_SOURCE_PATHS } from "hardhat/builtin-tasks/task-names.js";
import path from "path";
import { glob } from "glob";

// src/ + test/mocks/ — exclude Foundry test files and node_modules
subtask(TASK_COMPILE_SOLIDITY_GET_SOURCE_PATHS, async (_, hre, runSuper) => {
  const paths = await runSuper(); // picks up src/
  const mocks = await glob(
    path.join(hre.config.paths.root, "test", "mocks", "**", "*.sol")
  );
  return [...new Set([...paths, ...mocks])].filter(
    p => !p.includes("node_modules") && !p.includes(".t.sol")
  );
});

/** @type import('hardhat/config').HardhatUserConfig */
export default {
  solidity: {
    version: "0.8.24",
    settings: {
      optimizer: { enabled: true, runs: 200 },
      viaIR: true,
      evmVersion: "cancun",
    },
  },
  paths: {
    sources: "./src",
    tests: "./test",
    cache: "./cache-hardhat",
    artifacts: "./artifacts",
  },
};
