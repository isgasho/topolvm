## Dependency versions

CSI_VERSION=1.1.0
K8S_VERSION=1.18.9
KUBEBUILDER_VERSION = 2.3.1
KIND_VERSION=0.9.0
PROTOC_VERSION=3.12.4

## DON'T EDIT BELOW THIS LINE

SUDO=sudo
CURL=curl -Lsf
BINDIR := $(PWD)/bin
CONTROLLER_GEN := $(BINDIR)/controller-gen
KUBEBUILDER_ASSETS := $(BINDIR)
PROTOC := PATH=$(BINDIR):$(PATH) $(BINDIR)/protoc -I=$(PWD)/include:.
PACKAGES := unzip lvm2 xfsprogs

GO_FILES=$(shell find -name '*.go' -not -name '*_test.go')
GOOS := $(shell go env GOOS)
GOARCH := $(shell go env GOARCH)
GO111MODULE = on
GOFLAGS = -mod=vendor
export GO111MODULE GOFLAGS KUBEBUILDER_ASSETS

BUILD_TARGET=hypertopolvm
TOPOLVM_VERSION ?= devel
IMAGE_TAG ?= latest

csi.proto:
	$(CURL) -o $@ https://raw.githubusercontent.com/container-storage-interface/spec/v$(CSI_VERSION)/csi.proto
	sed -i 's,^option go_package.*$$,option go_package = "github.com/topolvm/topolvm/csi";,' csi.proto
	sed -i '/^\/\/ Code generated by make;.*$$/d' csi.proto

csi/csi.pb.go: csi.proto
	mkdir -p csi
	$(PROTOC) --go_out=module=github.com/topolvm/topolvm:. $<

csi/csi_grpc.pb.go: csi.proto
	mkdir -p csi
	$(PROTOC) --go-grpc_out=module=github.com/topolvm/topolvm:. $<

lvmd/proto/lvmd.pb.go: lvmd/proto/lvmd.proto
	$(PROTOC) --go_out=module=github.com/topolvm/topolvm:. $<

lvmd/proto/lvmd_grpc.pb.go: lvmd/proto/lvmd.proto
	$(PROTOC) --go-grpc_out=module=github.com/topolvm/topolvm:. $<

docs/lvmd-protocol.md: lvmd/proto/lvmd.proto
	$(PROTOC) --doc_out=./docs --doc_opt=markdown,$@ $<

PROTOBUF_GEN = csi/csi.pb.go csi/csi_grpc.pb.go \
	lvmd/proto/lvmd.pb.go lvmd/proto/lvmd_grpc.pb.go docs/lvmd-protocol.md

.PHONY: test
test:
	test -z "$$(gofmt -s -l . | grep -v '^vendor' | tee /dev/stderr)"
	staticcheck ./...
	test -z "$$(nilerr ./... 2>&1 | tee /dev/stderr)"
	ineffassign .
	go install ./...
	go test -race -v ./...
	go vet ./...
	test -z "$$(go vet ./... | grep -v '^vendor' | tee /dev/stderr)"

# Generate manifests e.g. CRD, RBAC etc.
.PHONY: manifests
manifests:
	$(CONTROLLER_GEN) \
		crd:trivialVersions=true \
		rbac:roleName=topolvm-controller \
		webhook \
		paths="./api/...;./controllers;./hook;./driver/k8s" \
		output:crd:artifacts:config=config/crd/bases
	rm -f deploy/manifests/base/crd.yaml
	cp config/crd/bases/topolvm.cybozu.com_logicalvolumes.yaml deploy/manifests/base/crd.yaml

.PHONY: generate
generate: $(PROTOBUF_GEN)
	$(CONTROLLER_GEN) object:headerFile=./hack/boilerplate.go.txt paths="./api/..."

.PHONY: check-uncommitted
check-uncommitted:
	$(MAKE) manifests
	$(MAKE) generate
	git diff --exit-code --name-only

