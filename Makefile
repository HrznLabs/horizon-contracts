.PHONY: all test clean install build verify fmt deploy

# Includes
-include .env

# Foundry commands
all: clean install build

# Clean the repo
clean:
	forge clean

# Install dependencies
install:
	forge install

# Build the project
build:
	forge build

# Run tests
test:
	forge test

# Run tests with verbosity
test-v:
	forge test -vvv

# Run gas report
gas:
	forge test --gas-report

# Format code
fmt:
	forge fmt

# Deploy to Base Sepolia
deploy-sepolia:
	forge script script/Deploy.s.sol --rpc-url base_sepolia --broadcast --verify

# Verify contract
verify:
	forge verify-check $(ADDRESS) --chain-id 84532

# Help
help:
	@echo "Available targets:"
	@echo "  make all            - Clean, install, and build"
	@echo "  make clean          - Clean the repo"
	@echo "  make install        - Install dependencies"
	@echo "  make build          - Build the project"
	@echo "  make test           - Run tests"
	@echo "  make test-v         - Run tests with verbosity"
	@echo "  make gas            - Run gas report"
	@echo "  make fmt            - Format code"
	@echo "  make deploy-sepolia - Deploy to Base Sepolia"
	@echo "  make verify         - Verify contract (usage: make verify ADDRESS=0x...)"
