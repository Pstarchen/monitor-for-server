package main

import (
	"context"
	"crypto/sha256"
	"encoding/base64"
	"encoding/hex"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"net/http"
	"net/url"
	"os"
	"path/filepath"
	"regexp"
	"strconv"
	"strings"
	"sync"
	"time"
)

const (
	agentManifestSchemaVersion = 1
	agentManifestMaxSize       = 1024 * 1024
	agentArtifactMaxSize       = int64(512 * 1024 * 1024)
	agentReleaseRequestTimeout = 30 * time.Second
)

var (
	agentAssetFilePattern = regexp.MustCompile(`^[A-Za-z0-9][A-Za-z0-9._-]{0,199}$`)
	sha256Pattern         = regexp.MustCompile(`^[a-fA-F0-9]{64}$`)
)

type agentReleaseManifest struct {
	SchemaVersion               int                 `json:"schemaVersion"`
	Version                     string              `json:"version"`
	PublishedAt                 string              `json:"publishedAt"`
	MinimumCompatibleController string              `json:"minimumCompatibleControllerVersion"`
	Assets                      []agentReleaseAsset `json:"assets"`
}

type agentReleaseAsset struct {
	OS     string `json:"os"`
	Arch   string `json:"arch"`
	File   string `json:"file"`
	URL    string `json:"url,omitempty"`
	SHA256 string `json:"sha256"`
	Size   int64  `json:"size"`
}

type cachedAgentManifest struct {
	ManifestBase64 string               `json:"manifestBase64"`
	Source         string               `json:"source"`
	FetchedAt      string               `json:"fetchedAt"`
	decoded        agentReleaseManifest `json:"-"`
}

type agentReleaseSelection struct {
	Version                     string `json:"version"`
	PublishedAt                 string `json:"publishedAt"`
	MinimumCompatibleController string `json:"minimumCompatibleControllerVersion"`
	OS                          string `json:"os"`
	Arch                        string `json:"arch"`
	File                        string `json:"file"`
	SHA256                      string `json:"sha256"`
	Size                        int64  `json:"size"`
	ArtifactURL                 string `json:"artifactUrl"`
	Source                      string `json:"source"`
	Cached                      bool   `json:"cached"`
	Verification                string `json:"verification"`
}

type agentReleaseService struct {
	mu                   sync.Mutex
	client               *http.Client
	controllerVersion    func() string
	manifestPath         string
	manifestPathRequired bool
	manifestURLs         []string
	artifactBaseURLs     []string
	offlineDir           string
	cacheDir             string
	manifestSHA256       string
}

func newAgentReleaseService() *agentReleaseService {
	configuredManifestPath := strings.TrimSpace(os.Getenv("XINGCHEN_RELEASE_MANIFEST_PATH"))
	manifestPath := configuredManifestPath
	if manifestPath == "" {
		manifestPath = filepath.Join(workspace, "release", "manifest.json")
	}
	cacheDir := strings.TrimSpace(os.Getenv("XINGCHEN_AGENT_CACHE_DIR"))
	if cacheDir == "" {
		cacheDir = filepath.Join(workspace, ".cache", "agent-release")
	}
	offlineDir := strings.TrimSpace(os.Getenv("XINGCHEN_AGENT_OFFLINE_DIR"))
	if offlineDir == "" {
		offlineDir = filepath.Join(workspace, "release", "assets")
	}
	return &agentReleaseService{
		client:               &http.Client{Timeout: agentReleaseRequestTimeout},
		controllerVersion:    currentControllerVersion,
		manifestPath:         filepath.Clean(manifestPath),
		manifestPathRequired: configuredManifestPath != "",
		manifestURLs:         splitReleaseSources(os.Getenv("XINGCHEN_RELEASE_MANIFEST_URLS")),
		artifactBaseURLs:     splitReleaseSources(os.Getenv("XINGCHEN_AGENT_RELEASE_BASE_URLS")),
		offlineDir:           filepath.Clean(offlineDir),
		cacheDir:             filepath.Clean(cacheDir),
		manifestSHA256:       strings.ToLower(strings.TrimSpace(os.Getenv("XINGCHEN_RELEASE_MANIFEST_SHA256"))),
	}
}

