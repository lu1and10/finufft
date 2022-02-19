python -m pip install --no-index --find-links=./wheelhouse/ finufft
if (-not $?) {throw "Failed to pip install finufft"}
python python/test/run_accuracy_tests.py
if (-not $?) {throw "Tests failed"}
