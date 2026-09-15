package archive

import (
	"crypto/sha256"
	"encoding/hex"
	"os"
	"path/filepath"
	"testing"
	"time"
)

func stageSentFile(t *testing.T, dir string, id string, data []byte) OutgoingFile {
	t.Helper()
	folder := filepath.Join(dir, "drafts", "attachments")
	if err := os.MkdirAll(folder, 0700); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(filepath.Join(folder, id), data, 0600); err != nil {
		t.Fatal(err)
	}
	sum := sha256.Sum256(data)
	return OutgoingFile{ID: id, Name: "IMG_0001.jpeg", MIME: "image/jpeg", Size: int64(len(data)), SHA256: hex.EncodeToString(sum[:])}
}

func confirmedSend(t *testing.T, s *Store, command SendCommand, m Message) {
	t.Helper()
	if err := s.PutConversation(Conversation{ID: command.ConversationID, Name: "Chloé", Folder: "INBOX", LastMessage: m.Timestamp}); err != nil {
		t.Fatal(err)
	}
	if created, err := s.ReserveSend(command); err != nil || !created {
		t.Fatalf("reserve %v %v", created, err)
	}
	if err := s.SetSendState(command.ID, "accepted", ""); err != nil {
		t.Fatal(err)
	}
	if err := s.PutUpdates([]Message{m}); err != nil {
		t.Fatal(err)
	}
}

func TestAdoptSentOriginalsKeepsUploadedFileWhenPhoneHasNoReference(t *testing.T) {
	dir := t.TempDir()
	s, err := Open(dir)
	if err != nil {
		t.Fatal(err)
	}
	defer s.Close()
	photo := []byte("jpeg bytes sent from this mac")
	file := stageSentFile(t, dir, "5bad91fe-835a-42d8-9d31-611802d83f3f", photo)
	command := SendCommand{Kind: "send_text", ID: "251bb6a2-9b07-4de3-b5e6-553ad17a4e59", ConversationID: "1724", Body: "the dogs", Files: []OutgoingFile{file}}
	now := time.Now().UTC().Truncate(time.Microsecond)
	// The phone reports its transcoded copy: smaller, and without a media key.
	m := Message{ClientID: command.ID, ID: "114608", ConversationID: "1724", Timestamp: now, Body: "the dogs", Sender: "Me", Outgoing: true, Status: "OUTGOING_COMPLETE",
		Attachments: []Attachment{{ID: "115487", Name: "10097", MIME: "image/jpeg", Size: 157843, State: "original_unavailable", Attempts: 2, NextAttempt: now.Add(time.Hour).UnixMicro()}}}
	confirmedSend(t, s, command, m)
	if state, err := s.SendState(command.ID); err != nil || state != "confirmed" {
		t.Fatalf("send not confirmed by its echo: %q %v", state, err)
	}
	adopted, err := s.AdoptSentOriginals()
	if err != nil || adopted != 1 {
		t.Fatalf("adopted %d %v", adopted, err)
	}
	saved, err := s.MessageByID("114608")
	if err != nil {
		t.Fatal(err)
	}
	a := saved.Attachments[0]
	if a.State != "downloaded_original" || a.Source != "sent" || a.Size != int64(len(photo)) || a.Attempts != 0 || a.NextAttempt != 0 || filepath.Dir(a.Path) != "media" || filepath.Ext(a.Path) != ".jpg" {
		t.Fatalf("attachment not kept as a sent original: %+v", a)
	}
	if data, err := os.ReadFile(filepath.Join(dir, a.Path)); err != nil || string(data) != string(photo) {
		t.Fatalf("media copy %q %v", data, err)
	}
	if adopted, err = s.AdoptSentOriginals(); err != nil || adopted != 0 {
		t.Fatalf("second pass adopted %d %v", adopted, err)
	}
	// A later history page carries the phone's own reference. The sent bytes
	// remain the original rather than being replaced by the transcoded copy.
	fresh := m
	fresh.ClientID = ""
	fresh.Attachments = []Attachment{{ID: "115487", Name: "10097", MIME: "image/jpeg", Size: 157843, MediaID: "remote-media", Key: []byte("k"), State: "pending"}}
	if err = s.PutPage([]Message{fresh}, Progress{ConversationID: "1724", Since: now.AddDate(-1, 0, 0), State: "complete"}); err != nil {
		t.Fatal(err)
	}
	saved, err = s.MessageByID("114608")
	if err != nil {
		t.Fatal(err)
	}
	a = saved.Attachments[0]
	if a.State != "downloaded_original" || a.Source != "sent" || a.Path == "" || a.MediaID != "remote-media" {
		t.Fatalf("sent original lost after history refresh: %+v", a)
	}
	pending, err := s.PendingMedia(now.Add(-time.Hour))
	if err != nil || len(pending) != 1 || pending[0].Attachments[0].State != "downloaded_original" {
		t.Fatalf("pending media %+v %v", pending, err)
	}
}