func (s *agentReleaseService) register(mux *http.ServeMux) {
	mux.HandleFunc("/api/setup/agent-release", s.release)
	mux.HandleFunc("/api/setup/agent-artifact", s.artifact)
}

func (s *agentReleaseService) release(w http.ResponseWriter, r *http.Request) {
	if r.Method != http.MethodGet {
		methodNotAllowed(w, http.MethodGet)
		return
	}
	osName, arch, err := agentPlatform(r)
	if err != nil {
		writeError(w, http.StatusBadRequest, err.Error())
		return
	}
	s.mu.Lock()
	manifest, source, cached, err := s.loadManifest(r.Context())
	s.mu.Unlock()
	if err != nil {
		writeError(w, http.StatusBadGateway, "Agent 版本清单不可用："+err.Error())
		return
	}
	if err := s.ensureControllerCompatible(manifest); err != nil {
		writeError(w, http.StatusConflict, err.Error())
		return
	}
	asset, err := selectAgentAsset(manifest, osName, arch)
	if err != nil {
		writeError(w, http.StatusNotFound, err.Error())
		return
	}
	w.Header().Set("Cache-Control", "no-store")
	writeJSON(w, http.StatusOK, releaseSelection(manifest, asset, source, cached))
}

func (s *agentReleaseService) artifact(w http.ResponseWriter, r *http.Request) {
	if r.Method != http.MethodGet {
		methodNotAllowed(w, http.MethodGet)
		return
	}
	osName, arch, err := agentPlatform(r)
	if err != nil {
		writeError(w, http.StatusBadRequest, err.Error())
		return
	}
	requestedVersion := normalizeControllerVersion(r.URL.Query().Get("version"))
	if requestedVersion == "" {
		writeError(w, http.StatusBadRequest, "version 必须是稳定语义版本，例如 v1.20.11")
		return
	}

	s.mu.Lock()
	manifest, manifestSource, _, err := s.loadManifest(r.Context())
	if err == nil {
		err = s.ensureControllerCompatible(manifest)
	}
	if err == nil && manifest.Version != requestedVersion {
		err = fmt.Errorf("请求版本 %s 不在当前受信清单中", requestedVersion)
	}
	var asset agentReleaseAsset
	if err == nil {
		asset, err = selectAgentAsset(manifest, osName, arch)
	}
	var path, source string
	var cached bool
	if err == nil {
		path, source, cached, err = s.resolveArtifact(r.Context(), manifest, asset, manifestSource)
	}
	s.mu.Unlock()
	if err != nil {
		status := http.StatusBadGateway
		if errors.Is(err, errIncompatibleAgentRelease) {
			status = http.StatusConflict
		}
		writeError(w, status, "Agent 制品不可用："+err.Error())
		return
	}

	file, err := os.Open(path)
	if err != nil {
		writeError(w, http.StatusInternalServerError, "已校验的 Agent 制品无法读取")
		return
	}
	defer file.Close()
	info, err := file.Stat()
	if err != nil {
		writeError(w, http.StatusInternalServerError, "已校验的 Agent 制品状态无法读取")
		return
	}
	w.Header().Set("Content-Type", "application/octet-stream")
	w.Header().Set("Content-Disposition", fmt.Sprintf("attachment; filename=%q", asset.File))
	w.Header().Set("X-Content-Type-Options", "nosniff")
	w.Header().Set("X-Xingchen-Artifact-SHA256", strings.ToLower(asset.SHA256))
	w.Header().Set("X-Xingchen-Artifact-Source", source)
	w.Header().Set("X-Xingchen-Artifact-Cached", strconv.FormatBool(cached))
	w.Header().Set("Cache-Control", "private, max-age=300")
	http.ServeContent(w, r, asset.File, info.ModTime(), file)
}

