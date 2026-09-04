package main

import (
	"net/url"
	"os"
	"strings"
)

const (
	networkModePublic   = "public"
	networkModeInternal = "internal"
	networkModeOffline  = "offline"
)

func configuredNetworkMode() string {
	return normalizeNetworkMode(os.Getenv("XINGCHEN_NETWORK_MODE"))
}

func configuredGiteeAllowed() bool {
	return strings.EqualFold(strings.TrimSpace(os.Getenv("XINGCHEN_ALLOW_GITEE")), "true")
}

func normalizeNetworkMode(mode string) string {
	mode = strings.ToLower(strings.TrimSpace(mode))
	if mode == "" {
		return networkModePublic
	}
	return mode
}

func validNetworkMode(mode string) bool {
	switch normalizeNetworkMode(mode) {
	case networkModePublic, networkModeInternal, networkModeOffline:
		return true
	default:
		return false
	}
}

func networkModeAllowsURL(mode, rawURL string, allowGitee bool) bool {
	mode = normalizeNetworkMode(mode)
	if mode == networkModeOffline || !validNetworkMode(mode) {
		return false
	}
	parsed, err := url.Parse(rawURL)
	if err == nil && parsed.Hostname() != "" && hostMatches(parsed.Hostname(), "gitee.com") && !allowGitee {
		return false
	}
	if mode == networkModePublic {
		return true
	}
	if err != nil || !strings.EqualFold(parsed.Scheme, "https") || parsed.User != nil || parsed.Hostname() == "" {
		return false
	}
	host := normalizeNetworkHost(parsed.Hostname())
	if forbiddenPublicHost(host) {
		return false
	}
	return true
}

func networkModeAllowsRegistry(mode, reference string, allowGitee bool) bool {
	mode = normalizeNetworkMode(mode)
	if mode == networkModeOffline {
		// Offline references are identifiers for images already present locally;
		// callers must still ensure no pull is attempted.
		return true
	}
	if !validNetworkMode(mode) {
		return false
	}
	host := registryHost(reference)
	if host != "" && hostMatches(host, "gitee.com") && !allowGitee {
		return false
	}
	if mode == networkModePublic {
		return true
	}
	if host == "" || forbiddenPublicHost(host) {
		return false
	}
	return true
}

func registryHost(reference string) string {
	reference = strings.TrimSpace(reference)
	if reference == "" {
		return ""
	}
	first, _, hasPath := strings.Cut(reference, "/")
	if !hasPath || (!strings.Contains(first, ".") && !strings.Contains(first, ":") && first != "localhost") {
		return ""
	}
	return normalizeNetworkHost(strings.SplitN(first, ":", 2)[0])
}

func forbiddenPublicHost(host string) bool {
	host = normalizeNetworkHost(host)
	return hostMatches(host, "github.com") ||
		hostMatches(host, "githubusercontent.com") ||
		hostMatches(host, "githubassets.com") ||
		hostMatches(host, "ghcr.io") ||
		hostMatches(host, "docker.io") ||
		hostMatches(host, "docker.com")
}

func hostMatches(host, suffix string) bool {
	host = normalizeNetworkHost(host)
	suffix = normalizeNetworkHost(suffix)
	return host == suffix || strings.HasSuffix(host, "."+suffix)
}

func normalizeNetworkHost(host string) string {
	return strings.TrimSuffix(strings.ToLower(strings.TrimSpace(host)), ".")
}
