.PHONY: test test-parsers
test:
	sh tests/run.sh
test-parsers:
	python3 tests/install_parsers.py