var errIncompatibleAgentRelease = errors.New("Agent 版本要求更高版本的总控")

func currentControllerVersion() string {
	_, _, version, _ := inspectControllerImages()
	return selectControllerVersion(version, configuredEnvironmentValue("XINGCHEN_TARGET_VERSION"))
}

func selectControllerVersion(running, configured string) string {
	if version := normalizeControllerVersion(running); version != "" {
		return version
	}
	return normalizeControllerVersion(configured)
}

func (s *agentReleaseService) ensureControllerCompatible(manifest agentReleaseManifest) error {
	if s.controllerVersion == nil {
		return nil
	}
	current := normalizeControllerVersion(s.controllerVersion())
	minimum := normalizeControllerVersion(manifest.MinimumCompatibleController)
	if minimum == "" {
		return nil
	}
	if current == "" {
		return fmt.Errorf("%w：无法确认当前总控版本，最低要求 %s", errIncompatibleAgentRelease, minimum)
	}
	if controllerVersionLess(current, minimum) {
		return fmt.Errorf("%w：当前 %s，最低要求 %s", errIncompatibleAgentRelease, current, minimum)
	}
	return nil
}

func agentPlatform(r *http.Request) (string, string, error) {
	osName := strings.ToLower(strings.TrimSpace(r.URL.Query().Get("os")))
	arch := strings.ToLower(strings.TrimSpace(r.URL.Query().Get("arch")))
	if osName != "linux" && osName != "windows" {
		return "", "", errors.New("os 必须是 linux 或 windows")
	}
	if arch != "amd64" && arch != "arm64" {
		return "", "", errors.New("arch 必须是 amd64 或 arm64")
	}
	return osName, arch, nil
}

func releaseSelection(manifest agentReleaseManifest, asset agentReleaseAsset, source string, cached bool) agentReleaseSelection {
	query := url.Values{"os": {asset.OS}, "arch": {asset.Arch}, "version": {manifest.Version}}
	return agentReleaseSelection{
		Version:                     manifest.Version,
		PublishedAt:                 manifest.PublishedAt,
		MinimumCompatibleController: manifest.MinimumCompatibleController,
		OS:                          asset.OS,
		Arch:                        asset.Arch,
		File:                        asset.File,
		SHA256:                      strings.ToLower(asset.SHA256),
		Size:                        asset.Size,
		ArtifactURL:                 "/api/setup/agent-artifact?" + query.Encode(),
		Source:                      source,
		Cached:                      cached,
		Verification:                "sha256",
	}
}

func (s *agentReleaseService) loadManifest(ctx context.Context) (agentReleaseManifest, string, bool, error) {
	if content, err := os.ReadFile(s.manifestPath); err == nil {
		manifest, validationErr := s.decodeManifest(content)
		if validationErr != nil {
			return agentReleaseManifest{}, "", false, fmt.Errorf("本地清单无效: %w", validationErr)
		}
		return manifest, "local", false, nil
	} else if s.manifestPathRequired || !errors.Is(err, os.ErrNotExist) {
		return agentReleaseManifest{}, "", false, fmt.Errorf("读取本地清单: %w", err)
	}

	var failures []string
	for _, sourceURL := range s.manifestURLs {
		if err := validateHTTPSURL(sourceURL); err != nil {
			failures = append(failures, "清单源配置无效")
			continue
		}
		content, err := s.downloadBytes(ctx, sourceURL, agentManifestMaxSize)
		if err != nil {
			failures = append(failures, sourceLabel(sourceURL)+": "+safeUpstreamError(err))
			continue
		}
		manifest, err := s.decodeManifest(content)
		if err != nil {
			failures = append(failures, sourceLabel(sourceURL)+": "+err.Error())
			continue
		}
		cached := cachedAgentManifest{ManifestBase64: base64.StdEncoding.EncodeToString(content), Source: sourceLabel(sourceURL), FetchedAt: time.Now().UTC().Format(time.RFC3339)}
		if err := s.writeManifestCache(cached); err != nil {
			return agentReleaseManifest{}, "", false, fmt.Errorf("保存最后已知可用清单: %w", err)
		}
		return manifest, cached.Source, false, nil
	}

	cached, err := s.readManifestCache()
	if err == nil {
		return cached.decoded, cached.Source, true, nil
	}
	if len(failures) == 0 {
		return agentReleaseManifest{}, "", false, errors.New("未配置可用清单源，且没有最后已知可用缓存")
	}
	return agentReleaseManifest{}, "", false, fmt.Errorf("所有清单源均失败（%s），且没有最后已知可用缓存", strings.Join(failures, "; "))
}

