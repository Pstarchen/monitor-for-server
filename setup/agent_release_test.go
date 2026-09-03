package main

import (
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"errors"
	"net/http"
	"net/http/httptest"
	"os"
	"path/filepath"
	"strings"
	"sync"
	"sync/atomic"
	"testing"
)

func TestAgentReleaseUsesOfflineManifest(t *testing.T) {
	content := []byte("offline-agent")
	root := t.TempDir()
	manifestPath := filepath.Join(root, "manifest.json")
	offlineDir := filepath.Join(root, "assets")
	if err := os.MkdirAll(offlineDir, 0700); err != nil {
		t.Fatal(err)
	}
	asset := testAgentAsset("linux", "amd64", "xingchen-agent_linux_amd64.tar.gz", content)
	writeTestManifest(t, manifestPath, asset)
	if err := os.WriteFile(filepath.Join(offlineDir, asset.File), content, 0600); err != nil {
		t.Fatal(err)
	}
	service := &agentReleaseService{
		client:               http.DefaultClient,
		manifestPath:         manifestPath,
		manifestPathRequired: true,
		offlineDir:           offlineDir,
		cacheDir:             filepath.Join(root, "cache"),
	}

	releaseResponse := requestAgentRelease(t, service, "/api/setup/agent-release?os=linux&arch=amd64")
	if releaseResponse.Code != http.StatusOK {
		t.Fatalf("release response = %d %s", releaseResponse.Code, releaseResponse.Body.String())
	}
	var selection agentReleaseSelection
	if err := json.NewDecoder(releaseResponse.Body).Decode(&selection); err != nil {
		t.Fatal(err)
	}
	if selection.Source != "local" || selection.Cached || selection.SHA256 != asset.SHA256 || selection.Verification != "sha256" {
		t.Fatalf("offline selection = %+v", selection)
	}

	artifactResponse := requestAgentArtifact(t, service, "/api/setup/agent-artifact?os=linux&arch=amd64&version=v1.20.11")
	if artifactResponse.Code != http.StatusOK || artifactResponse.Body.String() != string(content) {
		t.Fatalf("artifact response = %d %q", artifactResponse.Code, artifactResponse.Body.String())
	}
	if artifactResponse.Header().Get("X-Xingchen-Artifact-Source") != "local" {
		t.Fatalf("artifact source = %q", artifactResponse.Header().Get("X-Xingchen-Artifact-Source"))
	}
}

func TestAgentReleaseUsesPackagedFallback(t *testing.T) {
	content := []byte("packaged-agent")
	root := t.TempDir()
	packagedRoot := filepath.Join(root, "packaged")
	packagedAssets := filepath.Join(packagedRoot, "assets")
	if err := os.MkdirAll(packagedAssets, 0700); err != nil {
		t.Fatal(err)
	}
	asset := testAgentAsset("linux", "amd64", "xingchen-agent_linux_amd64.tar.gz", content)
	writeTestManifest(t, filepath.Join(packagedRoot, "manifest.json"), asset)
	if err := os.WriteFile(filepath.Join(packagedAssets, asset.File), content, 0600); err != nil {
		t.Fatal(err)
	}
	service := &agentReleaseService{
		client:               http.DefaultClient,
		manifestPath:         filepath.Join(root, "workspace", "manifest.json"),
		packagedManifestPath: filepath.Join(packagedRoot, "manifest.json"),
		offlineDir:           filepath.Join(root, "workspace", "assets"),
		packagedOfflineDir:   packagedAssets,
		cacheDir:             filepath.Join(root, "cache"),
	}

	releaseResponse := requestAgentRelease(t, service, "/api/setup/agent-release?os=linux&arch=amd64")
	if releaseResponse.Code != http.StatusOK {
		t.Fatalf("release response = %d %s", releaseResponse.Code, releaseResponse.Body.String())
	}
	artifactResponse := requestAgentArtifact(t, service, "/api/setup/agent-artifact?os=linux&arch=amd64&version=v1.20.11")
	if artifactResponse.Code != http.StatusOK || artifactResponse.Body.String() != string(content) {
		t.Fatalf("artifact response = %d %q", artifactResponse.Code, artifactResponse.Body.String())
	}
}

