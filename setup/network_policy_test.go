package main

import (
	"context"
	"reflect"
	"testing"
)

func TestNormalizeNetworkModeDefaultsToPublic(t *testing.T) {
	if actual := normalizeNetworkMode(""); actual != networkModePublic {
		t.Fatalf("normalizeNetworkMode() = %q, want %q", actual, networkModePublic)
	}
	if validNetworkMode("restricted") {
		t.Fatal("unknown network mode must be rejected")
	}
}

func TestInternalNetworkModeRejectsPublicCodeHosts(t *testing.T) {
	blocked := []string{
		"https://github.com/org/repo",
		"https://api.github.com/repos/org/repo",
		"https://uploads.github.com/repos/org/repo/releases",
		"https://raw.githubusercontent.com/org/repo/main/file",
		"https://objects.githubusercontent.com/object",
		"https://cdn.githubassets.com/assets/app.js",
		"https://ghcr.io/v2/org/image/manifests/v1",
		"https://cache.ghcr.io/v2/org/image/manifests/v1",
		"https://registry-1.docker.io/v2/library/redis/manifests/latest",
		"https://hub.docker.com/v2/repositories/library/redis",
	}
	for _, candidate := range blocked {
		if networkModeAllowsURL(networkModeInternal, candidate, false) {
			t.Fatalf("internal mode allowed %s", candidate)
		}
	}
	if !networkModeAllowsURL(networkModeInternal, "https://release.internal.example/v1/manifest.json", false) {
		t.Fatal("internal HTTPS artifact source was rejected")
	}
	if networkModeAllowsURL(networkModeInternal, "http://release.internal.example/manifest.json", false) {
		t.Fatal("internal mode allowed plaintext HTTP")
	}
}

func TestGiteeURLRequiresExplicitOptIn(t *testing.T) {
	const source = "https://git.gitee.com/example/project.git"
	for _, mode := range []string{networkModePublic, networkModeInternal} {
		if networkModeAllowsURL(mode, source, false) {
			t.Fatalf("%s mode allowed Gitee without opt-in", mode)
		}
		if !networkModeAllowsURL(mode, source, true) {
			t.Fatalf("%s mode rejected explicitly allowed Gitee", mode)
		}
	}
}

func TestOfflineNetworkModeRejectsEveryRemoteURL(t *testing.T) {
	for _, candidate := range []string{
		"https://release.internal.example/manifest.json",
		"https://gitee.com/example/project.git",
		"http://127.0.0.1/test",
	} {
		if networkModeAllowsURL(networkModeOffline, candidate, true) {
			t.Fatalf("offline mode allowed %s", candidate)
		}
	}
}

func TestInternalRegistryRequiresExplicitNonPublicHost(t *testing.T) {
	blocked := []string{
		"ghcr.io/example/image:v1.2.3",
		"cache.ghcr.io/example/image:v1.2.3",
		"postgres:16-alpine",
		"docker.io/library/redis:7.4-alpine",
		"registry-1.docker.io/library/redis:7.4-alpine",
		"registry.hub.docker.com/library/redis:7.4-alpine",
	}
	for _, reference := range blocked {
		if networkModeAllowsRegistry(networkModeInternal, reference, false) {
			t.Fatalf("internal mode allowed %s", reference)
		}
	}
	if !networkModeAllowsRegistry(networkModeInternal, "registry.internal.example/xingchen/server:v1.20.14", false) {
		t.Fatal("internal registry reference was rejected")
	}
}

func TestGiteeRegistryRequiresExplicitOptIn(t *testing.T) {
	const reference = "registry.gitee.com/example/agent:v1.20.14"
	for _, mode := range []string{networkModePublic, networkModeInternal} {
		if networkModeAllowsRegistry(mode, reference, false) {
			t.Fatalf("%s mode allowed Gitee registry without opt-in", mode)
		}
		if !networkModeAllowsRegistry(mode, reference, true) {
			t.Fatalf("%s mode rejected explicitly allowed Gitee registry", mode)
		}
	}
}

func TestControllerReleaseAPIHonorsNetworkMode(t *testing.T) {
	service := &controllerUpdateService{
		apiBase:        controllerGitHubAPIBase,
		allowGitHubAPI: true,
		networkMode:    networkModeInternal,
	}
	if service.githubReleaseEnabled() {
		t.Fatal("internal mode enabled the GitHub API")
	}

	service.apiBase = "https://release.internal.example/api"
	if !service.githubReleaseEnabled() {
		t.Fatal("internal mode rejected an explicitly configured internal API")
	}

	service.apiBase = "https://gitee.com/api/v5/repos/example/project"
	if service.githubReleaseEnabled() {
		t.Fatal("internal mode enabled Gitee without opt-in")
	}
	service.allowGitee = true
	if !service.githubReleaseEnabled() {
		t.Fatal("internal mode rejected explicitly allowed Gitee")
	}
}

func TestOfflineControllerUpdaterArgumentsDisableRemoteFallback(t *testing.T) {
	command := updateControllerCommand(context.Background(), "/packaged/update-controller.sh", "--apply", "--offline", "--no-source-fallback")
	want := []string{"bash", "/packaged/update-controller.sh", "--apply", "--offline", "--no-source-fallback"}
	if !reflect.DeepEqual(command.Args, want) {
		t.Fatalf("command args = %#v, want %#v", command.Args, want)
	}
}
