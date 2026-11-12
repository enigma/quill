.PHONY: install-app
install-app:
	/bin/bash scripts/install-app.sh

.PHONY: test-capture
test-capture:
	/bin/bash scripts/test-capture.sh

.PHONY: build-app test-installer
build-app:
	/bin/bash scripts/build-app.sh

test-installer:
	python3 -m unittest discover -s Tests -p 'test_*.py'

.PHONY: test-separation
test-separation:
	/bin/bash scripts/test-separation.sh
