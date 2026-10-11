.PHONY: setup moto stop test demo demos clean

setup:            ## create .venv with the AWS emulator
	python3 -m venv .venv
	.venv/bin/pip install --quiet 'moto[server]==5.2.3'

moto:             ## start the emulator on :5000
	./scripts/moto.sh start

stop:
	./scripts/moto.sh stop

test:             ## unit tests for the guard (no Terraform needed)
	python3 -m unittest discover tests

demo:             ## run one demo PR: make demo N=01
	./scripts/demo.sh $(N)

demos:            ## run every demo and check each gets its expected verdict
	./scripts/demo.sh all

clean:
	rm -rf .pr-out
