package main

import (
	"context"
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"errors"
	"net/http"
	"net/http/httptest"
	"net/url"
	"os"
	"os/exec"
	"path/filepath"
	"runtime"
	"strings"
	"testing"
	"time"
)

func validSetupRequest() setupRequest {
	return setupRequest{
		PublicBaseURL: "https://monitor.example.com", AllowedOrigins: "https://monitor.example.com", SiteName: "星辰监控", Timezone: "Asia/Shanghai",
		AdminUsername: "admin", AdminPassword: "administrator-password", AdminPasswordConfirm: "administrator-password",
	}
}

func TestValidateSetupRequest(t *testing.T) {
	if err := validateSetupRequest(validSetupRequest()); err != nil {
		t.Fatalf("valid setup request rejected: %v", err)
	}

	request := validSetupRequest()
	request.PublicBaseURL = "https://monitor.example.com/"
	request.AllowedOrigins = "https://monitor.example.com/"
	if err := validateSetupRequest(request); err != nil {
		t.Fatalf("trailing origin slash should be accepted: %v", err)
	}

	request = validSetupRequest()
	request.Timezone = "not-a-timezone"
	if err := validateSetupRequest(request); err == nil {
		t.Fatal("invalid IANA timezone was accepted")
	}
}

func TestAgentInstallerOnlyServesAllowlistedPlatforms(t *testing.T) {
	originalWorkspace, originalPackagedInstallerDir := workspace, packagedInstallerDir
	workspace = t.TempDir()
	packagedInstallerDir = filepath.Join(t.TempDir(), "not-installed")
	t.Cleanup(func() {
		workspace, packagedInstallerDir = originalWorkspace, originalPackagedInstallerDir
	})
	if err := os.MkdirAll(filepath.Join(workspace, "deploy"), 0700); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(filepath.Join(workspace, "deploy", "install-agent.sh"), []byte("#!/usr/bin/env bash\r\nset -e\r\n"), 0600); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(filepath.Join(workspace, "deploy", "install-agent.ps1"), []byte("#requires -version 5.1\r\n$ErrorActionPreference = 'Stop'\r\n"), 0600); err != nil {
		t.Fatal(err)
	}
	service := &setupService{}

	request := httptest.NewRequest(http.MethodGet, "/api/setup/agent-installer?platform=linux", nil)
	response := httptest.NewRecorder()
	service.agentInstaller(response, request)
	if response.Code != http.StatusOK || !strings.Contains(response.Body.String(), "#!/usr/bin/env bash") || strings.Contains(response.Body.String(), "\r") {
		t.Fatalf("linux installer response = %d %q", response.Code, response.Body.String())
	}
	if response.Header().Get("Cache-Control") != "no-store" {
		t.Fatal("installer response must not be cached")
	}
	if response.Header().Get("Content-Disposition") != `attachment; filename="install-agent.sh"` {
		t.Fatalf("installer filename = %q", response.Header().Get("Content-Disposition"))
	}

	request = httptest.NewRequest(http.MethodGet, "/api/setup/agent-installer?platform=linux&format=sha256", nil)
	response = httptest.NewRecorder()
	service.agentInstaller(response, request)
	normalized := []byte("#!/usr/bin/env bash\nset -e\n")
	digest := sha256.Sum256(normalized)
	if response.Code != http.StatusOK || strings.TrimSpace(response.Body.String()) != hex.EncodeToString(digest[:]) {
		t.Fatalf("installer digest response = %d %q", response.Code, response.Body.String())
	}
	if response.Header().Get("Content-Disposition") != `attachment; filename="install-agent.sh.sha256"` {
		t.Fatalf("installer digest filename = %q", response.Header().Get("Content-Disposition"))
	}

	request = httptest.NewRequest(http.MethodGet, "/api/setup/agent-installer?platform=windows&format=sha256", nil)
	response = httptest.NewRecorder()
	service.agentInstaller(response, request)
	windowsContent := []byte("#requires -version 5.1\r\n$ErrorActionPreference = 'Stop'\r\n")
	windowsDigest := sha256.Sum256(windowsContent)
	if response.Code != http.StatusOK || strings.TrimSpace(response.Body.String()) != hex.EncodeToString(windowsDigest[:]) {
		t.Fatalf("Windows installer digest response = %d %q", response.Code, response.Body.String())
	}

	request = httptest.NewRequest(http.MethodGet, "/api/setup/agent-installer?platform=../../.env", nil)
	response = httptest.NewRecorder()
	service.agentInstaller(response, request)
	if response.Code != http.StatusBadRequest {
		t.Fatalf("invalid platform returned %d, want 400", response.Code)
	}

	request = httptest.NewRequest(http.MethodGet, "/api/setup/agent-installer?platform=linux&format=script", nil)
	response = httptest.NewRecorder()
	service.agentInstaller(response, request)
	if response.Code != http.StatusBadRequest {
		t.Fatalf("invalid installer format returned %d, want 400", response.Code)
	}
}

