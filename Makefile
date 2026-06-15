.PHONY: setup test lint clean benchmark install

setup:
	mkdir -p src tests benchmarks docs

test:
	@echo "Running tests..."
	if command -v bats >/dev/null 2>&1; then \
		bats tests/; \
	else \
		echo "Error: bats is not installed. Install from https://github.com/bats-core/bats-core" >&2; \
		exit 1; \
	fi

lint:
	@echo "Running shellcheck..."
	if command -v shellcheck >/dev/null 2>&1; then \
		shellcheck -x src/*.sh tests/*.bats benchmarks/*.sh; \
	else \
		echo "Error: shellcheck is not installed. Install: apt-get install shellcheck" >&2; \
		exit 1; \
	fi

clean:
	@echo "Cleaning artifacts..."
	rm -f db db.tmp *.tmp db.lock db.wal
	rm -f benchmarks/db.bench benchmarks/db.bench.*
	@echo "Done."

benchmark:
	@echo "Running benchmarks..."
	if [ -f benchmarks/run.sh ]; then \
		bash benchmarks/run.sh; \
	else \
		echo "No benchmarks found. Create benchmarks/run.sh" >&2; \
	fi

install:
	@echo "Installing to /usr/local/bin..."
	install -m 755 src/*.sh /usr/local/bin/
	@echo "Done."
