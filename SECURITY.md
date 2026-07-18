# Security Policy

## Reporting

Do not publish a suspected exploit before maintainers have had a reasonable
opportunity to investigate. Include the affected contract, invariant, call
sequence, preconditions and a minimal reproduction when possible.

## Contract identity

- Treat any production source or compiler-setting change as a new contract
  family requiring a new identity, full tests, review and deployment.
- Never reuse the deployed compatibility identity for changed bytecode.
- Verify contract addresses, chain ID, bytecode and immutable wiring before
  signing a transaction.

## Operational safety

- Never commit deployment keys, mnemonics or populated environment files.
- Use separate deployment roles unless you have explicitly reviewed the
  shared-role option.
- Pin every factory dependency before renouncing ownership.
- Test factory deployment and a complete launch lifecycle on a test network
  before deploying a new suite to mainnet.

## Audit status

The repository includes extensive scenario testing and public test-network
evidence. It has not received a formal professional third-party audit. Users
must assess the contracts and external dependencies for themselves.
