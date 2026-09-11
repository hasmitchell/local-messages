package live

import (
	"context"
	"errors"
	"testing"
	"time"

	"github.com/google/uuid"
	"local/GoogleMessagingAppMac/internal/archive"
)

type fakeStarter struct {
	fakeSender
	calls  []string
	fail   bool
	result archive.Conversation
}

func (f *fakeStarter) StartConversation(_ context.Context, number string) (archive.Conversation, error) {
	f.calls = append(f.calls, number)
	if f.fail {
		return archive.Conversation{}, errors.New("private remote error")
	}
	return f.result, nil
}

func TestStartConversationCommandResolvesAndStoresTheThread(t *testing.T) {
	for _, mode := range []string{"resolved", "phone_rejected", "offline", "unsupported"} {
		t.Run(mode, func(t *testing.T) {
			store, err := archive.Open(t.TempDir())
			if err != nil {
				t.Fatal(err)
			}
			defer store.Close()
			var refreshed []string
			fake := &fakeStarter{fail: mode == "phone_rejected", result: archive.Conversation{ID: "new-thread", Name: "", Folder: "INBOX", LastMessage: time.Now(), Participants: []archive.Participant{{ID: "p1", Number: "+61400000009"}}}}
			session := &sendSession{token: "connection", ctx: context.Background(), client: fake, refresh: func(id string) { refreshed = append(refreshed, id) }}
			if mode == "unsupported" {
				session.client = &fakeSender{store: store, t: t}
			}
			if mode == "offline" {
				session = nil
			}
			router := &commandRouter{store: store}
			command := archive.SendCommand{Kind: "start", ID: uuid.NewString(), Connection: "connection", Number: "+61400000009"}
			if err := router.execute(command, session); err != nil {
				t.Fatal(err)
			}
			state, _ := store.SendState(command.ID)
			switch mode {
			case "resolved":
				if state != "resolved" || len(fake.calls) != 1 || fake.calls[0] != "+61400000009" || len(refreshed) != 1 || refreshed[0] != "new-thread" {
					t.Fatalf("state %q calls %v refreshed %v", state, fake.calls, refreshed)
				}
				var remote string
				if err := store.DB().QueryRow(`SELECT remote_id FROM outbox WHERE id=?`, command.ID).Scan(&remote); err != nil || remote != "new-thread" {
					t.Fatalf("remote id %q err %v", remote, err)
				}
				if latest, err := store.Latest("new-thread"); err != nil {
					t.Fatalf("conversation not stored: %v %v", latest, err)
				}
				// Repeating the same attempt ID never asks the phone again.
				if err := router.execute(command, session); err != nil || len(fake.calls) != 1 {
					t.Fatalf("duplicate start repeated the request: %v %v", err, fake.calls)
				}
			default:
				if state != "failed" {
					t.Fatalf("expected failed state, got %q", state)
				}
			}
		})
	}
	bad := archive.SendCommand{Kind: "start", ID: uuid.NewString(), Number: "04 00"}
	if bad.Valid() {
		t.Fatal("malformed number accepted")
	}
	text := archive.SendCommand{Kind: "send_text", ID: uuid.NewString(), ConversationID: "c", Body: "hi", Number: "+61400000000"}
	if text.Valid() {
		t.Fatal("text command must not carry a number")
	}
}
