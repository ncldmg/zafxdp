# Run all tests (caller must use sudo for e2e and traffic tests)
test-all:
	zig build test-all --summary failures

# Individual test targets
test-unit:
	zig build test --summary failures

test-packet:
	zig build test-packet --summary failures

test-protocol:
	zig build test-protocol --summary failures

test-e2e:
	zig build test-e2e --summary failures

test-traffic:
	zig build test-traffic --summary failures

# Alias for backwards compatibility
test: test-unit

# Run the CLI
run:
	zig build run

# Build everything
build:
	zig build

# Clean build artifacts
clean:
	rm -rf zig-cache zig-out .zig-cache

# Help
help:
	@echo "Available targets:"
	@echo "  sudo make test-all      - Run all tests (requires root)"
	@echo "  make test-unit          - Run unit tests only"
	@echo "  make test-packet        - Run packet parsing tests"
	@echo "  make test-protocol      - Run protocol tests"
	@echo "  sudo make test-e2e      - Run end-to-end tests (requires root)"
	@echo "  sudo make test-traffic  - Run traffic tests (requires root)"
	@echo "  make build              - Build the library and CLI"
	@echo "  make run                - Run the CLI"
	@echo "  make clean              - Clean build artifacts"

.PHONY: test-all test-unit test-packet test-protocol test-e2e test-traffic test run build clean help
