# Run all tests (caller must use sudo for e2e and traffic tests)
test-all:
	zig build test-all --summary all

# Individual test targets
test-unit:
	zig build test --summary all

test-packet:
	zig build test-packet --summary all

test-protocol:
	zig build test-protocol --summary all

test-e2e:
	zig build test-e2e --summary all

test-traffic:
	zig build test-traffic --summary all

test-cmd:
	zig build test-cmd --summary all

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

# Fix cache permissions (use after running tests with sudo)
fix-cache:
	@if [ -d .zig-cache ]; then \
		sudo chown -R $(USER):$(USER) .zig-cache zig-cache 2>/dev/null || true; \
	fi

# Help
help:
	@echo "Available targets:"
	@echo "  sudo make test-all      - Run all tests (requires root)"
	@echo "  make test-unit          - Run unit tests only"
	@echo "  make test-packet        - Run packet parsing tests"
	@echo "  make test-protocol      - Run protocol tests"
	@echo "  make test-cmd           - Run command tests"
	@echo "  sudo make test-e2e      - Run end-to-end tests (requires root)"
	@echo "  sudo make test-traffic  - Run traffic tests (requires root)"
	@echo "  make build              - Build the library and CLI"
	@echo "  make run                - Run the CLI"
	@echo "  make clean              - Clean build artifacts"
	@echo "  make fix-cache          - Fix cache permissions after sudo runs"
	@echo ""
	@echo "Note: All targets can also be run directly with zig build:"
	@echo "  zig build test-all --summary all"
	@echo "  zig build --help        - Show all available build steps"

.PHONY: test-all test-unit test-packet test-protocol test-cmd test-e2e test-traffic test run build clean fix-cache help