func (s *agentReleaseService) decodeManifest(content []byte) (agentReleaseManifest, error) {
	if s.manifestSHA256 != "" {
		if !sha256Pattern.MatchString(s.manifestSHA256) {
			return agentReleaseManifest{}, errors.New("XINGCHEN_RELEASE_MANIFEST_SHA256 必须是 64 位十六进制")
		}
		actual := sha256.Sum256(content)
		if hex.EncodeToString(actual[:]) != s.manifestSHA256 {
			return agentReleaseManifest{}, errors.New("版本清单 SHA256 与预置信任摘要不匹配")
		}
	}
	return decodeAgentManifest(content)
}

func decodeAgentManifest(content []byte) (agentReleaseManifest, error) {
	if len(content) == 0 || len(content) > agentManifestMaxSize {
		return agentReleaseManifest{}, errors.New("清单为空或超过大小限制")
	}
	decoder := json.NewDecoder(strings.NewReader(string(content)))
	decoder.DisallowUnknownFields()
	var manifest agentReleaseManifest
	if err := decoder.Decode(&manifest); err != nil {
		return agentReleaseManifest{}, fmt.Errorf("解析清单: %w", err)
	}
	if decoder.Decode(&struct{}{}) != io.EOF {
		return agentReleaseManifest{}, errors.New("清单包含额外 JSON 内容")
	}
	if err := validateAgentManifest(manifest); err != nil {
		return agentReleaseManifest{}, err
	}
	manifest.Version = normalizeControllerVersion(manifest.Version)
	manifest.MinimumCompatibleController = normalizeControllerVersion(manifest.MinimumCompatibleController)
	for index := range manifest.Assets {
		manifest.Assets[index].OS = strings.ToLower(manifest.Assets[index].OS)
		manifest.Assets[index].Arch = strings.ToLower(manifest.Assets[index].Arch)
		manifest.Assets[index].SHA256 = strings.ToLower(manifest.Assets[index].SHA256)
	}
	return manifest, nil
}

func validateAgentManifest(manifest agentReleaseManifest) error {
	if manifest.SchemaVersion != agentManifestSchemaVersion {
		return fmt.Errorf("不支持的 schemaVersion %d", manifest.SchemaVersion)
	}
	if normalizeControllerVersion(manifest.Version) == "" {
		return errors.New("清单版本必须是稳定语义版本")
	}
	if normalizeControllerVersion(manifest.MinimumCompatibleController) == "" {
		return errors.New("最低兼容总控版本必须是稳定语义版本")
	}
	if _, err := time.Parse(time.RFC3339, manifest.PublishedAt); err != nil {
		return errors.New("publishedAt 必须是 RFC3339 时间")
	}
	if len(manifest.Assets) == 0 || len(manifest.Assets) > 16 {
		return errors.New("清单必须包含 1 到 16 个制品")
	}
	seen := make(map[string]bool, len(manifest.Assets))
	for _, asset := range manifest.Assets {
		osName := strings.ToLower(strings.TrimSpace(asset.OS))
		arch := strings.ToLower(strings.TrimSpace(asset.Arch))
		if osName != "linux" && osName != "windows" {
			return fmt.Errorf("制品 %q 的操作系统无效", asset.File)
		}
		if arch != "amd64" && arch != "arm64" {
			return fmt.Errorf("制品 %q 的架构无效", asset.File)
		}
		if !agentAssetFilePattern.MatchString(asset.File) || asset.File == "." || asset.File == ".." {
			return fmt.Errorf("制品文件名 %q 无效", asset.File)
		}
		if !sha256Pattern.MatchString(asset.SHA256) {
			return fmt.Errorf("制品 %q 的 SHA256 无效", asset.File)
		}
		if asset.Size <= 0 || asset.Size > agentArtifactMaxSize {
			return fmt.Errorf("制品 %q 的大小无效", asset.File)
		}
		key := osName + "/" + arch
		if seen[key] {
			return fmt.Errorf("平台 %s 存在重复制品", key)
		}
		seen[key] = true
	}
	return nil
}

