.PHONY: test test-unit test-integration test-parsers
test:
	sh tests/run.sh
test-unit:
	sh tests/run.sh unit
test-integration:
	sh tests/run.sh integration
test-parsers:
	python3 tests/install_parsers.py
