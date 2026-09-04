package main

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"net/http"
	"strconv"
	"strings"
	"time"
)

const (
	controllerReleaseCheckTimeout = 30 * time.Second
	controllerReleaseCacheTTL     = 20 * time.Minute
	controllerGitHubAPIBase       = "https://api.github.com/repos/Pstarchen/monitor-for-server"
	controllerGiteeAPIBase        = "https://gitee.com/api/v5/repos/starchen520/monitor-for-server"
	controllerGiteeRepository     = "https://gitee.com/starchen520/monitor-for-server"
	controllerReleaseResponseSize = 2 * 1024 * 1024
)

type controllerRelease struct {
	TagName      string `json:"tag_name"`
	Name         string `json:"name"`
	Body         string `json:"body"`
	PublishedAt  string `json:"published_at"`
	HTMLURL      string `json:"html_url"`
	Source       string `json:"-"`
	Verification string `json:"-"`
}

type controllerRepositoryTag struct {
	Name    string `json:"name"`
	Message string `json:"message"`
	Commit  struct {
		SHA  string `json:"sha"`
		Date string `json:"date"`
	} `json:"commit"`
	Tagger *struct {
		Date string `json:"date"`
	} `json:"tagger"`
}

func (s *controllerUpdateService) refreshReleaseState(ctx context.Context, state *controllerUpdateState, force bool) error {
	s.decorate(state)
	release, cached, warning, err := s.latestRelease(ctx, *state, force)
	if err != nil {
		return err
	}
	latestVersion := normalizeControllerVersion(release.TagName)
	if latestVersion == "" {
		return fmt.Errorf("latest release has an invalid version tag %q", release.TagName)
	}
	state.LatestVersion = latestVersion
	state.ReleaseName = strings.TrimSpace(release.Name)
	state.ReleaseNotes = strings.TrimSpace(release.Body)
	state.ReleaseURL = strings.TrimSpace(release.HTMLURL)
	state.ReleasePublishedAt = strings.TrimSpace(release.PublishedAt)
	state.ReleaseCached = cached
	state.ReleaseWarning = warning
	state.ReleaseSource = release.Source
	state.ReleaseVerification = release.Verification
	if !cached {
		state.ReleaseFetchedAt = s.currentTime().UTC().Format(time.RFC3339)
	}

	if normalizeControllerVersion(state.CurrentVersion) == "" {
		state.CurrentVersion = ""
	}
	if state.CurrentVersion == "" && state.CurrentRevision != "" {
		version, versionErr := s.versionForRevision(ctx, state.CurrentRevision)
		if versionErr == nil {
			state.CurrentVersion = version
			state.VersionRevision = state.CurrentRevision
		} else if state.ReleaseWarning == "" {
			state.ReleaseWarning = "无法从发布标签识别当前运行版本"
		}
	}
	state.UpdateAvailable = controllerVersionLess(state.CurrentVersion, state.LatestVersion)
	return nil
}

func (s *controllerUpdateService) latestRelease(ctx context.Context, state controllerUpdateState, force bool) (controllerRelease, bool, string, error) {
	if !validNetworkMode(s.effectiveNetworkMode()) {
		return controllerRelease{}, false, "", errors.New("XINGCHEN_NETWORK_MODE 必须是 public、internal 或 offline")
	}
	if !force && s.releaseCacheFresh(state) {
		return releaseFromState(state), true, "", nil
	}
	var sourceErrors []string
	manifestConfigured := s.releases != nil && (s.releases.manifestPathRequired || len(s.releases.manifestURLs) > 0)
	if manifestConfigured {
		if release, cached, warning, err := s.manifestRelease(ctx); err == nil {
			return release, cached, warning, nil
		}
		sourceErrors = append(sourceErrors, "版本清单不可用")
	}
	if s.giteeReleaseEnabled() {
		if release, err := s.latestGiteeRelease(ctx); err == nil {
			return release, false, "", nil
		}
		sourceErrors = append(sourceErrors, "Gitee 标签 API 不可用")
	}
	if s.githubReleaseEnabled() {
		var release controllerRelease
		if err := s.githubJSON(ctx, "/releases/latest", &release); err == nil {
			release.Source = "github.com"
			release.Verification = "github-api"
			return release, false, "", nil
		}
		sourceErrors = append(sourceErrors, "GitHub API 不可用")
	}
	if s.releases != nil && !manifestConfigured {
		if release, cached, warning, err := s.manifestRelease(ctx); err == nil {
			if warning == "" && len(sourceErrors) > 0 {
				warning = "远程发布源暂时不可用，当前使用镜像内版本清单"
			}
			return release, cached, warning, nil
		}
		sourceErrors = append(sourceErrors, "版本清单不可用")
	}
	cached := releaseFromState(state)
	if normalizeControllerVersion(cached.TagName) != "" {
		return cached, true, "发布源暂时不可用，当前显示缓存结果", nil
	}
	if len(sourceErrors) == 0 {
		return controllerRelease{}, false, "", errors.New("未配置版本清单源，且 GitHub API 回退未启用")
	}
	return controllerRelease{}, false, "", errors.New(strings.Join(sourceErrors, "；"))
}