func TestAgentReleaseDoesNotBypassRequiredManifestWithPackagedFallback(t *testing.T) {
	root := t.TempDir()
	packagedManifest := filepath.Join(root, "packaged", "manifest.json")
	if err := os.MkdirAll(filepath.Dir(packagedManifest), 0700); err != nil {
		t.Fatal(err)
	}
	writeTestManifest(t, packagedManifest, testAgentAsset("linux", "amd64", "agent.tar.gz", []byte("agent")))
	service := &agentReleaseService{
		manifestPath:         filepath.Join(root, "required", "manifest.json"),
		manifestPathRequired: true,
		packagedManifestPath: packagedManifest,
		cacheDir:             filepath.Join(root, "cache"),
	}

	response := requestAgentRelease(t, service, "/api/setup/agent-release?os=linux&arch=amd64")
	if response.Code != http.StatusBadGateway || !strings.Contains(response.Body.String(), "读取本地清单") {
		t.Fatalf("required manifest response = %d %s", response.Code, response.Body.String())
	}
}

func TestAgentReleaseRejectsIncompatibleController(t *testing.T) {
	content := []byte("offline-agent")
	root := t.TempDir()
	manifestPath := filepath.Join(root, "manifest.json")
	offlineDir := filepath.Join(root, "assets")
	if err := os.MkdirAll(offlineDir, 0700); err != nil {
		t.Fatal(err)
	}
	asset := testAgentAsset("linux", "amd64", "xingchen-agent_linux_amd64.tar.gz", content)
	writeTestManifest(t, manifestPath, asset)
	if err := os.WriteFile(filepath.Join(offlineDir, asset.File), content, 0600); err != nil {
		t.Fatal(err)
	}
	service := &agentReleaseService{
		controllerVersion:    func() string { return "v1.19.9" },
		manifestPath:         manifestPath,
		manifestPathRequired: true,
		offlineDir:           offlineDir,
		cacheDir:             filepath.Join(root, "cache"),
	}

	for _, response := range []*httptest.ResponseRecorder{
		requestAgentRelease(t, service, "/api/setup/agent-release?os=linux&arch=amd64"),
		requestAgentArtifact(t, service, "/api/setup/agent-artifact?os=linux&arch=amd64&version=v1.20.11"),
	} {
		if response.Code != http.StatusConflict || !strings.Contains(response.Body.String(), "最低要求 v1.20.0") {
			t.Fatalf("incompatible release response = %d %s", response.Code, response.Body.String())
		}
	}
}

func TestAgentReleaseRejectsUnknownControllerVersion(t *testing.T) {
	service := &agentReleaseService{controllerVersion: func() string { return "dev" }}
	err := service.ensureControllerCompatible(agentReleaseManifest{MinimumCompatibleController: "v1.20.0"})
	if !errors.Is(err, errIncompatibleAgentRelease) || !strings.Contains(err.Error(), "无法确认当前总控版本") {
		t.Fatalf("unknown controller compatibility error = %v", err)
	}
}

func TestSelectControllerVersionPrefersRunningServer(t *testing.T) {
	for _, test := range []struct {
		name       string
		running    string
		configured string
		want       string
	}{
		{name: "running server", running: "v1.20.10", configured: "v1.20.11", want: "v1.20.10"},
		{name: "configured fallback", configured: "1.20.11", want: "v1.20.11"},
		{name: "invalid running fallback", running: "main", configured: "v1.20.11", want: "v1.20.11"},
		{name: "no known version", running: "dev", configured: "latest", want: ""},
	} {
		t.Run(test.name, func(t *testing.T) {
			if got := selectControllerVersion(test.running, test.configured); got != test.want {
				t.Fatalf("selectControllerVersion(%q, %q) = %q, want %q", test.running, test.configured, got, test.want)
			}
		})
	}
}

