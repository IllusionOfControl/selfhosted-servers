.PHONY: install-boxes install-box-amd64-virtualbox install-box-i386-virtualbox

all: install-boxes

install-boxes: install-box-amd64-virtualbox install-box-i386-virtualbox

install-box-amd64-virtualbox: raccoon-amd64-virtualbox.box
	vagrant box add -f --name capricorn/raccoon-x64 --provider virtualbox raccoon-amd64-virtualbox.box

raccoon-amd64-virtualbox.box: raccoon-amd64.json *.sh
	PACKER_LOG=1 packer build -force -only virtualbox-iso raccoon-amd64.json

clean: clean-packer clean-boxes clean-vagrant clean-artifacts

clean-packer:
	-rm crash.log

clean-boxes:
	-rm *.box

clean-vagrant:
	-rm -rf .vagrant

clean-artifacts:
	-rm -rf packer_cache

lint: packer-validate shfmt

packer-validate:
	find . -name '*.json' -exec packer validate {} \;

shfmt:
	find . -name '*.sh' -print | xargs shfmt -w -i 4
