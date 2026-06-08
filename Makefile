.PHONY: clean
clean:
	forge clean && rm -rf cache

.PHONY: compile
compile:
	forge build

.PHONY: test
test:
	forge test

.PHONY: create-genesis
create-genesis:
	go run ./create-genesis.go

.PHONY: all
all: clean compile create-genesis
