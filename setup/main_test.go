package main

import "testing"

func validSetupRequest() setupRequest {
	return setupRequest{
		MySQLAdminHost: "host.docker.internal", MySQLAdminPort: 3306, MySQLAdminUsername: "root", MySQLAdminPassword: "admin-password",
		MySQLAppHost: "host.docker.internal", MySQLAppPort: 3306, DatabaseName: "monitor", AppUsername: "monitor", AppPassword: "application-password", AppPasswordConfirm: "application-password",
		PublicBaseURL: "https://monitor.example.com", AllowedOrigins: "https://monitor.example.com", SiteName: "观澜监控", Timezone: "Asia/Shanghai", WebPort: 18080, WebBindAddress: "127.0.0.1",
		AdminUsername: "admin", AdminPassword: "administrator-password", AdminPasswordConfirm: "administrator-password",
	}
}

func TestValidateSetupRequest(t *testing.T) {
	if err := validateSetupRequest(validSetupRequest()); err != nil {
		t.Fatalf("valid setup request rejected: %v", err)
	}

	request := validSetupRequest()
	request.DatabaseName = "monitor-prod;drop"
	if err := validateSetupRequest(request); err == nil {
		t.Fatal("unsafe database identifier was accepted")
	}
}

func TestDotenvValueEscapesComposeInterpolation(t *testing.T) {
	got := dotenvValue(`pa$ss\"word`)
	want := `"pa$$ss\\\"word"`
	if got != want {
		t.Fatalf("dotenvValue() = %q, want %q", got, want)
	}
}
