# fixtures

`chain.json` is a copy of `contracts/fixtures/chain.json` of pouw-docs.
node-1 mounts this folder and, with `POUW_API_FIXTURES=/fixtures`, answers its API
from it (pouw-node#59). Copy a new version here when the fixtures change. Remove
the variable and the mount when the node serves its own chain.
