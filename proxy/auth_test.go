package main

import (
	"path/filepath"
	"testing"
)

func TestAuthSetVerify(t *testing.T) {
	a, err := NewAuth(filepath.Join(t.TempDir(), "secrets.json"))
	if err != nil {
		t.Fatal(err)
	}
	if a.IsSet() {
		t.Fatal("fresh auth should not be set")
	}
	if err := a.Set("", "hunter2"); err != nil {
		t.Fatal(err)
	}
	if !a.IsSet() {
		t.Fatal("set should make IsSet true")
	}
	if !a.Verify("hunter2") {
		t.Fatal("right password should verify")
	}
	if a.Verify("wrong") {
		t.Fatal("wrong password verified")
	}
}

func TestAuthChangeRequiresCurrent(t *testing.T) {
	a, _ := NewAuth(filepath.Join(t.TempDir(), "secrets.json"))
	_ = a.Set("", "first")
	if err := a.Set("wrong", "second"); err == nil {
		t.Fatal("change with wrong current should error")
	}
	if !a.Verify("first") {
		t.Fatal("password should be unchanged after failed change")
	}
	if err := a.Set("first", "second"); err != nil {
		t.Fatal(err)
	}
	if !a.Verify("second") {
		t.Fatal("new password should verify after change")
	}
}

func TestAuthPersistsAcrossInstances(t *testing.T) {
	dir := t.TempDir()
	path := filepath.Join(dir, "secrets.json")
	a, _ := NewAuth(path)
	_ = a.Set("", "remember-me")

	b, _ := NewAuth(path)
	if !b.Verify("remember-me") {
		t.Fatal("password should survive a reload")
	}
}

func TestAuthClearRequiresCurrent(t *testing.T) {
	a, _ := NewAuth(filepath.Join(t.TempDir(), "secrets.json"))
	_ = a.Set("", "abc")
	if err := a.Clear("wrong"); err == nil {
		t.Fatal("clear with wrong current should error")
	}
	if !a.IsSet() {
		t.Fatal("should still be set after failed clear")
	}
	if err := a.Clear("abc"); err != nil {
		t.Fatal(err)
	}
	if a.IsSet() {
		t.Fatal("should be unset after successful clear")
	}
}

func TestAuthResetEverything(t *testing.T) {
	a, _ := NewAuth(filepath.Join(t.TempDir(), "secrets.json"))
	_ = a.Set("", "abc")
	if err := a.ResetEverything(); err != nil {
		t.Fatal(err)
	}
	if a.IsSet() {
		t.Fatal("should be unset after reset")
	}
}