func TestAgentReleaseFallsBackToLastKnownGoodManifest(t *testing.T) {
	asset := testAgentAsset("windows", "arm64", "xingchen-agent_windows_arm64.zip", []byte("agent"))
	manifest := marshalTestManifest(t, asset)
	manifestDigest := sha256.Sum256(manifest)
	var fail atomic.Bool
	server := httptest.NewTLSServer(http.HandlerFunc(func(w http.ResponseWriter, _ *http.Request) {
		if fail.Load() {
			http.Error(w, "unavailable", http.StatusServiceUnavailable)
			return
		}
		_, _ = w.Write(manifest)
	}))
	defer server.Close()
	root := t.TempDir()
	packagedManifest := filepath.Join(root, "packaged.json")
	if err := os.WriteFile(packagedManifest, []byte("not-the-configured-manifest"), 0600); err != nil {
		t.Fatal(err)
	}
	service := &agentReleaseService{
		client:               server.Client(),
		manifestPath:         filepath.Join(root, "missing.json"),
		packagedManifestPath: packagedManifest,
		manifestURLs:         []string{server.URL + "/manifest.json"},
		offlineDir:           filepath.Join(root, "offline"),
		cacheDir:             filepath.Join(root, "cache"),
		manifestSHA256:       hex.EncodeToString(manifestDigest[:]),
	}

	first := requestAgentRelease(t, service, "/api/setup/agent-release?os=windows&arch=arm64")
	if first.Code != http.StatusOK {
		t.Fatalf("initial remote release = %d %s", first.Code, first.Body.String())
	}
	fail.Store(true)
	second := requestAgentRelease(t, service, "/api/setup/agent-release?os=windows&arch=arm64")
	if second.Code != http.StatusOK {
		t.Fatalf("cached release = %d %s", second.Code, second.Body.String())
	}
	var selection agentReleaseSelection
	if err := json.NewDecoder(second.Body).Decode(&selection); err != nil {
		t.Fatal(err)
	}
	if !selection.Cached {
		t.Fatalf("fallback selection is not marked cached: %+v", selection)
	}
}

func TestAgentReleaseRejectsManifestOutsidePinnedTrust(t *testing.T) {
	asset := testAgentAsset("linux", "amd64", "xingchen-agent_linux_amd64.tar.gz", []byte("agent"))
	manifest := marshalTestManifest(t, asset)
	root := t.TempDir()
	manifestPath := filepath.Join(root, "manifest.json")
	if err := os.WriteFile(manifestPath, manifest, 0600); err != nil {
		t.Fatal(err)
	}
	service := &agentReleaseService{
		manifestPath:         manifestPath,
		manifestPathRequired: true,
		manifestSHA256:       strings.Repeat("0", 64),
		cacheDir:             filepath.Join(root, "cache"),
	}
	response := requestAgentRelease(t, service, "/api/setup/agent-release?os=linux&arch=amd64")
	if response.Code != http.StatusBadGateway || !strings.Contains(response.Body.String(), "预置信任摘要不匹配") {
		t.Fatalf("pinned manifest mismatch response = %d %s", response.Code, response.Body.String())
	}
	if _, err := os.Stat(filepath.Join(service.cacheDir, "manifest.json")); !os.IsNotExist(err) {
		t.Fatalf("untrusted manifest was cached: %v", err)
	}
}

func TestAgentArtifactDownloadsOnceAndUsesVerifiedCache(t *testing.T) {
	content := []byte("verified-agent-binary")
	asset := testAgentAsset("linux", "arm64", "xingchen-agent_linux_arm64.tar.gz", content)
	manifest := marshalTestManifest(t, asset)
	var downloads atomic.Int32
	server := httptest.NewTLSServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		switch r.URL.Path {
		case "/manifest.json":
			_, _ = w.Write(manifest)
		case "/releases/v1.20.11/" + asset.File:
			downloads.Add(1)
			_, _ = w.Write(content)
		default:
			http.NotFound(w, r)
		}
	}))
	defer server.Close()
	root := t.TempDir()
	service := &agentReleaseService{
		client:           server.Client(),
		manifestPath:     filepath.Join(root, "missing.json"),
		manifestURLs:     []string{server.URL + "/manifest.json"},
		artifactBaseURLs: []string{server.URL + "/releases"},
		offlineDir:       filepath.Join(root, "offline"),
		cacheDir:         filepath.Join(root, "cache"),
	}

	path := "/api/setup/agent-artifact?os=linux&arch=arm64&version=v1.20.11"
	const callers = 4
	responses := make([]*httptest.ResponseRecorder, callers)
	var wait sync.WaitGroup
	for index := range responses {
		wait.Add(1)
		go func(index int) {
			defer wait.Done()
			responses[index] = requestAgentArtifact(t, service, path)
		}(index)
	}
	wait.Wait()
	for _, response := range responses {
		if response.Code != http.StatusOK || response.Body.String() != string(content) {
			t.Fatalf("concurrent artifact response = %d %q", response.Code, response.Body.String())
		}
	}
	if got := downloads.Load(); got != 1 {
		t.Fatalf("artifact downloaded %d times, want 1", got)
	}
}

