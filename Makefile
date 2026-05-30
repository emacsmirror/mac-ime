# Makefile
CC = clang
CFLAGS = -Wall -O2 -fPIC -fobjc-arc
LDFLAGS = -dynamiclib -framework Cocoa -framework Carbon
ARCH_FLAGS = -arch x86_64 -arch arm64

# Include path for emacs-module.h
CFLAGS += -I./src

SRC = src/mac_ime.m
OBJ = mac-ime-module.so

all: $(OBJ)

$(OBJ): $(SRC)
	$(CC) $(ARCH_FLAGS) $(CFLAGS) $(LDFLAGS) -o $@ $<

clean:
	rm -f $(OBJ)

test: $(OBJ) compile lint
	@$(MAKE) check-module-policy
	@echo "Running Mock Tests..."
	emacs -Q -batch -L . -L test -l test/mac-ime-mock-test.el -f ert-run-tests-batch-and-exit
	@echo "Running Integration Tests..."
	emacs -Q -batch -L . -L test -l test/mac-ime-integration-test.el -f ert-run-tests-batch-and-exit
	@echo "Running inherit Tests..."
	emacs -Q -batch -L . -L test -l test/mac-ime-inherit-test.el -f ert-run-tests-batch-and-exit

check-module-policy: $(OBJ)
	@if xattr -p com.apple.quarantine $(OBJ) >/dev/null 2>&1; then \
		echo "Error: $(OBJ) has com.apple.quarantine and may fail to load."; \
		echo "Run: xattr -d com.apple.quarantine $(OBJ)"; \
		exit 1; \
	fi

compile:
	@echo "Byte-compiling mac-ime.el..."
	@emacs -Q -batch --eval "(setq byte-compile-error-on-warn t)" -f batch-byte-compile mac-ime.el
	@rm -f mac-ime.elc

lint:
	@echo "Running checkdoc..."
	@emacs -Q -batch --eval "(progn (checkdoc-file \"mac-ime.el\") (when (get-buffer \"*Warnings*\") (message \"checkdoc failed:\") (princ (with-current-buffer \"*Warnings*\" (buffer-string))) (kill-emacs 1)))"
	@echo "Running package-lint..."
	@emacs -batch --eval "(progn (require 'package) (add-to-list 'package-archives '(\"melpa\" . \"https://melpa.org/packages/\") t) (package-initialize) (unless (package-installed-p 'package-lint) (package-refresh-contents) (package-install 'package-lint)))" -l package-lint -f package-lint-batch-and-exit mac-ime.el

.PHONY: all clean test check-module-policy compile lint


