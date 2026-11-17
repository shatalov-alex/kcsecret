.PHONY: build test lint install uninstall release clean help

help:  ## show this help
	@grep -E '^[a-z]+:.*## ' $(MAKEFILE_LIST) | awk -F':.*## ' '{printf "  %-10s %s\n", $$1, $$2}'

build:  ## debug build into .build/
	swift build

test:  ## run the unit tests
	swift test

lint:  ## check the shell scripts' syntax
	zsh -n install.sh shell/ksecret.zsh

install:  ## build a release binary into ~/.local/bin and load the zsh integration
	./install.sh

uninstall:  ## remove the binary and the ~/.zshrc line (keeps the keychain)
	./install.sh --uninstall

release:  ## universal (arm64 + x86_64) release binary in dist/
	swift build -c release --arch arm64 --arch x86_64 --product kcsecret
	mkdir -p dist
	cp "$$(swift build -c release --arch arm64 --arch x86_64 --show-bin-path)/kcsecret" dist/kcsecret
	codesign --force --sign - dist/kcsecret
	lipo -info dist/kcsecret

clean:  ## remove build output
	rm -rf .build dist