func TestAgentArtifactRejectsChecksumMismatchWithoutPollutingCache(t *testing.T) {
	content := []byte("tampered-agent")
	asset := testAgentAsset("linux", "amd64", "xingchen-agent_linux_amd64.tar.gz", []byte("expected-agent"))
	manifest := marshalTestManifest(t, asset)
	server := httptest.NewTLSServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if r.URL.Path == "/manifest.json" {
			_, _ = w.Write(manifest)
			return
		}
		_, _ = w.Write(content)
	}))
	defer server.Close()
	root := t.TempDir()
	service := &agentReleaseService{
		client:           server.Client(),
		manifestPath:     filepath.Join(root, "missing.json"),
		manifestURLs:     []string{server.URL + "/manifest.json"},
		artifactBaseURLs: []string{server.URL},
		offlineDir:       filepath.Join(root, "offline"),
		cacheDir:         filepath.Join(root, "cache"),
	}

	response := requestAgentArtifact(t, service, "/api/setup/agent-artifact?os=linux&arch=amd64&version=v1.20.11")
	if response.Code != http.StatusBadGateway || !strings.Contains(response.Body.String(), "完整性校验失败") {
		t.Fatalf("checksum mismatch response = %d %s", response.Code, response.Body.String())
	}
	cachePath := filepath.Join(service.cacheDir, "artifacts", "v1.20.11", asset.File)
	if _, err := os.Stat(cachePath); !os.IsNotExist(err) {
		t.Fatalf("invalid artifact polluted cache: %v", err)
	}
}

func TestAgentReleaseRejectsRedirectToUntrustedManifestHost(t *testing.T) {
	asset := testAgentAsset("linux", "amd64", "xingchen-agent_linux_amd64.tar.gz", []byte("agent"))
	manifest := marshalTestManifest(t, asset)
	var untrustedRequests atomic.Int32
	untrusted := httptest.NewTLSServer(http.HandlerFunc(func(w http.ResponseWriter, _ *http.Request) {
		untrustedRequests.Add(1)
		_, _ = w.Write(manifest)
	}))
	defer untrusted.Close()
	trusted := httptest.NewTLSServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		http.Redirect(w, r, untrusted.URL+"/manifest.json", http.StatusFound)
	}))
	defer trusted.Close()
	root := t.TempDir()
	service := &agentReleaseService{
		client:       trusted.Client(),
		manifestPath: filepath.Join(root, "missing.json"),
		manifestURLs: []string{trusted.URL + "/manifest.json"},
		offlineDir:   filepath.Join(root, "offline"),
		cacheDir:     filepath.Join(root, "cache"),
	}

	response := requestAgentRelease(t, service, "/api/setup/agent-release?os=linux&arch=amd64")
	if response.Code != http.StatusBadGateway {
		t.Fatalf("redirected manifest response = %d %s", response.Code, response.Body.String())
	}
	if got := untrustedRequests.Load(); got != 0 {
		t.Fatalf("untrusted manifest host received %d requests", got)
	}
}

func TestAgentArtifactRejectsRedirectOutsideConfiguredBase(t *testing.T) {
	content := []byte("agent")
	asset := testAgentAsset("linux", "amd64", "xingchen-agent_linux_amd64.tar.gz", content)
	var untrustedRequests atomic.Int32
	untrusted := httptest.NewTLSServer(http.HandlerFunc(func(w http.ResponseWriter, _ *http.Request) {
		untrustedRequests.Add(1)
		_, _ = w.Write(content)
	}))
	defer untrusted.Close()
	trusted := httptest.NewTLSServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		http.Redirect(w, r, untrusted.URL+"/agent.tar.gz", http.StatusFound)
	}))
	defer trusted.Close()
	root := t.TempDir()
	manifestPath := filepath.Join(root, "manifest.json")
	writeTestManifest(t, manifestPath, asset)
	service := &agentReleaseService{
		client:               trusted.Client(),
		manifestPath:         manifestPath,
		manifestPathRequired: true,
		artifactBaseURLs:     []string{trusted.URL + "/releases"},
		offlineDir:           filepath.Join(root, "offline"),
		cacheDir:             filepath.Join(root, "cache"),
	}

	response := requestAgentArtifact(t, service, "/api/setup/agent-artifact?os=linux&arch=amd64&version=v1.20.11")
	if response.Code != http.StatusBadGateway {
		t.Fatalf("redirected artifact response = %d %s", response.Code, response.Body.String())
	}
	if got := untrustedRequests.Load(); got != 0 {
		t.Fatalf("untrusted artifact host received %d requests", got)
	}
}

