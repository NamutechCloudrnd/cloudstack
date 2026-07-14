# namuVIRT 설치 하네스 Makefile
#
#   make build VERSION=1.0.0
#   make export VERSION=1.0.0
#   make syntax          # ansible playbook syntax-check (로컬 ansible 필요)
#   make lint            # bash -n 전체 스크립트
#   make clean VERSION=1.0.0

VERSION ?= 1.0.0
OUTPUT  ?= release/namuvirt-installer-$(VERSION)
PACKAGES_SRC ?=

SHELL := /bin/bash

.PHONY: help build export syntax lint clean

help:
	@echo "targets: build export syntax lint clean  (VERSION=$(VERSION))"

build:
	./build-images.sh --version $(VERSION) $(if $(PACKAGES_SRC),--packages-src $(PACKAGES_SRC),)

export:
	./export-images.sh --version $(VERSION) --output $(OUTPUT)

# 로컬 ansible 로 syntax-check (컨테이너 없이 빠른 검증)
syntax:
	cd ansible && ANSIBLE_CONFIG=ansible.cfg ansible-playbook --syntax-check \
	  -e namuvirt_config_file=$(CURDIR)/config.sample.yaml site.yml preflight.yml

# 모든 bash 스크립트 문법 검사
lint:
	@set -e; for f in install-namuvirt.sh build-images.sh export-images.sh scripts/*.sh; do \
	  bash -n "$$f" && echo "OK  $$f"; \
	done

clean:
	rm -rf release/namuvirt-installer-$(VERSION)
	-docker rmi namuvirt-management-setup:$(VERSION) \
	            namuvirt-host-setup-rocky:$(VERSION) \
	            namuvirt-host-setup-ubuntu:$(VERSION) 2>/dev/null || true