.PHONY: build
build: build/hypertopolvm build/lvmd csi-sidecars

build/hypertopolvm: $(GO_FILES)
	mkdir -p build
	go build -o $@ -ldflags "-X github.com/topolvm/topolvm.Version=$(TOPOLVM_VERSION)" ./pkg/hypertopolvm

build/lvmd:
	mkdir -p build
	CGO_ENABLED=0 go build -o $@ -ldflags "-X github.com/topolvm/topolvm.Version=$(TOPOLVM_VERSION)" ./pkg/lvmd

.PHONY: csi-sidecars
csi-sidecars:
	mkdir -p build
	make -f csi-sidecars.mk OUTPUT_DIR=build

.PHONY: image
image:
	docker build -t $(IMAGE_PREFIX)topolvm:devel .

.PHONY: tag
tag:
	docker tag $(IMAGE_PREFIX)topolvm:devel $(IMAGE_PREFIX)topolvm:$(IMAGE_TAG)

.PHONY: push
push:
	docker push $(IMAGE_PREFIX)topolvm:$(IMAGE_TAG)

.PHONY: clean
clean:
	rm -rf build/
	rm -rf bin/
	rm -rf include/

.PHONY: tools
tools:
	cd /tmp; env GOFLAGS= GO111MODULE=on go get golang.org/x/tools/cmd/goimports	
	cd /tmp; env GOFLAGS= GO111MODULE=on go get honnef.co/go/tools/cmd/staticcheck
	cd /tmp; env GOFLAGS= GO111MODULE=on go get github.com/gordonklaus/ineffassign
	cd /tmp; env GOFLAGS= GO111MODULE=on go get github.com/gostaticanalysis/nilerr/cmd/nilerr

.PHONY: setup
setup: tools
	$(SUDO) apt-get update
	$(SUDO) apt-get -y install --no-install-recommends $(PACKAGES)
	if apt-cache show btrfs-progs; then \
		$(SUDO) apt-get install -y btrfs-progs; \
	else \
		$(SUDO) apt-get install -y btrfs-tools; \
	fi

	mkdir -p bin
	curl -sfL https://go.kubebuilder.io/dl/$(KUBEBUILDER_VERSION)/$(GOOS)/$(GOARCH) | tar -xz -C /tmp/
	mv /tmp/kubebuilder_$(KUBEBUILDER_VERSION)_$(GOOS)_$(GOARCH)/bin/* bin/
	rm -rf /tmp/kubebuilder_*
	GOBIN=$(BINDIR) go install sigs.k8s.io/controller-tools/cmd/controller-gen

	curl -sfL -o protoc.zip https://github.com/protocolbuffers/protobuf/releases/download/v$(PROTOC_VERSION)/protoc-$(PROTOC_VERSION)-linux-x86_64.zip
	unzip -o protoc.zip bin/protoc 'include/*'
	rm -f protoc.zip
	GOBIN=$(BINDIR) go install google.golang.org/protobuf/cmd/protoc-gen-go
	GOBIN=$(BINDIR) go install google.golang.org/grpc/cmd/protoc-gen-go-grpc
	GOBIN=$(BINDIR) go install github.com/pseudomuto/protoc-gen-doc/cmd/protoc-gen-doc

	curl -o $(BINDIR)/kind -sfL https://kind.sigs.k8s.io/dl/v$(KIND_VERSION)/kind-linux-amd64
	curl -o $(BINDIR)/kubectl -sfL https://storage.googleapis.com/kubernetes-release/release/v$(K8S_VERSION)/bin/linux/amd64/kubectl
	curl -sfL https://github.com/kubernetes-sigs/kustomize/releases/download/kustomize%2Fv3.7.0/kustomize_v3.7.0_linux_amd64.tar.gz | tar -xz -C $(BINDIR)
	chmod a+x $(BINDIR)/kubectl $(BINDIR)/kind
	GOBIN=$(BINDIR) go install github.com/onsi/ginkgo/ginkgo
