package google

import (
	"context"
	"encoding/json"
	"errors"
	"os"
	"path/filepath"
	"reflect"
	"testing"
	"time"

	"github.com/google/uuid"
	"go.mau.fi/mautrix-gmessages/pkg/libgm"
	"go.mau.fi/mautrix-gmessages/pkg/libgm/gmproto"
	"local/GoogleMessagingAppMac/internal/archive"
)

func testAuth() *libgm.AuthData {
	a := libgm.NewAuthData()
	a.Mobile = &gmproto.Device{SourceID: "person@example.test"}
	a.DestRegID = uuid.MustParse("00000000-0000-0000-0000-000000000001")
	a.PairingID = uuid.MustParse("00000000-0000-0000-0000-000000000002")
	return a
}

func TestLegacyIdentityUsesOnlySavedPairing(t *testing.T) {
	s, err := archive.Open(t.TempDir())
	if err != nil {
		t.Fatal(err)
	}
	defer s.Close()
	absent := func(context.Context) ([]byte, error) { return nil, errors.New("missing") }
	if _, err = originalIdentity(context.Background(), s, absent); !errors.Is(err, ErrOriginalIdentityMissing) {
		t.Fatal("missing original accepted")
	}
	auth := testAuth()
	expected, _ := identityFromAuth(auth)
	auth.Mobile.SourceID = " PERSON@EXAMPLE.TEST "
	got, err := identityFromAuth(auth)
	if err != nil || got != expected {
		t.Fatal("account normalization changed identity")
	}
	read := func(context.Context) ([]byte, error) { return json.Marshal(session{Auth: auth}) }
	got, err = originalIdentity(context.Background(), s, read)
	if err != nil || got != expected {
		t.Fatal("legacy migration failed")
	}
	got, err = originalIdentity(context.Background(), s, absent)
	if err != nil || got != expected {
		t.Fatal("identity lost when Keychain unavailable")
	}
	for _, invalid := range []*libgm.AuthData{nil, libgm.NewAuthData(), {Mobile: auth.Mobile, DestRegID: auth.DestRegID}} {
		if _, err = identityFromAuth(invalid); err == nil {
			t.Fatal("incomplete pairing accepted")
		}
	}
}

