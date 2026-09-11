package main

import (
	"context"
	"encoding/json"
	"errors"
	"io"
	"os"
	"path/filepath"
	"strings"
	"syscall"
	"testing"
	"time"

	"local/GoogleMessagingAppMac/internal/archive"
	"local/GoogleMessagingAppMac/internal/google"
)

func TestRelinkRequiresExclusiveLiveArchive(t *testing.T) {
	for _, scenario := range []string{"synthetic", "locked", "missing"} {
		t.Run(scenario, func(t *testing.T) {
			dir := t.TempDir()
			if scenario != "missing" {
				store, err := archive.Open(dir)
				if err != nil {
					t.Fatal(err)
				}
				kind := "live"
				if scenario == "synthetic" {
					kind = "demo"
				}
				if err = store.SetMeta("kind", kind); err != nil {
					t.Fatal(err)
				}
				if err = store.PutPage([]archive.Message{{ID: "m", ConversationID: "chat", Timestamp: time.Now(), Body: "retained"}}, archive.Progress{ConversationID: "chat"}); err != nil {
					t.Fatal(err)
				}
				store.Close()
			}
			if scenario == "locked" {
				lock, err := os.OpenFile(filepath.Join(dir, ".lock"), os.O_CREATE|os.O_RDWR, 0600)
				if err != nil {
					t.Fatal(err)
				}
				defer lock.Close()
				if err = syscall.Flock(int(lock.Fd()), syscall.LOCK_EX|syscall.LOCK_NB); err != nil {
					t.Fatal(err)
				}
				defer syscall.Flock(int(lock.Fd()), syscall.LOCK_UN)
			}
			read, write, err := os.Pipe()
			if err != nil {
				t.Fatal(err)
			}
			original := os.Stdout
			os.Stdout = write
			err = run(context.Background(), []string{"relink", "--data", dir, "--status-json"})
			os.Stdout = original
			write.Close()
			data, _ := io.ReadAll(read)
			read.Close()
			if err == nil {
				t.Fatal("unsafe archive accepted")
			}
			var status google.PairingStatus
			if json.Unmarshal(data, &status) != nil || status.State == "complete" || status.Emoji != "" {
				t.Fatal("invalid terminal status")
			}
			if scenario == "locked" && (!errors.Is(err, google.ErrArchiveBusy) || status.State != "archive_busy") {
				t.Fatal("lock failure not reported")
			}
			if scenario == "missing" {
				if _, err = os.Stat(filepath.Join(dir, "archive.db")); !os.IsNotExist(err) {
					t.Fatal("relink created an empty archive")
				}
			} else {
				store, e := archive.Open(dir)
				if e != nil {
					t.Fatal(e)
				}
				defer store.Close()
				stats, e := store.Stats()
				if e != nil || stats.Messages != 1 {
					t.Fatal("failed relink changed history")
				}
			}
		})
	}
}

func TestPairCannotBypassRelinkForSavedHistory(t *testing.T) {
	dir := t.TempDir()
	store, err := archive.Open(dir)
	if err != nil {
		t.Fatal(err)
	}
	if err = store.PutConversation(archive.Conversation{ID: "chat"}); err != nil {
		t.Fatal(err)
	}
	store.Close()
	err = run(context.Background(), []string{"pair", "--data", dir})
	if err == nil || !strings.Contains(err.Error(), "use relink") {
		t.Fatal("pair did not require verified relink")
	}
}