func (s *controllerUpdateService) manifestRelease(ctx context.Context) (controllerRelease, bool, string, error) {
	s.releases.mu.Lock()
	manifest, source, cached, err := s.releases.loadManifest(ctx)
	s.releases.mu.Unlock()
	if err != nil {
		return controllerRelease{}, false, "", err
	}
	warning := ""
	if cached {
		warning = "版本清单源暂时不可用，当前使用最后已知可用清单"
	}
	verification := "sha256"
	if s.releases.manifestSHA256 != "" {
		verification = "manifest-sha256"
	}
	return controllerRelease{
		TagName: manifest.Version, Name: manifest.Version, PublishedAt: manifest.PublishedAt,
		Source: source, Verification: verification,
	}, cached, warning, nil
}

func (s *controllerUpdateService) releaseCacheFresh(state controllerUpdateState) bool {
	if normalizeControllerVersion(state.LatestVersion) == "" || state.ReleaseFetchedAt == "" {
		return false
	}
	fetchedAt, err := time.Parse(time.RFC3339, state.ReleaseFetchedAt)
	if err != nil {
		return false
	}
	age := s.currentTime().UTC().Sub(fetchedAt.UTC())
	return age >= 0 && age < controllerReleaseCacheTTL
}

func releaseFromState(state controllerUpdateState) controllerRelease {
	return controllerRelease{
		TagName:      state.LatestVersion,
		Name:         state.ReleaseName,
		Body:         state.ReleaseNotes,
		PublishedAt:  state.ReleasePublishedAt,
		HTMLURL:      state.ReleaseURL,
		Source:       state.ReleaseSource,
		Verification: state.ReleaseVerification,
	}
}

func (s *controllerUpdateService) versionForRevision(ctx context.Context, revision string) (string, error) {
	var sourceErrors []string
	if s.giteeReleaseEnabled() {
		tags, err := s.giteeTags(ctx)
		if err == nil {
			if version := versionForRepositoryRevision(tags, revision); version != "" {
				return version, nil
			}
			sourceErrors = append(sourceErrors, "Gitee 标签中没有当前提交")
		} else {
			sourceErrors = append(sourceErrors, "Gitee 标签 API 不可用")
		}
	}
	if s.githubReleaseEnabled() {
		var tags []controllerRepositoryTag
		if err := s.githubJSON(ctx, "/tags?per_page=100", &tags); err == nil {
			if version := versionForRepositoryRevision(tags, revision); version != "" {
				return version, nil
			}
			sourceErrors = append(sourceErrors, "GitHub 标签中没有当前提交")
		} else {
			sourceErrors = append(sourceErrors, "GitHub API 不可用")
		}
	}
	if len(sourceErrors) == 0 {
		return "", errors.New("未启用可用的发布标签 API")
	}
	return "", errors.New(strings.Join(sourceErrors, "；"))
}

func versionForRepositoryRevision(tags []controllerRepositoryTag, revision string) string {
	matched := ""
	for _, tag := range tags {
		if !strings.EqualFold(strings.TrimSpace(tag.Commit.SHA), strings.TrimSpace(revision)) {
			continue
		}
		version := normalizeControllerVersion(tag.Name)
		if version != "" && (matched == "" || controllerVersionLess(matched, version)) {
			matched = version
		}
	}
	return matched
}

func (s *controllerUpdateService) giteeReleaseEnabled() bool {
	if !s.allowGitee {
		return false
	}
	apiBase := strings.TrimRight(strings.TrimSpace(s.giteeAPIBase), "/")
	if apiBase == "" {
		apiBase = controllerGiteeAPIBase
	}
	return networkModeAllowsURL(s.effectiveNetworkMode(), apiBase, true)
}

func (s *controllerUpdateService) latestGiteeRelease(ctx context.Context) (controllerRelease, error) {
	tags, err := s.giteeTags(ctx)
	if err != nil {
		return controllerRelease{}, err
	}
	latestVersion := ""
	var latestTag controllerRepositoryTag
	for _, tag := range tags {
		version := normalizeControllerVersion(tag.Name)
		if version == "" || (latestVersion != "" && !controllerVersionLess(latestVersion, version)) {
			continue
		}
		latestVersion = version
		latestTag = tag
	}
	if latestVersion == "" {
		return controllerRelease{}, errors.New("Gitee 标签中没有稳定版本")
	}
	publishedAt := strings.TrimSpace(latestTag.Commit.Date)
	if latestTag.Tagger != nil && strings.TrimSpace(latestTag.Tagger.Date) != "" {
		publishedAt = strings.TrimSpace(latestTag.Tagger.Date)
	}
	return controllerRelease{
		TagName:      latestVersion,
		Name:         latestVersion,
		Body:         strings.TrimSpace(latestTag.Message),
		PublishedAt:  publishedAt,
		HTMLURL:      controllerGiteeRepository + "/tree/" + latestVersion,
		Source:       "gitee.com",
		Verification: "gitee-api",
	}, nil
}