func TestAgentInstallerPrefersPackagedVersionOverWorkspace(t *testing.T) {
	originalWorkspace, originalPackagedInstallerDir := workspace, packagedInstallerDir
	workspace = t.TempDir()
	packagedInstallerDir = t.TempDir()
	t.Cleanup(func() {
		workspace, packagedInstallerDir = originalWorkspace, originalPackagedInstallerDir
	})
	if err := os.MkdirAll(filepath.Join(workspace, "deploy"), 0700); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(filepath.Join(workspace, "deploy", "install-agent.sh"), []byte("#!/bin/sh\necho stale-workspace\n"), 0600); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(filepath.Join(packagedInstallerDir, "install-agent.sh"), []byte("#!/bin/sh\necho packaged-version\n"), 0600); err != nil {
		t.Fatal(err)
	}

	request := httptest.NewRequest(http.MethodGet, "/api/setup/agent-installer?platform=linux", nil)
	response := httptest.NewRecorder()
	(&setupService{}).agentInstaller(response, request)
	if response.Code != http.StatusOK || !strings.Contains(response.Body.String(), "packaged-version") || strings.Contains(response.Body.String(), "stale-workspace") {
		t.Fatalf("installer response = %d %q", response.Code, response.Body.String())
	}
}

func useAgentBootstrapFixture(t *testing.T, publicBaseURL string) {
	t.Helper()
	originalWorkspace, originalEnvPath, originalPackagedInstallerDir := workspace, envPath, packagedInstallerDir
	workspace = t.TempDir()
	envPath = filepath.Join(workspace, ".env")
	packagedInstallerDir = filepath.Join(t.TempDir(), "not-installed")
	t.Cleanup(func() {
		workspace, envPath, packagedInstallerDir = originalWorkspace, originalEnvPath, originalPackagedInstallerDir
	})
	if err := os.MkdirAll(filepath.Join(workspace, "deploy"), 0700); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(filepath.Join(workspace, "deploy", "install-agent.sh"), []byte("#!/usr/bin/env bash\nset -euo pipefail\n"), 0600); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(filepath.Join(workspace, "deploy", "install-agent.ps1"), []byte("$ErrorActionPreference = 'Stop'\r\n"), 0600); err != nil {
		t.Fatal(err)
	}
	if publicBaseURL != "" {
		if err := os.WriteFile(envPath, []byte("PUBLIC_BASE_URL=\""+publicBaseURL+"\"\n"), 0600); err != nil {
			t.Fatal(err)
		}
	}
}

func TestAgentBootstrapUsesConfiguredControllerAndVerifiesLinuxInstaller(t *testing.T) {
	useAgentBootstrapFixture(t, "https://monitor.example.com")
	query := url.Values{
		"platform":            {"linux"},
		"deviceId":            {"123e4567-e89b-42d3-a456-426614174000"},
		"interval":            {"30s"},
		"disk":                {"/", "/srv/data (primary)"},
		"collectAllProcesses": {"true"},
		"processLimit":        {"128"},
	}
	request := httptest.NewRequest(http.MethodGet, "http://setup:8090/api/setup/agent-bootstrap?"+query.Encode(), nil)
	request.Host = "untrusted.example"
	request.Header.Set("X-Forwarded-Host", "also-untrusted.example")
	response := httptest.NewRecorder()

	(&setupService{}).agentBootstrap(response, request)

	content := response.Body.String()
	if response.Code != http.StatusOK {
		t.Fatalf("Linux bootstrap response = %d %q", response.Code, content)
	}
	for _, expected := range []string{
		"#!/usr/bin/env bash",
		"https://monitor.example.com/api/setup/agent-installer?platform=linux",
		"&format=sha256",
		"sha256sum -- \"${installer}\"",
		"bash \"${installer}\" '--server-url' 'https://monitor.example.com' '--device-id' '123e4567-e89b-42d3-a456-426614174000' '--interval' '30s' '--disk' '/' '--disk' '/srv/data (primary)' '--all-processes' '--process-limit' '128'",
	} {
		if !strings.Contains(content, expected) {
			t.Fatalf("Linux bootstrap missing %q:\n%s", expected, content)
		}
	}
	if strings.Contains(content, "untrusted.example") || strings.Contains(content, "XINGCHEN_ENROLLMENT_TOKEN") || strings.Contains(content, "XINGCHEN_AGENT_KEY") {
		t.Fatalf("Linux bootstrap contains an untrusted origin or credential: %s", content)
	}
	if response.Header().Get("Cache-Control") != "no-store" || response.Header().Get("X-Content-Type-Options") != "nosniff" {
		t.Fatal("bootstrap response must be non-cacheable and nosniff")
	}
}

