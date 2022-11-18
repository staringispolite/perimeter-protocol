# perimeter-core

This repository contains the contracts for the Perimeter protocol.

## Getting started

```sh
npm install
```

## Running a node

```sh
npx hardhat node
npx hardhat run scripts/deploy.ts
```

## Testing

```sh
npm test

# or

npx hardhat test
```

### Gas usage reports

```sh
npm run test:gas

# or

REPORT_GAS=true npx hardhat test
```

### Code Coverage

```sh
npm run test:coverage

# or

npx hardhat coverage
```

### Hardhat Tasks

There are several hardhat tasks to allow for easy modification of the contracts.

Updating the ServiceConfiguration:

- setPaused
- setLiquidityAsset
- setLoanFactory
- setTosAcceptanceRegistry

You can find complete instructions for how to run each command by running the following:

```sh
npx hardhat setPaused --help
```

Here is an example command to pause a hypothetical contract:

```sh
 npx hardhat setPaused --address 0x5FbDB2315678afecb367f032d93F642f64180aa3 --paused true
```