func selectAgentAsset(manifest agentReleaseManifest, osName, arch string) (agentReleaseAsset, error) {
	for _, asset := range manifest.Assets {
		if asset.OS == osName && asset.Arch == arch {
			return asset, nil
		}
	}
	return agentReleaseAsset{}, fmt.Errorf("Agent %s/%s 制品未发布", osName, arch)
}

func (s *agentReleaseService) resolveArtifact(ctx context.Context, manifest agentReleaseManifest, asset agentReleaseAsset, manifestSource string) (string, string, bool, error) {
	localPath := filepath.Join(s.offlineDir, asset.File)
	if fileMatchesAsset(localPath, asset) {
		return localPath, "local", false, nil
	}
	cachePath := filepath.Join(s.cacheDir, "artifacts", manifest.Version, asset.File)
	if fileMatchesAsset(cachePath, asset) {
		return cachePath, "cache", true, nil
	}

	if err := os.MkdirAll(filepath.Dir(cachePath), 0700); err != nil {
		return "", "", false, fmt.Errorf("创建制品缓存目录: %w", err)
	}
	candidates := s.artifactCandidates(manifest.Version, asset)
	var failures []string
	for _, candidate := range candidates {
		temporary, err := os.CreateTemp(filepath.Dir(cachePath), ".artifact-*")
		if err != nil {
			return "", "", false, fmt.Errorf("创建制品临时文件: %w", err)
		}
		temporaryName := temporary.Name()
		if chmodErr := temporary.Chmod(0600); chmodErr != nil {
			err = chmodErr
		} else {
			err = s.downloadArtifact(ctx, candidate, temporary, asset)
		}
		closeErr := temporary.Close()
		if err == nil {
			err = closeErr
		}
		if err == nil {
			err = os.Rename(temporaryName, cachePath)
		}
		if err == nil {
			return cachePath, sourceLabel(candidate), false, nil
		}
		_ = os.Remove(temporaryName)
		failures = append(failures, sourceLabel(candidate)+": "+safeUpstreamError(err))
	}
	if len(candidates) == 0 {
		return "", "", false, fmt.Errorf("清单来自 %s，但未配置制品源且本地/缓存均无制品", manifestSource)
	}
	return "", "", false, fmt.Errorf("所有制品源均失败（%s）", strings.Join(failures, "; "))
}

func (s *agentReleaseService) artifactCandidates(version string, asset agentReleaseAsset) []string {
	result := make([]string, 0, len(s.artifactBaseURLs)+1)
	seen := map[string]bool{}
	if asset.URL != "" && artifactURLAllowed(asset.URL, s.artifactBaseURLs) {
		result = append(result, asset.URL)
		seen[asset.URL] = true
	}
	for _, base := range s.artifactBaseURLs {
		if validateHTTPSURL(base) != nil {
			continue
		}
		candidate := strings.TrimRight(base, "/") + "/" + url.PathEscape(version) + "/" + url.PathEscape(asset.File)
		if !seen[candidate] {
			result = append(result, candidate)
			seen[candidate] = true
		}
	}
	return result
}

