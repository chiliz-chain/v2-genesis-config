.PHONY: clean
clean:
	forge clean

.PHONY: install
install:
	yarn

.PHONY: compile
compile:
	forge build

.PHONY: test
test:
	yarn coverage

.PHONY: create-genesis
create-genesis:
	go run ./create-genesis.go

.PHONY: all
all: clean compile create-genesis