func (s *controllerUpdateService) giteeTags(ctx context.Context) ([]controllerRepositoryTag, error) {
	apiBase := strings.TrimRight(strings.TrimSpace(s.giteeAPIBase), "/")
	if apiBase == "" {
		apiBase = controllerGiteeAPIBase
	}
	var tags []controllerRepositoryTag
	if err := s.repositoryJSON(ctx, apiBase, "/tags?per_page=100&sort=updated&direction=desc", "Gitee API", true, &tags); err != nil {
		return nil, err
	}
	return tags, nil
}

func (s *controllerUpdateService) githubReleaseEnabled() bool {
	apiBase := strings.TrimRight(strings.TrimSpace(s.apiBase), "/")
	if apiBase == "" {
		apiBase = controllerGitHubAPIBase
	}
	if !networkModeAllowsURL(s.effectiveNetworkMode(), apiBase, s.allowGitee) {
		return false
	}
	return s.allowGitHubAPI || apiBase != controllerGitHubAPIBase
}

func (s *controllerUpdateService) githubJSON(ctx context.Context, path string, destination any) error {
	apiBase := strings.TrimRight(s.apiBase, "/")
	if apiBase == "" {
		apiBase = controllerGitHubAPIBase
	}
	return s.repositoryJSON(ctx, apiBase, path, "GitHub API", s.allowGitee, destination)
}

func (s *controllerUpdateService) repositoryJSON(ctx context.Context, apiBase, path, source string, allowGitee bool, destination any) error {
	if !networkModeAllowsURL(s.effectiveNetworkMode(), apiBase, allowGitee) {
		return errors.New("当前网络模式禁止访问配置的版本 API")
	}
	request, err := http.NewRequestWithContext(ctx, http.MethodGet, apiBase+path, nil)
	if err != nil {
		return err
	}
	request.Header.Set("Accept", "application/json")
	request.Header.Set("User-Agent", "xingchen-monitor-controller-updater")
	response, err := s.doRepositoryRequest(request, source)
	if err != nil {
		return err
	}
	defer response.Body.Close()
	if response.StatusCode != http.StatusOK {
		_, _ = io.Copy(io.Discard, io.LimitReader(response.Body, 4096))
		return fmt.Errorf("%s returned %s", source, response.Status)
	}
	content, err := io.ReadAll(io.LimitReader(response.Body, controllerReleaseResponseSize+1))
	if err != nil {
		return err
	}
	if len(content) > controllerReleaseResponseSize {
		return fmt.Errorf("%s response is too large", source)
	}
	if err := json.Unmarshal(content, destination); err != nil {
		return fmt.Errorf("decode %s response: %w", source, err)
	}
	return nil
}

func (s *controllerUpdateService) doRepositoryRequest(request *http.Request, source string) (*http.Response, error) {
	baseClient := s.client
	if baseClient == nil {
		baseClient = &http.Client{Timeout: controllerReleaseCheckTimeout}
	}
	client := *baseClient
	configuredRedirect := baseClient.CheckRedirect
	originScheme := request.URL.Scheme
	originHost := request.URL.Host
	client.CheckRedirect = func(next *http.Request, via []*http.Request) error {
		if len(via) >= 10 {
			return fmt.Errorf("%s redirect limit exceeded", source)
		}
		if next.URL.User != nil || !strings.EqualFold(next.URL.Scheme, originScheme) || !strings.EqualFold(next.URL.Host, originHost) {
			return fmt.Errorf("%s redirect target is outside the configured origin", source)
		}
		if configuredRedirect != nil {
			return configuredRedirect(next, via)
		}
		return nil
	}
	return client.Do(request)
}

func normalizeControllerVersion(value string) string {
	version, ok := parseControllerVersion(value)
	if !ok {
		return ""
	}
	return fmt.Sprintf("v%d.%d.%d", version[0], version[1], version[2])
}

func controllerVersionLess(left, right string) bool {
	leftVersion, leftOK := parseControllerVersion(left)
	rightVersion, rightOK := parseControllerVersion(right)
	if !leftOK || !rightOK {
		return false
	}
	for index := range leftVersion {
		if leftVersion[index] != rightVersion[index] {
			return leftVersion[index] < rightVersion[index]
		}
	}
	return false
}

func parseControllerVersion(value string) ([3]int, bool) {
	var parsed [3]int
	value = strings.TrimPrefix(strings.TrimSpace(value), "v")
	parts := strings.Split(value, ".")
	if len(parts) != len(parsed) {
		return parsed, false
	}
	for index, part := range parts {
		if part == "" || (len(part) > 1 && part[0] == '0') {
			return parsed, false
		}
		number, err := strconv.Atoi(part)
		if err != nil || number < 0 {
			return parsed, false
		}
		parsed[index] = number
	}
	return parsed, true
}