func artifactURLAllowed(candidate string, bases []string) bool {
	parsedCandidate, err := url.Parse(candidate)
	if err != nil || parsedCandidate.Scheme != "https" || parsedCandidate.User != nil || parsedCandidate.Fragment != "" {
		return false
	}
	for _, base := range bases {
		parsedBase, err := url.Parse(strings.TrimRight(base, "/") + "/")
		if err != nil || parsedBase.Scheme != "https" || !strings.EqualFold(parsedCandidate.Host, parsedBase.Host) {
			continue
		}
		if strings.HasPrefix(parsedCandidate.EscapedPath(), parsedBase.EscapedPath()) {
			return true
		}
	}
	return false
}

func (s *agentReleaseService) downloadBytes(ctx context.Context, sourceURL string, limit int64) ([]byte, error) {
	request, err := http.NewRequestWithContext(ctx, http.MethodGet, sourceURL, nil)
	if err != nil {
		return nil, err
	}
	request.Header.Set("User-Agent", "xingchen-agent-release-service")
	origin := request.URL
	response, err := s.doRequest(request, func(target *url.URL) bool {
		return validateHTTPSURL(target.String()) == nil && strings.EqualFold(target.Host, origin.Host)
	})
	if err != nil {
		return nil, err
	}
	defer response.Body.Close()
	if response.StatusCode != http.StatusOK {
		_, _ = io.Copy(io.Discard, io.LimitReader(response.Body, 4096))
		return nil, fmt.Errorf("上游返回 %s", response.Status)
	}
	content, err := io.ReadAll(io.LimitReader(response.Body, limit+1))
	if err != nil {
		return nil, err
	}
	if int64(len(content)) > limit {
		return nil, errors.New("上游响应超过大小限制")
	}
	return content, nil
}

func (s *agentReleaseService) downloadArtifact(ctx context.Context, sourceURL string, destination io.Writer, asset agentReleaseAsset) error {
	request, err := http.NewRequestWithContext(ctx, http.MethodGet, sourceURL, nil)
	if err != nil {
		return err
	}
	request.Header.Set("User-Agent", "xingchen-agent-release-service")
	response, err := s.doRequest(request, func(target *url.URL) bool {
		return artifactURLAllowed(target.String(), s.artifactBaseURLs)
	})
	if err != nil {
		return err
	}
	defer response.Body.Close()
	if response.StatusCode != http.StatusOK {
		_, _ = io.Copy(io.Discard, io.LimitReader(response.Body, 4096))
		return fmt.Errorf("上游返回 %s", response.Status)
	}
	if response.ContentLength >= 0 && response.ContentLength != asset.Size {
		return fmt.Errorf("文件大小不符: 期望 %d，得到 %d", asset.Size, response.ContentLength)
	}
	hash := sha256.New()
	written, err := io.Copy(io.MultiWriter(destination, hash), io.LimitReader(response.Body, asset.Size+1))
	if err != nil {
		return err
	}
	if written != asset.Size {
		return fmt.Errorf("文件大小不符: 期望 %d，得到 %d", asset.Size, written)
	}
	if actual := hex.EncodeToString(hash.Sum(nil)); !strings.EqualFold(actual, asset.SHA256) {
		return errors.New("SHA256 完整性校验失败")
	}
	return nil
}

func (s *agentReleaseService) doRequest(request *http.Request, redirectAllowed func(*url.URL) bool) (*http.Response, error) {
	baseClient := s.client
	if baseClient == nil {
		baseClient = http.DefaultClient
	}
	client := *baseClient
	configuredRedirect := baseClient.CheckRedirect
	client.CheckRedirect = func(next *http.Request, via []*http.Request) error {
		if len(via) >= 10 {
			return errors.New("上游重定向次数过多")
		}
		if !redirectAllowed(next.URL) {
			return errors.New("上游重定向目标不在受信源范围内")
		}
		if configuredRedirect != nil {
			return configuredRedirect(next, via)
		}
		return nil
	}
	return client.Do(request)
}