func TestRelinkVerificationGatesCredentialReplacement(t *testing.T) {
	for _, scenario := range []string{"success", "wrong_account", "wrong_phone", "changed_after_confirmation", "cancel_login", "cancel_confirmation", "save_failure", "different_archive_identity"} {
		t.Run(scenario, func(t *testing.T) {
			s, err := archive.Open(t.TempDir())
			if err != nil {
				t.Fatal(err)
			}
			defer s.Close()
			expected, _ := identityFromAuth(testAuth())
			bound := expected
			if scenario == "different_archive_identity" {
				bound.Phone = identityHash("phone", "other")
			}
			if err = s.BindPairingIdentity(bound); err != nil {
				t.Fatal(err)
			}
			now := time.Now().UTC()
			progress := archive.Progress{ConversationID: "chat", Since: now.AddDate(-1, 0, 0), Cursor: json.RawMessage(`"cursor"`), State: "page_limit", Pages: 4}
			if err = s.PutPage([]archive.Message{{ID: "m", ConversationID: "chat", Timestamp: now, Body: "saved message", Attachments: []archive.Attachment{{ID: "photo", Path: "media/photo.jpg", State: "downloaded_original"}}}}, progress); err != nil {
				t.Fatal(err)
			}
			for _, path := range []string{"media/photo.jpg", "drafts.json", "settings.json"} {
				full := filepath.Join(s.Dir, path)
				if err = os.MkdirAll(filepath.Dir(full), 0700); err != nil {
					t.Fatal(err)
				}
				if err = os.WriteFile(full, []byte("keep"), 0600); err != nil {
					t.Fatal(err)
				}
			}
			if err = s.PutConversation(archive.Conversation{ID: "chat", Name: "Synthetic"}); err != nil {
				t.Fatal(err)
			}
			attempt := archive.SendCommand{Kind: "send_text", ID: "00000000-0000-0000-0000-000000000010", ConversationID: "chat", Body: "already attempted"}
			if reserved, e := s.ReserveSend(attempt); e != nil || !reserved {
				t.Fatal("could not seed outbox")
			}
			if err = s.SetSendState(attempt.ID, "unknown", "interrupted"); err != nil {
				t.Fatal(err)
			}
			before, _ := s.Search("saved", "", 10)
			ctx, cancel := context.WithCancel(context.Background())
			defer cancel()
			starts, finishes, saves := 0, 0, 0
			steps := relinkSteps{
				login: func(context.Context) error {
					if scenario == "cancel_login" {
						return context.Canceled
					}
					return nil
				},
				account: func(context.Context) (string, error) {
					if scenario == "wrong_account" {
						return "different@example.test", nil
					}
					return "person@example.test", nil
				},
				start: func(context.Context) (string, archive.PairingIdentity, error) {
					starts++
					candidate := expected
					if scenario == "wrong_phone" {
						candidate.Phone = identityHash("phone", "new")
					}
					return "🐢", candidate, nil
				},
				finish: func(context.Context) (archive.PairingIdentity, error) {
					finishes++
					candidate := expected
					if scenario == "changed_after_confirmation" {
						candidate.Account = identityHash("account", "different")
					}
					if scenario == "cancel_confirmation" {
						cancel()
					}
					return candidate, nil
				},
				save: func(context.Context) error {
					saves++
					if scenario == "save_failure" {
						return errors.New("private upstream data")
					}
					return nil
				},
			}
			var statuses []PairingStatus
			err = performRelink(ctx, s, expected, steps, func(v PairingStatus) { statuses = append(statuses, v) })
			if scenario == "success" {
				if err != nil || saves != 1 {
					t.Fatal("verified pairing did not save exactly once")
				}
			} else if err == nil {
				t.Fatal("unsafe or incomplete attempt succeeded")
			}
			if scenario != "success" && scenario != "save_failure" && saves != 0 {
				t.Fatal("failed verification replaced credentials")
			}
			if scenario == "wrong_account" && starts != 0 {
				t.Fatal("wrong account reached phone pairing")
			}
			if scenario == "wrong_phone" && finishes != 0 {
				t.Fatal("wrong phone reached confirmation")
			}
			if scenario == "save_failure" && (saves != 1 || !errors.Is(err, ErrPairingSave)) {
				t.Fatal("uncertain save retried or exposed raw error")
			}
			identity, _ := s.PairingIdentity()
			if identity != bound {
				t.Fatal("archive owner changed")
			}
			state, e := s.SendState(attempt.ID)
			if e != nil || state != "unknown" {
				t.Fatal("outbox attempt changed")
			}
			if reserved, e := s.ReserveSend(attempt); e != nil || reserved {
				t.Fatal("relink allowed an attempt to be sent again")
			}
			after, _ := s.Search("saved", "", 10)
			if !reflect.DeepEqual(before, after) {
				t.Fatal("archived content changed")
			}
			for _, path := range []string{"media/photo.jpg", "drafts.json", "settings.json"} {
				b, e := os.ReadFile(filepath.Join(s.Dir, path))
				if e != nil || string(b) != "keep" {
					t.Fatal("archive file changed")
				}
			}
			p, _ := s.Progress("chat")
			if scenario != "success" && scenario != "save_failure" && string(p.Cursor) != string(progress.Cursor) {
				t.Fatal("rejected pairing changed cursor")
			}
			if scenario == "success" && (len(p.Cursor) != 0 || p.State != "relink_restart") {
				t.Fatal("new pairing kept old cursor")
			}
			for _, status := range statuses {
				b, _ := json.Marshal(status)
				var fields map[string]any
				json.Unmarshal(b, &fields)
				for key := range fields {
					if key != "state" && key != "emoji" {
						t.Fatal("unexpected status data")
					}
				}
			}
		})
	}
}