func agentBootstrapTestBash(t *testing.T) string {
	t.Helper()
	if runtime.GOOS == "windows" {
		// Windows' system bash.exe starts WSL; use the native Git Bash runtime.
		candidates := []string{`D:\Git\bin\bash.exe`, filepath.Join(os.Getenv("ProgramFiles"), "Git", "bin", "bash.exe")}
		if git, err := exec.LookPath("git"); err == nil {
			candidates = append(candidates, filepath.Join(filepath.Dir(filepath.Dir(git)), "bin", "bash.exe"))
		}
		for _, candidate := range candidates {
			if info, err := os.Stat(candidate); err == nil && !info.IsDir() {
				return candidate
			}
		}
		t.Skip("Agent bootstrap execution tests require Git Bash on Windows")
	}
	bash, err := exec.LookPath("bash")
	if err != nil {
		t.Skip("Agent bootstrap execution tests require Bash")
	}
	return bash
}

func TestAgentBootstrapExecutesVerifiedLinuxInstaller(t *testing.T) {
	bash := agentBootstrapTestBash(t)
	useAgentBootstrapFixture(t, "https://monitor.example.com")
	query := url.Values{
		"platform":            {"linux"},
		"deviceId":            {"123e4567-e89b-42d3-a456-426614174000"},
		"interval":            {"30s"},
		"disk":                {"/", "/srv/data (primary)", "/srv/a,b+archive"},
		"collectAllProcesses": {"true"},
		"processLimit":        {"128"},
	}
	response := httptest.NewRecorder()
	(&setupService{}).agentBootstrap(response, httptest.NewRequest(http.MethodGet, "/api/setup/agent-bootstrap?"+query.Encode(), nil))
	if response.Code != http.StatusOK || response.Header().Get("Cache-Control") != "no-store" {
		t.Fatal("bootstrap must return a successful non-cacheable script")
	}
	if strings.Contains(response.Body.String(), "test-only-enrollment-token") || strings.Contains(response.Body.String(), "XINGCHEN_ENROLLMENT_TOKEN") {
		t.Fatal("bootstrap must not embed enrollment credentials")
	}
	installer := `#!/usr/bin/env bash
set -euo pipefail
printf ran > "${XINGCHEN_TEST_ROOT}/executed"
[[ "${XINGCHEN_ENROLLMENT_TOKEN:-}" == test-only-enrollment-token ]] || exit 97
printf '%s\0' "$@" > "${XINGCHEN_TEST_ROOT}/arguments"
[[ "${XINGCHEN_TEST_DOWNLOAD_MODE}" != installer_failure ]] || exit 42
`
	digest := sha256.Sum256([]byte(installer))
	checksum := strings.ToUpper(hex.EncodeToString(digest[:])) + "\r\n"
	driver := `set -euo pipefail
export XINGCHEN_TEST_ROOT="$PWD"
export TMPDIR="$PWD/tmp"
curl() {
  local output='' url='' protocol='' redirect_protocol='' redirects='' tls=false
  while (($# > 0)); do
    case "$1" in
      -o) output="$2"; shift 2 ;;
      --proto) protocol="$2"; shift 2 ;;
      --proto-redir) redirect_protocol="$2"; shift 2 ;;
      --max-redirs) redirects="$2"; shift 2 ;;
      --tlsv1.2) tls=true; shift ;;
      --retry|--retry-delay|--connect-timeout|--max-time|--max-filesize) shift 2 ;;
      -fsSL) shift ;;
      https://monitor.example.com/api/setup/agent-installer?platform=linux*) url="$1"; shift ;;
      *) echo 'Unexpected mock curl argument.' >&2; return 98 ;;
    esac
  done
  [[ "$protocol" == =https && "$redirect_protocol" == =https && "$tls" == true && "$redirects" == 0 ]] || return 98
  printf '%s\n' "$url" >> "$XINGCHEN_TEST_ROOT/downloads"
  case "$url" in
    'https://monitor.example.com/api/setup/agent-installer?platform=linux')
      [[ -n "$output" ]] || return 98
      if [[ "$XINGCHEN_TEST_DOWNLOAD_MODE" == installer_partial ]]; then
        head -n 3 "$XINGCHEN_TEST_ROOT/fixture.sh" > "$output"
        return 18
      fi
      cp "$XINGCHEN_TEST_ROOT/fixture.sh" "$output"
      case "$XINGCHEN_TEST_DOWNLOAD_MODE" in
        installer_tls) return 60 ;;
        installer_handshake) return 35 ;;
      esac
      ;;
    'https://monitor.example.com/api/setup/agent-installer?platform=linux&format=sha256')
      [[ -z "$output" ]] || return 98
      case "$XINGCHEN_TEST_DOWNLOAD_MODE" in
        checksum_partial) cat "$XINGCHEN_TEST_ROOT/checksum"; return 60 ;;
        checksum_mismatch) printf '%064d' 0 ;;
        checksum_invalid) printf 'not-a-checksum' ;;
        *) cat "$XINGCHEN_TEST_ROOT/checksum" ;;
      esac
      ;;
    *) return 98 ;;
  esac
}
export -f curl
exec bash --noprofile --norc ./bootstrap.sh
`
	tests := []struct {
		name          string
		exitCode      int
		downloadCount int
		executed      bool
		messages      []string
	}{
		{"installer_partial", 18, 1, false, []string{"安装器下载失败", "curl 退出码 18"}},
		{"installer_tls", 60, 1, false, []string{"安装器下载失败", "curl 退出码 60", "系统时间", "CA", "证书链", "curl/NSS", "KeyUsage"}},
		{"installer_handshake", 35, 1, false, []string{"安装器下载失败", "curl 退出码 35", "TLS 握手失败", "SEC_ERROR_INADEQUATE_KEY_USAGE"}},
		{"checksum_partial", 60, 2, false, []string{"安装器摘要下载失败", "curl 退出码 60", "系统时间", "CA", "KeyUsage"}},
		{"checksum_mismatch", 1, 2, false, []string{"SHA256 校验失败"}},
		{"checksum_invalid", 1, 2, false, []string{"摘要格式无效"}},
		{"success", 0, 2, true, nil},
		{"installer_failure", 42, 2, true, nil},
	}
	for _, test := range tests {
		t.Run(test.name, func(t *testing.T) {
			root := t.TempDir()
			if err := os.Mkdir(filepath.Join(root, "tmp"), 0700); err != nil {
				t.Fatal(err)
			}
			for name, content := range map[string]string{"bootstrap.sh": response.Body.String(), "fixture.sh": installer, "checksum": checksum} {
				if err := os.WriteFile(filepath.Join(root, name), []byte(content), 0600); err != nil {
					t.Fatal(err)
				}
			}
			ctx, cancel := context.WithTimeout(context.Background(), 15*time.Second)
			defer cancel()
			command := exec.CommandContext(ctx, bash, "--noprofile", "--norc", "-c", driver)
			command.Dir = root
			command.Env = append(os.Environ(), "BASH_ENV=", "ENV=", "XINGCHEN_TEST_DOWNLOAD_MODE="+test.name, "XINGCHEN_ENROLLMENT_TOKEN=test-only-enrollment-token")
			output, err := command.CombinedOutput()
			exitCode := 0
			if err != nil {
				var exitError *exec.ExitError
				if !errors.As(err, &exitError) || ctx.Err() != nil {
					t.Fatalf("bootstrap did not complete: %v", err)
				}
				exitCode = exitError.ExitCode()
			}
			if exitCode != test.exitCode {
				t.Fatalf("bootstrap exit code = %d, want %d; output: %s", exitCode, test.exitCode, output)
			}
			for _, message := range test.messages {
				if !strings.Contains(string(output), message) {
					t.Errorf("bootstrap diagnostic missing %q: %s", message, output)
				}
			}
			if strings.Contains(string(output), "test-only-enrollment-token") {
				t.Error("bootstrap exposed an enrollment credential")
			}
			_, markerErr := os.Stat(filepath.Join(root, "executed"))
			if (markerErr == nil) != test.executed || (markerErr != nil && !os.IsNotExist(markerErr)) {
				t.Fatalf("installer execution marker = %v, expected execution = %t", markerErr, test.executed)
			}
			if test.executed {
				arguments, err := os.ReadFile(filepath.Join(root, "arguments"))
				if err != nil {
					t.Fatal(err)
				}
				want := []string{"--server-url", "https://monitor.example.com", "--device-id", query.Get("deviceId"), "--interval", "30s", "--disk", "/", "--disk", "/srv/data (primary)", "--disk", "/srv/a,b+archive", "--all-processes", "--process-limit", "128"}
				if string(arguments) != strings.Join(want, "\x00")+"\x00" {
					t.Fatalf("installer argument boundaries changed: %q", arguments)
				}
			}
			downloads, err := os.ReadFile(filepath.Join(root, "downloads"))
			if err != nil {
				t.Fatal(err)
			}
			if count := strings.Count(string(downloads), "\n"); count != test.downloadCount {
				t.Errorf("bootstrap performed %d downloads, want %d", count, test.downloadCount)
			}
			remaining, err := os.ReadDir(filepath.Join(root, "tmp"))
			if err != nil || len(remaining) != 0 {
				t.Fatalf("bootstrap left temporary installer files: %v, %v", remaining, err)
			}
		})
	}
}

