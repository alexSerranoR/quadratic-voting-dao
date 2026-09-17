# Quadratic Voting DAO

A decentralized governance system implementing **quadratic voting for DAOs**, built with Solidity and ERC-20 voting tokens.

The project allows participants to acquire voting tokens, create funding or signaling proposals, vote using a quadratic cost model, and execute approved proposals through external smart contracts.

## Overview

Traditional voting systems often allow participants with more resources to accumulate disproportionate influence.

This project implements **quadratic voting**, where the cost of voting increases quadratically with the number of votes assigned to a proposal:

| Votes | Token Cost |
|------:|-----------:|
| 1 | 1 |
| 2 | 4 |
| 3 | 9 |
| 4 | 16 |
| 5 | 25 |

The general voting cost is:

```text
cost = votes²
```

When additional votes are added, only the difference between the previous and new quadratic cost is charged.

This makes expressing stronger preferences possible while making vote concentration increasingly expensive.

---

## Features

- Participant registration and removal
- ERC-20 voting token (`QVT`)
- Token purchasing and selling using Ether
- Quadratic voting mechanism
- Funding proposals
- Signaling proposals
- Automatic execution of approved funding proposals
- Vote withdrawal
- Pull-based token refunds
- Multiple voting rounds
- External proposal execution
- ERC-165 interface validation
- Gas-limited external calls
- Reentrancy protection
- Explicit proposal and voting states

---

## Architecture

The system is composed of four Solidity contracts:

```text
QuadraticVoting
│
├── VotingToken
│
└── IExecutableProposal
        ▲
        │
TestExecutableProposal
```

### `QuadraticVoting.sol`

The main governance contract.

It manages:

- participants
- voting rounds
- token purchases and sales
- proposal creation
- quadratic voting
- proposal approval
- funding execution
- signaling execution
- vote withdrawal
- token refunds

### `VotingToken.sol`

ERC-20 token used as the voting asset.

The token:

- uses the symbol `QVT`
- has no decimal units (`decimals = 0`)
- has a maximum supply
- can only be minted by `QuadraticVoting`
- can only be burned by `QuadraticVoting`

Participants purchase tokens using Ether and authorize the governance contract through the ERC-20 `approve` / `transferFrom` mechanism before voting.

### `IExecutableProposal.sol`

Interface that every executable proposal contract must implement.

External proposal contracts expose:

```solidity
executeProposal(
    uint proposalId,
    uint numVotes,
    uint numTokens
)
```

The interface extends ERC-165 so that `QuadraticVoting` can verify whether an external contract supports the required proposal interface.

### `TestExecutableProposal.sol`

A simple implementation of `IExecutableProposal` used to test external proposal execution.

It records proposal execution through events and can receive Ether when a funding proposal is executed.

---

## Proposal Types

The governance system supports two different proposal types.

### Funding Proposals

Funding proposals request Ether from the current voting-round budget.

A funding proposal can be automatically approved when:

- it reaches the required voting threshold
- sufficient budget is available

Once approved, the contract:

1. updates the proposal state
2. updates the available budget
3. consumes the voting tokens
4. executes the external proposal contract
5. transfers the requested Ether

### Signaling Proposals

Signaling proposals have a budget of `0`.

They are used to represent governance preferences without requesting funds.

Unlike funding proposals, signaling proposals are not automatically executed while voting is open. They can be executed after the voting round has been closed.

---

## Quadratic Voting

For a participant with `v` votes:

```text
token cost = v²
```

When adding votes, the contract calculates only the additional cost:

```text
additional cost = newVotes² - previousVotes²
```

For example, moving from 2 votes to 3 votes costs:

```text
3² - 2² = 9 - 4 = 5 tokens
```

The same principle is used when withdrawing votes to calculate the number of tokens that must be returned.

---

## Proposal Approval Threshold

Funding proposals use a dynamic approval threshold based on:

- requested proposal budget
- total available budget
- number of participants
- number of pending funding proposals

The implemented threshold is based on:

```text
(0.2 + proposalBudget / totalBudget)
× numberOfParticipants
+ pendingFundingProposals
```

Funding proposals are executed automatically when their vote count exceeds this threshold and enough budget is available.

