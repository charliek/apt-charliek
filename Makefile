.PHONY: help check lint shellcheck shfmt docs docs-serve fixture publish-fixture \
        verify-local verify-public clean

help:
	@echo "Targets:"
	@echo "  check             lint + docs --strict + fixture publish + verify-local (CI parity)"
	@echo "  lint              shellcheck + shfmt --diff"
	@echo "  shellcheck        shellcheck on scripts/, infra/, fixtures/"
	@echo "  shfmt             shfmt --diff on the same"
	@echo "  docs              uv run mkdocs build --strict"
	@echo "  docs-serve        uv run mkdocs serve at http://127.0.0.1:7070"
	@echo "  fixture           build fixtures/hello_0.0.1_amd64.deb via nfpm"
	@echo "  publish-fixture   stage fixture into pool/ and run publish.sh in FIXTURE_MODE"
	@echo "  verify-local      smoke-test the fixture publish output via debian:noble docker"
	@echo "  verify-public     smoke-test https://apt.stridelabs.ai end-to-end"
	@echo "  clean             remove pool/, dists/, .tmp/, site-build/, pubkey.{gpg,asc}"

check: lint docs publish-fixture verify-local

lint: shellcheck shfmt

shellcheck:
	shellcheck scripts/*.sh infra/*.sh fixtures/*.sh

shfmt:
	shfmt --diff scripts/ infra/ fixtures/

docs:
	uv sync --group docs
	uv run mkdocs build --strict

docs-serve:
	uv sync --group docs
	uv run mkdocs serve

fixture:
	./fixtures/build-fixture.sh

publish-fixture:
	@mkdir -p pool/main/h/hello
	@cp fixtures/hello_0.0.1_amd64.deb pool/main/h/hello/
	FIXTURE_MODE=1 ./scripts/publish.sh

verify-local:
	./scripts/verify.sh --local --pkg hello

verify-public:
	./scripts/verify.sh --url https://apt.stridelabs.ai

clean:
	rm -rf pool/ dists/ .tmp/ site-build/ .cache/ pubkey.gpg pubkey.asc