func TestAgentBootstrapBuildsWindowsScriptFromConfiguredController(t *testing.T) {
	useAgentBootstrapFixture(t, "https://edge.example:8443")
	query := url.Values{
		"platform":    {"windows"},
		"deviceId":    {"123e4567-e89b-42d3-a456-426614174000"},
		"interval":    {"3s"},
		"disk":        {`C:\`, `D:\Data`},
		"lightweight": {"true"},
	}
	request := httptest.NewRequest(http.MethodGet, "http://setup:8090/api/setup/agent-bootstrap?"+query.Encode(), nil)
	response := httptest.NewRecorder()

	(&setupService{}).agentBootstrap(response, request)

	content := response.Body.String()
	if response.Code != http.StatusOK {
		t.Fatalf("Windows bootstrap response = %d %q", response.Code, content)
	}
	for _, expected := range []string{
		"https://edge.example:8443/api/setup/agent-installer?platform=windows",
		"Get-FileHash -LiteralPath $installer -Algorithm SHA256",
		"ServerUrl = 'https://edge.example:8443'",
		"DeviceId = '123e4567-e89b-42d3-a456-426614174000'",
		`DiskMountpoint = @('C:\', 'D:\Data')`,
		"SkipProcesses = $true",
		"SkipConnections = $true",
		"& $installer @installOptions",
	} {
		if !strings.Contains(content, expected) {
			t.Fatalf("Windows bootstrap missing %q:\n%s", expected, content)
		}
	}
	if strings.Contains(content, "ENROLLMENT_TOKEN") || strings.Contains(content, "AGENT_KEY") {
		t.Fatalf("Windows bootstrap contains a credential variable: %s", content)
	}
}

func TestAgentBootstrapRejectsUnknownDuplicateAndUnsafeOptions(t *testing.T) {
	useAgentBootstrapFixture(t, "https://monitor.example.com")
	valid := "platform=linux&deviceId=123e4567-e89b-42d3-a456-426614174000&interval=3s"
	tests := []string{
		valid + "&token=secret-value",
		valid + "&deviceId=123e4567-e89b-42d3-a456-426614174001",
		"platform=linux&deviceId=device%27%3Bcurl+evil&interval=3s",
		"platform=linux&deviceId=123e4567-e89b-42d3-a456-426614174000&interval=2s",
		valid + "&disk=%2Fdata%27%3Bcurl+evil",
		valid + "&lightweight=true&collectAllProcesses=true",
		valid + "&processLimit=128",
		valid + "&collectAllProcesses=true&processLimit=257",
		"platform=windows&deviceId=123e4567-e89b-42d3-a456-426614174000&interval=3s&disk=%2Fvar",
	}
	for _, rawQuery := range tests {
		request := httptest.NewRequest(http.MethodGet, "/api/setup/agent-bootstrap?"+rawQuery, nil)
		response := httptest.NewRecorder()
		(&setupService{}).agentBootstrap(response, request)
		if response.Code != http.StatusBadRequest {
			t.Errorf("unsafe query %q returned %d, want 400: %s", rawQuery, response.Code, response.Body.String())
		}
		if strings.Contains(response.Body.String(), "secret-value") {
			t.Fatal("bootstrap error leaked a credential value")
		}
	}
}

func TestAgentBootstrapRejectsInvalidConfiguredControllerWithoutRequestFallback(t *testing.T) {
	useAgentBootstrapFixture(t, "https://user:secret@monitor.example.com")
	request := httptest.NewRequest(http.MethodGet, "/api/setup/agent-bootstrap?platform=linux&deviceId=123e4567-e89b-42d3-a456-426614174000&interval=3s", nil)
	request.Host = "fallback.example"
	response := httptest.NewRecorder()

	(&setupService{}).agentBootstrap(response, request)

	if response.Code != http.StatusInternalServerError || strings.Contains(response.Body.String(), "secret") || strings.Contains(response.Body.String(), "fallback.example") {
		t.Fatalf("invalid configured controller response = %d %q", response.Code, response.Body.String())
	}
}

func TestAgentBootstrapRejectsMissingConfiguredControllerWithoutRequestFallback(t *testing.T) {
	useAgentBootstrapFixture(t, "")
	request := httptest.NewRequest(http.MethodGet, "http://request.example/api/setup/agent-bootstrap?platform=linux&deviceId=123e4567-e89b-42d3-a456-426614174000&interval=3s", nil)
	request.Header.Set("X-Forwarded-Proto", "https")
	request.Header.Set("X-Forwarded-Host", "forwarded.example")
	response := httptest.NewRecorder()

	(&setupService{}).agentBootstrap(response, request)

	if response.Code != http.StatusInternalServerError || strings.Contains(response.Body.String(), "request.example") || strings.Contains(response.Body.String(), "forwarded.example") {
		t.Fatalf("missing configured controller response = %d %q", response.Code, response.Body.String())
	}
}

func TestValidateAllowedOriginsRequiresPublicOrigin(t *testing.T) {
	publicURL, err := url.Parse("https://monitor.example.com")
	if err != nil {
		t.Fatal(err)
	}
	if err := validateAllowedOrigins("https://other.example.com", publicURL); err == nil {
		t.Fatal("allowed origins without the public origin were accepted")
	}
	if err := validateAllowedOrigins("https://monitor.example.com, https://127.0.0.1:18080", publicURL); err != nil {
		t.Fatalf("valid additional origin rejected: %v", err)
	}
}

func TestConfiguredEnvRequiresPostgreSQLAndApplicationSecrets(t *testing.T) {
	originalEnvPath := envPath
	envPath = filepath.Join(t.TempDir(), ".env")
	t.Cleanup(func() { envPath = originalEnvPath })

	content := "SPRING_PROFILES_ACTIVE=production\nPOSTGRES_DB=guanlan_monitor\nPOSTGRES_USER=guanlan\nPOSTGRES_PASSWORD=database-password\nBOOTSTRAP_ADMIN_USERNAME=admin\nBOOTSTRAP_ADMIN_PASSWORD=administrator-password\nSETTINGS_ENCRYPTION_KEY=key\n"
	if err := os.WriteFile(envPath, []byte(content), 0600); err != nil {
		t.Fatal(err)
	}
	if !configuredEnv() {
		t.Fatal("complete PostgreSQL configuration was not detected")
	}

	if err := os.WriteFile(envPath, []byte(strings.Replace(content, "POSTGRES_PASSWORD=database-password\n", "", 1)), 0600); err != nil {
		t.Fatal(err)
	}
	if configuredEnv() {
		t.Fatal("configuration without PostgreSQL password was accepted")
	}
}

func TestComposeApplyDoesNotRecreateSetupService(t *testing.T) {
	t.Setenv("CONTROLLER_AGENT_ENABLED", "false")
	got := strings.Join(composeApplyArgs(), " ")
	want := "compose -f " + filepath.Join(workspace, "docker-compose.yml") + " --project-directory " + hostWorkspace + " --env-file " + envPath + " up -d --no-build --pull never --no-deps --wait --wait-timeout 300 server web"
	if got != want {
		t.Fatalf("composeApplyArgs() = %q, want %q", got, want)
	}
}

func TestOfflineComposeApplyUsesOnlyPreparedImages(t *testing.T) {
	t.Setenv("CONTROLLER_AGENT_ENABLED", "false")
	t.Setenv("XINGCHEN_NETWORK_MODE", networkModeOffline)
	got := strings.Join(composeApplyArgs(), " ")
	if !strings.Contains(got, " up -d --no-build --pull never ") {
		t.Fatalf("offline composeApplyArgs() may build or pull a missing image: %q", got)
	}
	if strings.Contains(got, " --build ") {
		t.Fatalf("offline composeApplyArgs() requires source build contexts: %q", got)
	}
}

func TestComposeApplyEnablesControllerHostMonitoring(t *testing.T) {
	t.Setenv("CONTROLLER_AGENT_ENABLED", "true")
	got := strings.Join(composeApplyArgs(), " ")
	if !strings.Contains(got, "--profile host-monitoring up") {
		t.Fatalf("controller monitoring profile missing: %q", got)
	}
}

func TestSetupStatusWaitsForProductionCompletionMarker(t *testing.T) {
	originalWorkspace, originalEnvPath, originalMarkerPath := workspace, envPath, completionMarkerPath
	workspace = t.TempDir()
	envPath = filepath.Join(workspace, ".env")
	completionMarkerPath = filepath.Join(workspace, ".setup-complete")
	t.Cleanup(func() {
		workspace, envPath, completionMarkerPath = originalWorkspace, originalEnvPath, originalMarkerPath
	})

	content := "SPRING_PROFILES_ACTIVE=production\nPOSTGRES_DB=guanlan_monitor\nPOSTGRES_USER=guanlan\nPOSTGRES_PASSWORD=database-password\nBOOTSTRAP_ADMIN_USERNAME=admin\nBOOTSTRAP_ADMIN_PASSWORD=administrator-password\nSETTINGS_ENCRYPTION_KEY=key\nPUBLIC_BASE_URL=https://monitor.example.com\n"
	if err := os.WriteFile(envPath, []byte(content), 0600); err != nil {
		t.Fatal(err)
	}

	service := &setupService{applying: true}
	status := requestSetupStatus(t, service)
	if !status.Configured || status.State != "applying" {
		t.Fatalf("active setup status = %+v, want configured applying", status)
	}

	service.applying = false
	status = requestSetupStatus(t, service)
	if !status.Configured || status.State != "applying" {
		t.Fatalf("unmarked setup status = %+v, want configured applying", status)
	}

	if err := writeSetupCompletionMarker(); err != nil {
		t.Fatal(err)
	}
	status = requestSetupStatus(t, service)
	if !status.Configured || status.State != "configured" || status.BaseURL != "https://monitor.example.com" {
		t.Fatalf("completed setup status = %+v", status)
	}
}

func TestWriteEnvironmentPreservesInstallerWebListener(t *testing.T) {
	originalWorkspace, originalEnvPath := workspace, envPath
	workspace = t.TempDir()
	envPath = filepath.Join(workspace, ".env")
	t.Cleanup(func() { workspace, envPath = originalWorkspace, originalEnvPath })
	t.Setenv("POSTGRES_PASSWORD", "database-password")
	t.Setenv("WEB_PORT", "19090")
	t.Setenv("WEB_BIND_ADDRESS", "127.0.0.1")
	t.Setenv("CONTROLLER_AGENT_ENABLED", "true")
	t.Setenv("CONTROLLER_AGENT_DEVICE_ID", "controller-device-id")
	t.Setenv("CONTROLLER_AGENT_KEY", "controller-agent-key")
	if err := os.WriteFile(envPath, []byte("CONTROLLER_AUTO_UPDATE=\"true\"\nXINGCHEN_NETWORK_MODE=\"internal\"\nXINGCHEN_ALLOW_GITEE=\"false\"\nXINGCHEN_POSTGRES_IMAGE=\"registry.internal.example/postgres:16\"\nXINGCHEN_REDIS_IMAGE=\"registry.internal.example/redis:7.4\"\nXINGCHEN_SETUP_IMAGE=\"registry.internal.example/setup:v1.20.11\"\nXINGCHEN_RELEASE_MANIFEST_PATH=\"/workspace/release/manifest.json\"\nXINGCHEN_UPDATE_MIN_FREE_BYTES=\"2147483648\"\n"), 0600); err != nil {
		t.Fatal(err)
	}

	if err := writeEnvironment(validSetupRequest()); err != nil {
		t.Fatal(err)
	}
	values, err := readEnv()
	if err != nil {
		t.Fatal(err)
	}
	if values["WEB_PORT"] != "19090" || values["WEB_BIND_ADDRESS"] != "127.0.0.1" {
		t.Fatalf("listener settings were not preserved: port=%q bind=%q", values["WEB_PORT"], values["WEB_BIND_ADDRESS"])
	}
	if values["CONTROLLER_AGENT_ENABLED"] != "true" || values["CONTROLLER_AGENT_DEVICE_ID"] != "controller-device-id" || values["CONTROLLER_AGENT_KEY"] != "controller-agent-key" {
		t.Fatal("controller Agent settings were not preserved")
	}
	if values["CONTROLLER_AUTO_UPDATE"] != "true" {
		t.Fatal("controller automatic update setting was not preserved")
	}
	if values["XINGCHEN_NETWORK_MODE"] != "internal" || values["XINGCHEN_ALLOW_GITEE"] != "false" {
		t.Fatal("controller network policy settings were not preserved")
	}
	if values["XINGCHEN_SETUP_IMAGE"] != "registry.internal.example/setup:v1.20.11" || values["XINGCHEN_RELEASE_MANIFEST_PATH"] != "/workspace/release/manifest.json" {
		t.Fatal("controller release and image settings were not preserved")
	}
	if values["XINGCHEN_POSTGRES_IMAGE"] != "registry.internal.example/postgres:16" || values["XINGCHEN_REDIS_IMAGE"] != "registry.internal.example/redis:7.4" || values["XINGCHEN_UPDATE_MIN_FREE_BYTES"] != "2147483648" {
		t.Fatal("offline dependency image and update preflight settings were not preserved")
	}
	if values["COMPOSE_PROJECT_NAME"] != "xingchen-monitor" {
		t.Fatalf("default Compose project name = %q, want xingchen-monitor", values["COMPOSE_PROJECT_NAME"])
	}
}

func TestWriteEnvironmentPreservesExistingComposeProjectName(t *testing.T) {
	originalWorkspace, originalEnvPath := workspace, envPath
	workspace = t.TempDir()
	envPath = filepath.Join(workspace, ".env")
	t.Cleanup(func() { workspace, envPath = originalWorkspace, originalEnvPath })
	t.Setenv("POSTGRES_PASSWORD", "database-password")
	if err := os.WriteFile(envPath, []byte("COMPOSE_PROJECT_NAME=legacy-monitor\n"), 0600); err != nil {
		t.Fatal(err)
	}

	if err := writeEnvironment(validSetupRequest()); err != nil {
		t.Fatal(err)
	}
	values, err := readEnv()
	if err != nil {
		t.Fatal(err)
	}
	if values["COMPOSE_PROJECT_NAME"] != "legacy-monitor" {
		t.Fatalf("existing Compose project name was not preserved: %q", values["COMPOSE_PROJECT_NAME"])
	}
}

func requestSetupStatus(t *testing.T, service *setupService) setupStatus {
	t.Helper()
	request := httptest.NewRequest(http.MethodGet, "/api/setup/status", nil)
	response := httptest.NewRecorder()
	service.status(response, request)
	var status setupStatus
	if err := json.NewDecoder(response.Body).Decode(&status); err != nil {
		t.Fatal(err)
	}
	return status
}

func TestDotenvValueEscapesComposeInterpolation(t *testing.T) {
	got := dotenvValue(`pa$ss\"word`)
	want := `"pa$$ss\\\"word"`
	if got != want {
		t.Fatalf("dotenvValue() = %q, want %q", got, want)
	}
}

func TestOriginGuardAcceptsForwardedPort(t *testing.T) {
	handler := withOriginGuard(http.HandlerFunc(func(w http.ResponseWriter, _ *http.Request) {
		w.WriteHeader(http.StatusNoContent)
	}))
	request := httptest.NewRequest(http.MethodPost, "http://setup:8090/api/setup/complete", nil)
	request.Host = "111.170.155.150"
	request.Header.Set("Origin", "http://111.170.155.150:18080")
	request.Header.Set("X-Forwarded-Host", "111.170.155.150:18080")
	response := httptest.NewRecorder()
	handler.ServeHTTP(response, request)
	if response.Code != http.StatusNoContent {
		t.Fatalf("forwarded origin rejected with status %d", response.Code)
	}
}

func TestOriginGuardAcceptsForwardedPublicHost(t *testing.T) {
	handler := withOriginGuard(http.HandlerFunc(func(w http.ResponseWriter, _ *http.Request) {
		w.WriteHeader(http.StatusNoContent)
	}))
	request := httptest.NewRequest(http.MethodPost, "http://setup:8090/api/setup/complete", nil)
	request.Host = "localhost"
	request.Header.Set("Origin", "http://monitor.xciy.cn")
	request.Header.Set("X-Forwarded-Host", "monitor.xciy.cn")
	response := httptest.NewRecorder()
	handler.ServeHTTP(response, request)
	if response.Code != http.StatusNoContent {
		t.Fatalf("forwarded public host rejected with status %d", response.Code)
	}
}

func TestOriginGuardRejectsDifferentHost(t *testing.T) {
	handler := withOriginGuard(http.HandlerFunc(func(w http.ResponseWriter, _ *http.Request) {
		w.WriteHeader(http.StatusNoContent)
	}))
	request := httptest.NewRequest(http.MethodPost, "http://setup:8090/api/setup/complete", nil)
	request.Host = "monitor.example.com"
	request.Header.Set("Origin", "https://evil.example.com")
	response := httptest.NewRecorder()
	handler.ServeHTTP(response, request)
	if response.Code != http.StatusForbidden {
		t.Fatalf("different origin accepted with status %d", response.Code)
	}
}

func TestOriginMatchesHostNormalizesDefaultPort(t *testing.T) {
	origin, err := url.Parse("https://monitor.example.com")
	if err != nil || !originMatchesHost(origin, "monitor.example.com:443") {
		t.Fatal("https origin should match its default port")
	}
}