func TestAdoptSentOriginalsRefusesAlteredOrAmbiguousFiles(t *testing.T) {
	dir := t.TempDir()
	s, err := Open(dir)
	if err != nil {
		t.Fatal(err)
	}
	defer s.Close()
	now := time.Now().UTC().Truncate(time.Microsecond)
	altered := stageSentFile(t, dir, "1cfc3cb7-3622-4b35-9b5c-aaaae0d1b419", []byte("original"))
	if err = os.WriteFile(filepath.Join(dir, "drafts", "attachments", altered.ID), []byte("replaced"), 0600); err != nil {
		t.Fatal(err)
	}
	one := SendCommand{Kind: "send_text", ID: "4c577807-1442-4d71-a090-e603e1b2d47d", ConversationID: "1724", Files: []OutgoingFile{altered}}
	confirmedSend(t, s, one, Message{ClientID: one.ID, ID: "1", ConversationID: "1724", Timestamp: now, Sender: "Me", Outgoing: true,
		Attachments: []Attachment{{ID: "a1", MIME: "image/jpeg", Size: 8, State: "original_unavailable"}}})
	first := stageSentFile(t, dir, "925fe336-f19d-4a2c-b4f1-af5e2473352d", []byte("first photo"))
	second := stageSentFile(t, dir, "0d5e9f5c-8a0e-4c4a-9b7a-2f0b7f0c1d2e", []byte("second photo"))
	two := SendCommand{Kind: "send_text", ID: "b4b7a5f2-3c1d-4e6f-8a9b-0c1d2e3f4a5b", ConversationID: "1724", Files: []OutgoingFile{first, second}}
	// The phone kept only one of two uploads: which one is unknown, so neither is adopted.
	confirmedSend(t, s, two, Message{ClientID: two.ID, ID: "2", ConversationID: "1724", Timestamp: now.Add(time.Second), Sender: "Me", Outgoing: true,
		Attachments: []Attachment{{ID: "a2", MIME: "image/jpeg", Size: 5, State: "original_unavailable"}}})
	vcard := stageSentFile(t, dir, "6a1b2c3d-4e5f-4a6b-8c7d-9e0f1a2b3c4d", []byte("BEGIN:VCARD"))
	vcard.MIME, vcard.Name = "text/vcard", "chloe.vcf"
	three := SendCommand{Kind: "send_text", ID: "c1d2e3f4-a5b6-4c7d-8e9f-0a1b2c3d4e5f", ConversationID: "1724", Files: []OutgoingFile{vcard}}
	// A different kind of media than uploaded is not the same file.
	confirmedSend(t, s, three, Message{ClientID: three.ID, ID: "3", ConversationID: "1724", Timestamp: now.Add(2 * time.Second), Sender: "Me", Outgoing: true,
		Attachments: []Attachment{{ID: "a3", MIME: "image/jpeg", Size: 5, State: "original_unavailable"}}})
	adopted, err := s.AdoptSentOriginals()
	if err != nil || adopted != 0 {
		t.Fatalf("adopted %d %v", adopted, err)
	}
	for _, id := range []string{"1", "2", "3"} {
		saved, err := s.MessageByID(id)
		if err != nil || saved.Attachments[0].State != "original_unavailable" || saved.Attachments[0].Path != "" {
			t.Fatalf("message %s changed: %+v %v", id, saved.Attachments, err)
		}
	}
	entries, err := os.ReadDir(filepath.Join(dir, "media"))
	if err == nil && len(entries) != 0 {
		t.Fatalf("stray media files: %v", entries)
	}
}
