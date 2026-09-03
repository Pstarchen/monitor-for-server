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
	Name   string `json:"name"`
	Commit struct {
		SHA string `json:"sha"`
	} `json:"commit"`
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
	if !force && s.releaseCacheFresh(state) {
		return releaseFromState(state), true, "", nil
	}
	var sourceErrors []string
	if s.releases != nil {
		s.releases.mu.Lock()
		manifest, source, cached, err := s.releases.loadManifest(ctx)
		s.releases.mu.Unlock()
		if err == nil {
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
		sourceErrors = append(sourceErrors, "版本清单不可用")
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
	cached := releaseFromState(state)
	if normalizeControllerVersion(cached.TagName) != "" {
		return cached, true, "发布源暂时不可用，当前显示缓存结果", nil
	}
	if len(sourceErrors) == 0 {
		return controllerRelease{}, false, "", errors.New("未配置版本清单源，且 GitHub API 回退未启用")
	}
	return controllerRelease{}, false, "", errors.New(strings.Join(sourceErrors, "；"))
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
	if !s.githubReleaseEnabled() {
		return "", errors.New("GitHub API 回退未启用")
	}
	var tags []controllerRepositoryTag
	if err := s.githubJSON(ctx, "/tags?per_page=100", &tags); err != nil {
		return "", err
	}
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
	if matched == "" {
		return "", fmt.Errorf("no release tag found for revision %s", revision)
	}
	return matched, nil
}

func (s *controllerUpdateService) githubReleaseEnabled() bool {
	return s.allowGitHubAPI || (strings.TrimSpace(s.apiBase) != "" && strings.TrimRight(s.apiBase, "/") != controllerGitHubAPIBase)
}

func (s *controllerUpdateService) githubJSON(ctx context.Context, path string, destination any) error {
	apiBase := strings.TrimRight(s.apiBase, "/")
	if apiBase == "" {
		apiBase = controllerGitHubAPIBase
	}
	request, err := http.NewRequestWithContext(ctx, http.MethodGet, apiBase+path, nil)
	if err != nil {
		return err
	}
	request.Header.Set("Accept", "application/vnd.github+json")
	request.Header.Set("User-Agent", "xingchen-monitor-controller-updater")
	response, err := s.doGitHubRequest(request)
	if err != nil {
		return err
	}
	defer response.Body.Close()
	if response.StatusCode != http.StatusOK {
		_, _ = io.Copy(io.Discard, io.LimitReader(response.Body, 4096))
		return fmt.Errorf("GitHub API returned %s", response.Status)
	}
	content, err := io.ReadAll(io.LimitReader(response.Body, controllerReleaseResponseSize+1))
	if err != nil {
		return err
	}
	if len(content) > controllerReleaseResponseSize {
		return errors.New("GitHub API response is too large")
	}
	if err := json.Unmarshal(content, destination); err != nil {
		return fmt.Errorf("decode GitHub API response: %w", err)
	}
	return nil
}

func (s *controllerUpdateService) doGitHubRequest(request *http.Request) (*http.Response, error) {
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
			return errors.New("GitHub API redirect limit exceeded")
		}
		if next.URL.User != nil || !strings.EqualFold(next.URL.Scheme, originScheme) || !strings.EqualFold(next.URL.Host, originHost) {
			return errors.New("GitHub API redirect target is outside the configured origin")
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
		if part == "" {
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