---

## Pull-over-Push Design

A key design decision of the project is the use of a **pull-over-push pattern**.

Instead of processing every voter and proposal when a voting round closes, the contract allows pending actions to be executed individually.

### Token refunds

Participants recover locked tokens using:

```solidity
claimRefund()
```

Refunds can be claimed when appropriate for:

- cancelled proposals
- funding proposals that were not approved
- signaling proposals after the voting round closes

### Signaling execution

Signaling proposals are executed individually after the voting round closes using:

```solidity
executeSignalingProposal()
```

This avoids iterating over an unbounded number of voters or proposals inside `closeVoting()`, reducing gas usage and the risk of denial-of-service conditions.

---

## Security

The project includes several mechanisms designed to reduce common smart-contract risks.

### Reentrancy Protection

Sensitive functions use a `nonReentrant` modifier to prevent recursive execution.

The contract also follows the **Checks-Effects-Interactions** pattern by updating internal state before performing external calls.

### ERC-165 Validation

External proposal contracts must implement `IExecutableProposal`.

The governance contract verifies support for the interface through ERC-165 before accepting a proposal.

### Gas-Limited External Execution

External proposal execution is limited to:

```solidity
100000 gas
```

This reduces the ability of external proposal contracts to consume excessive transaction gas.

### ERC-20 Authorization

Voting tokens cannot be moved directly from participants.

Users must first authorize `QuadraticVoting` through:

```solidity
approve()
```

The governance contract then uses:

```solidity
transferFrom()
```

to lock the required voting tokens.

### Restricted Token Supply

Only the `QuadraticVoting` contract can mint or burn `QVT` tokens.

---

## Main Workflow

A typical voting round follows this process:

```text
Deploy QuadraticVoting
        ↓
VotingToken is created
        ↓
Participants register
        ↓
Participants acquire QVT
        ↓
Owner opens voting round
        ↓
Participants create proposals
        ↓
Users approve QVT spending
        ↓
Users stake votes
        ↓
Funding proposals may be automatically approved
        ↓
Owner closes voting round
        ↓
Users claim eligible refunds
        ↓
Signaling proposals can be executed
```

---

## Testing

The contracts were manually tested using the **Remix VM** with different accounts representing the owner, participants, and external proposal contracts.

The tested scenarios include:

- deployment of the governance contract
- automatic deployment of the voting token
- participant registration
- token purchases
- token sales
- participant removal
- opening voting rounds
- creating valid proposals
- rejecting invalid proposal contracts
- attempting to vote without ERC-20 approval
- quadratic voting
- automatic funding proposal approval
- vote withdrawal
- proposal cancellation
- token refunds
- signaling proposals
- closing voting rounds
- signaling proposal execution
- rejection of invalid refunds

A complete description of the tests and their results is available in:

[`docs/project-report.pdf`](docs/project-report.pdf)

---

## Technologies

- Solidity `^0.8.20`
- Ethereum smart contracts
- OpenZeppelin Contracts
- ERC-20
- ERC-165
- Remix IDE

---

## Project Structure

```text
quadratic-voting-dao/
│
├── contracts/
│   ├── QuadraticVoting.sol
│   ├── VotingToken.sol
│   ├── IExecutableProposal.sol
│   └── TestExecutableProposal.sol
│
├── docs/
│   └── project-report.pdf
│
├── README.md
├── .gitignore
└── LICENSE
```

---

## Documentation

The full project report contains:

- system architecture
- design decisions
- complete voting workflow
- Remix testing
- negative test cases
- pull-over-push implementation
- smart-contract security analysis

See:

[`docs/project-report.pdf`](docs/project-report.pdf)

---

## Future Improvements

Possible improvements to the project include:

- automated tests with Foundry or Hardhat
- deployment scripts
- gas usage benchmarks
- testnet deployment
- CI/CD with GitHub Actions
- frontend integration
- formal smart-contract security analysis

---

## Author

**Alejandro Serrano Ruibal**

Software Engineering & Business and Technology student interested in software development, blockchain and decentralized systems.

---

## License

This project is licensed under the GNU General Public License v3.0.
