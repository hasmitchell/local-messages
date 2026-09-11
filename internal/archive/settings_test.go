package archive

import (
	"os"
	"path/filepath"
	"testing"
	"time"
)

func TestRetentionRemovesOnlyOldUnreferencedLocalMedia(t *testing.T) {
	directory := t.TempDir()
	store, err := Open(directory)
	if err != nil {
		t.Fatal(err)
	}
	defer store.Close()
	os.Mkdir(filepath.Join(directory, "media"), 0700)
	for _, name := range []string{"old.jpg", "shared.jpg"} {
		if err := os.WriteFile(filepath.Join(directory, "media", name), []byte("synthetic"), 0600); err != nil {
			t.Fatal(err)
		}
	}
	now := time.Now().UTC()
	old := now.AddDate(-2, 0, 0)
	file := func(id, path string) Attachment {
		return Attachment{ID: id, Path: path, State: "downloaded_original", MIME: "image/jpeg"}
	}
	if err := store.PutUpdates([]Message{
		{ID: "old", ConversationID: "c", Timestamp: old, Body: "old retention needle", Attachments: []Attachment{file("one", "media/old.jpg"), file("shared", "media/shared.jpg"), file("escape", "../outside")}},
		{ID: "recent", ConversationID: "c", Timestamp: now, Body: "recent needle", Attachments: []Attachment{file("shared", "media/shared.jpg")}},
	}); err != nil {
		t.Fatal(err)
	}
	if err := store.PruneBefore(now.AddDate(-1, 0, 0)); err != nil {
		t.Fatal(err)
	}
	if _, err := store.MessageByID("old"); err == nil {
		t.Fatal("old message retained")
	}
	if _, err := store.MessageByID("recent"); err != nil {
		t.Fatal("recent message removed")
	}
	if err := store.PutUpdates([]Message{{ID: "late-old", ConversationID: "c", Timestamp: old, Body: "late obsolete snapshot"}}); err != nil {
		t.Fatal(err)
	}
	if _, err := store.MessageByID("late-old"); err == nil {
		t.Fatal("late snapshot re-imported expired data")
	}
	latePath := filepath.Join(directory, "media/late.jpg")
	if err := os.WriteFile(latePath, []byte("late download"), 0600); err != nil {
		t.Fatal(err)
	}
	if err := store.UpdateMedia(Message{ID: "old", Attachments: []Attachment{file("late", "media/late.jpg")}}); err != nil {
		t.Fatal(err)
	}
	if err := store.CollectMedia(); err != nil {
		t.Fatal(err)
	}
	if _, err := os.Stat(latePath); !os.IsNotExist(err) {
		t.Fatal("orphaned late download was not collected")
	}
	if _, err := os.Stat(filepath.Join(directory, "media/old.jpg")); !os.IsNotExist(err) {
		t.Fatal("old file remains")
	}
	if _, err := os.Stat(filepath.Join(directory, "media/shared.jpg")); err != nil {
		t.Fatal("still-referenced file removed")
	}
	var count int
	if err := store.db.QueryRow(`SELECT count(*) FROM message_search WHERE message_search MATCH 'retention'`).Scan(&count); err != nil || count != 0 {
		t.Fatal("FTS retained deleted text", err)
	}
	var floor string
	floor, err = store.Meta("retention_floor")
	if err != nil || floor == "" {
		t.Fatal("lost pruned coverage boundary")
	}
	if err := store.SetMeta("active_retention_floor", ""); err != nil {
		t.Fatal(err)
	}
	if err := store.PutUpdates([]Message{{ID: "restored", ConversationID: "c", Timestamp: old, Body: "restored history"}}); err != nil {
		t.Fatal(err)
	}
	if _, err := store.MessageByID("restored"); err != nil {
		t.Fatal("could not restore older history after disabling cleanup")
	}
}

func TestSettingsDefaultAndEffectiveHistory(t *testing.T) {
	directory := t.TempDir()
	settings, err := ReadSettings(directory)
	if err != nil || settings.RetentionDays != 0 {
		t.Fatal("cleanup must default off")
	}
	now := time.Date(2026, 9, 11, 13, 0, 0, 0, time.UTC)
	s := Settings{HistorySince: "2020-01-01", RetentionDays: 30}
	if actual := s.Cutoff(time.Time{}, now); !actual.Equal(time.Date(2026, 8, 12, 0, 0, 0, 0, time.UTC)) {
		t.Fatal("retention would re-import expired history")
	}
	for _, data := range []string{`{"history_since":"invalid"}`, `{"history_since":"1999-01-01"}`, `{"retention_days":-1}`, `{"retention_days":999999}`} {
		os.WriteFile(filepath.Join(directory, "settings.json"), []byte(data), 0600)
		if _, err := ReadSettings(directory); err == nil {
			t.Fatal("accepted invalid settings")
		}
	}
}