func TestAgentReleaseRejectsTraversalAndArbitraryURL(t *testing.T) {
	root := t.TempDir()
	manifestPath := filepath.Join(root, "manifest.json")
	asset := testAgentAsset("linux", "amd64", "../agent.tar.gz", []byte("agent"))
	writeTestManifest(t, manifestPath, asset)
	service := &agentReleaseService{client: http.DefaultClient, manifestPath: manifestPath, manifestPathRequired: true, offlineDir: root, cacheDir: filepath.Join(root, "cache")}
	response := requestAgentRelease(t, service, "/api/setup/agent-release?os=linux&arch=amd64")
	if response.Code != http.StatusBadGateway {
		t.Fatalf("traversal manifest response = %d %s", response.Code, response.Body.String())
	}

	asset = testAgentAsset("linux", "amd64", "agent.tar.gz", []byte("agent"))
	asset.URL = "https://169.254.169.254/latest/meta-data"
	writeTestManifest(t, manifestPath, asset)
	response = requestAgentArtifact(t, service, "/api/setup/agent-artifact?os=linux&arch=amd64&version=v1.20.11")
	if response.Code != http.StatusBadGateway || !strings.Contains(response.Body.String(), "未配置制品源") {
		t.Fatalf("arbitrary URL response = %d %s", response.Code, response.Body.String())
	}
}

func TestAgentReleaseRejectsInvalidRequestParameters(t *testing.T) {
	service := &agentReleaseService{}
	for _, path := range []string{
		"/api/setup/agent-release?os=../../etc&arch=amd64",
		"/api/setup/agent-release?os=linux&arch=x86",
		"/api/setup/agent-artifact?os=linux&arch=amd64&version=latest",
	} {
		var response *httptest.ResponseRecorder
		if strings.Contains(path, "artifact") {
			response = requestAgentArtifact(t, service, path)
		} else {
			response = requestAgentRelease(t, service, path)
		}
		if response.Code != http.StatusBadRequest {
			t.Fatalf("invalid request %q returned %d", path, response.Code)
		}
	}
}

func testAgentAsset(osName, arch, file string, content []byte) agentReleaseAsset {
	hash := sha256.Sum256(content)
	return agentReleaseAsset{OS: osName, Arch: arch, File: file, SHA256: hex.EncodeToString(hash[:]), Size: int64(len(content))}
}

func marshalTestManifest(t *testing.T, assets ...agentReleaseAsset) []byte {
	t.Helper()
	content, err := json.Marshal(agentReleaseManifest{
		SchemaVersion:               1,
		Version:                     "v1.20.11",
		PublishedAt:                 "2026-09-04T00:00:00Z",
		MinimumCompatibleController: "v1.20.0",
		Assets:                      assets,
	})
	if err != nil {
		t.Fatal(err)
	}
	return content
}

func writeTestManifest(t *testing.T, path string, assets ...agentReleaseAsset) {
	t.Helper()
	if err := os.WriteFile(path, marshalTestManifest(t, assets...), 0600); err != nil {
		t.Fatal(err)
	}
}

func requestAgentRelease(t *testing.T, service *agentReleaseService, path string) *httptest.ResponseRecorder {
	t.Helper()
	response := httptest.NewRecorder()
	service.release(response, httptest.NewRequest(http.MethodGet, path, nil))
	return response
}

func requestAgentArtifact(t *testing.T, service *agentReleaseService, path string) *httptest.ResponseRecorder {
	t.Helper()
	response := httptest.NewRecorder()
	service.artifact(response, httptest.NewRequest(http.MethodGet, path, nil))
	return response
}
