package archive

import (
	"bytes"
	"encoding/json"
	"errors"
	"os"
	"path/filepath"
	"reflect"
	"strings"
	"testing"
	"time"
)

func TestIdentityBindsOnceAndSurvivesReopen(t *testing.T) {
	dir := t.TempDir()
	s, err := Open(dir)
	if err != nil {
		t.Fatal(err)
	}
	identity := PairingIdentity{Version: 1, Account: strings.Repeat("a", 64), Phone: strings.Repeat("b", 64)}
	if err = s.BindPairingIdentity(identity); err != nil {
		t.Fatal(err)
	}
	if err = s.BindPairingIdentity(identity); err != nil {
		t.Fatal(err)
	}
	for _, changed := range []PairingIdentity{{Version: 1, Account: strings.Repeat("c", 64), Phone: identity.Phone}, {Version: 1, Account: identity.Account, Phone: strings.Repeat("d", 64)}, {}} {
		if !errors.Is(s.BindPairingIdentity(changed), ErrIdentityMismatch) {
			t.Fatal("allowed replacement identity")
		}
	}
	s.Close()
	s, err = Open(dir)
	if err != nil {
		t.Fatal(err)
	}
	defer s.Close()
	got, err := s.PairingIdentity()
	if err != nil || got != identity {
		t.Fatal("identity did not survive reopen")
	}
	if err = s.SetMeta("pairing_identity", "{}"); err != nil {
		t.Fatal(err)
	}
	if _, err = s.PairingIdentity(); !errors.Is(err, ErrIdentityMismatch) {
		t.Fatal("invalid stored identity accepted")
	}
	if !errors.Is(s.BindPairingIdentity(identity), ErrIdentityMismatch) {
		t.Fatal("corrupt identity overwritten")
	}
}

func TestRelinkRestartsOnlyUnfinishedOpaqueCursors(t *testing.T) {
	s, err := Open(t.TempDir())
	if err != nil {
		t.Fatal(err)
	}
	defer s.Close()
	now := time.Now().UTC().Truncate(time.Microsecond)
	states := []string{"in_progress", "page_limit", "interrupted", "failed", "boundary_reached", "source_exhausted"}
	before := map[string]Progress{}
	for _, state := range states {
		p := Progress{ConversationID: state, Since: now.AddDate(-1, 0, 0), Cursor: json.RawMessage(`{"token":"old"}`), State: state, Pages: 9, Oldest: &now}
		before[state] = p
		if err = s.PutPage([]Message{{ID: state, ConversationID: state, Timestamp: now, Body: "saved history"}}, p); err != nil {
			t.Fatal(err)
		}
	}
	// Relinking must leave unrelated metadata and live catch-up checkpoints alone.
	if err = s.SetMeta("live_checkpoint", "retained"); err != nil {
		t.Fatal(err)
	}
	if err = s.ResetIncompleteHistory(); err != nil {
		t.Fatal(err)
	}
	for _, state := range states {
		p, err := s.Progress(state)
		if err != nil {
			t.Fatal(err)
		}
		if state == "boundary_reached" || state == "source_exhausted" {
			if !reflect.DeepEqual(p, before[state]) {
				t.Fatal("completed coverage changed")
			}
		} else if len(p.Cursor) != 0 || p.Pages != 0 || p.Oldest != nil || p.State != "relink_restart" || !p.Since.Equal(before[state].Since) {
			t.Fatalf("unfinished cursor not restarted: %s", state)
		}
	}
	stats, err := s.Stats()
	if err != nil || stats.Messages != len(states) {
		t.Fatal("saved messages changed")
	}
	value, err := s.Meta("live_checkpoint")
	if err != nil || value != "retained" {
		t.Fatal("live checkpoint changed")
	}
	// A bad progress row must roll the whole reset back.
	if _, err = s.db.Exec(`UPDATE progress SET payload='bad' WHERE conversation_id='failed'`); err != nil {
		t.Fatal(err)
	}
	if err = s.ResetIncompleteHistory(); err == nil {
		t.Fatal("corrupt progress silently skipped")
	}
}

func TestIdentityLookupDoesNotCreateOrWriteAnotherArchive(t *testing.T) {
	dir := t.TempDir()
	if _, err := ReadPairingIdentity(dir); err == nil {
		t.Fatal("missing archive accepted")
	}
	if _, err := os.Stat(filepath.Join(dir, "archive.db")); !os.IsNotExist(err) {
		t.Fatal("lookup created an archive")
	}
	store, err := Open(dir)
	if err != nil {
		t.Fatal(err)
	}
	identity := PairingIdentity{Version: 1, Account: strings.Repeat("a", 64), Phone: strings.Repeat("b", 64)}
	if err = store.BindPairingIdentity(identity); err != nil {
		t.Fatal(err)
	}
	store.Close()
	before, err := os.ReadFile(filepath.Join(dir, "archive.db"))
	if err != nil {
		t.Fatal(err)
	}
	got, err := ReadPairingIdentity(dir)
	if err != nil || got != identity {
		t.Fatal("identity lookup failed")
	}
	after, err := os.ReadFile(filepath.Join(dir, "archive.db"))
	if err != nil || !bytes.Equal(before, after) {
		t.Fatal("lookup modified archive")
	}
}