func fileMatchesAsset(path string, asset agentReleaseAsset) bool {
	info, err := os.Stat(path)
	if err != nil || !info.Mode().IsRegular() || info.Size() != asset.Size {
		return false
	}
	file, err := os.Open(path)
	if err != nil {
		return false
	}
	defer file.Close()
	hash := sha256.New()
	if _, err := io.Copy(hash, file); err != nil {
		return false
	}
	return strings.EqualFold(hex.EncodeToString(hash.Sum(nil)), asset.SHA256)
}

func (s *agentReleaseService) writeManifestCache(value cachedAgentManifest) error {
	if err := os.MkdirAll(s.cacheDir, 0700); err != nil {
		return err
	}
	content, err := json.MarshalIndent(value, "", "  ")
	if err != nil {
		return err
	}
	temporary, err := os.CreateTemp(s.cacheDir, ".manifest-*")
	if err != nil {
		return err
	}
	temporaryName := temporary.Name()
	defer os.Remove(temporaryName)
	if err := temporary.Chmod(0600); err != nil {
		temporary.Close()
		return err
	}
	if _, err := temporary.Write(append(content, '\n')); err != nil {
		temporary.Close()
		return err
	}
	if err := temporary.Close(); err != nil {
		return err
	}
	return os.Rename(temporaryName, filepath.Join(s.cacheDir, "manifest.json"))
}

func (s *agentReleaseService) readManifestCache() (cachedAgentManifest, error) {
	content, err := os.ReadFile(filepath.Join(s.cacheDir, "manifest.json"))
	if err != nil {
		return cachedAgentManifest{}, err
	}
	var cached cachedAgentManifest
	decoder := json.NewDecoder(strings.NewReader(string(content)))
	decoder.DisallowUnknownFields()
	if err := decoder.Decode(&cached); err != nil {
		return cachedAgentManifest{}, err
	}
	manifest, err := base64.StdEncoding.DecodeString(cached.ManifestBase64)
	if err != nil {
		return cachedAgentManifest{}, err
	}
	cached.decoded, err = s.decodeManifest(manifest)
	if err != nil {
		return cachedAgentManifest{}, err
	}
	if strings.TrimSpace(cached.Source) == "" {
		return cachedAgentManifest{}, errors.New("缓存清单缺少来源")
	}
	if _, err := time.Parse(time.RFC3339, cached.FetchedAt); err != nil {
		return cachedAgentManifest{}, errors.New("缓存清单时间无效")
	}
	return cached, nil
}

func validateHTTPSURL(value string) error {
	parsed, err := url.Parse(value)
	if err != nil || parsed.Scheme != "https" || parsed.Host == "" || parsed.User != nil || parsed.Fragment != "" {
		return errors.New("必须是无凭据、无片段的 HTTPS URL")
	}
	return nil
}

func sourceLabel(value string) string {
	parsed, err := url.Parse(value)
	if err != nil || parsed.Hostname() == "" {
		return "configured-source"
	}
	return strings.ToLower(parsed.Hostname())
}

func safeUpstreamError(err error) string {
	if errors.Is(err, context.DeadlineExceeded) {
		return "请求超时"
	}
	message := err.Error()
	for _, safe := range []string{"上游返回 ", "文件大小不符", "SHA256 完整性校验失败", "上游响应超过大小限制"} {
		if strings.HasPrefix(message, safe) {
			return message
		}
	}
	return "请求失败"
}

func splitReleaseSources(value string) []string {
	parts := strings.Split(value, ",")
	result := make([]string, 0, len(parts))
	for _, part := range parts {
		if trimmed := strings.TrimSpace(part); trimmed != "" {
			result = append(result, strings.TrimRight(trimmed, "/"))
		}
	}
	return result
}
