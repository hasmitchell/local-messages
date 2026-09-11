package live

import (
	"context"
	"encoding/json"
	"errors"
	"github.com/google/uuid"
	"local/GoogleMessagingAppMac/internal/archive"
	"strings"
	"testing"
	"time"
)

type fakeSender struct {
	prepares, sends int
	mode            string
	store           *archive.Store
	t               *testing.T
}

func (f *fakeSender) PrepareText(_ context.Context, c archive.SendCommand) (func(context.Context) (bool, error), error) {
	f.prepares++
	if f.mode == "preflight" {
		return nil, errors.New("private remote error")
	}
	return func(ctx context.Context) (bool, error) {
		f.sends++
		state, err := f.store.SendState(c.ID)
		if err != nil || state != "sending" {
			f.t.Fatal("send happened before durable reservation")
		}
		switch f.mode {
		case "timeout":
			return false, context.DeadlineExceeded
		case "reject":
			return false, nil
		case "echo":
			err := f.store.PutUpdates([]archive.Message{{ID: "remote", ClientID: c.ID, ConversationID: c.ConversationID, Body: c.Body, Timestamp: time.Now(), Outgoing: true, Status: "OUTGOING_COMPLETE"}})
			if err != nil {
				f.t.Fatal(err)
			}
		}
		return true, nil
	}, nil
}
func TestSendAttemptsAreDurableAndNeverAutomaticallyRepeated(t *testing.T) {
	for _, mode := range []string{"accepted", "timeout", "reject", "preflight", "echo", "offline", "stale_connection"} {
		t.Run(mode, func(t *testing.T) {
			store, err := archive.Open(t.TempDir())
			if err != nil {
				t.Fatal(err)
			}
			defer store.Close()
			if err = store.PutConversation(archive.Conversation{ID: "c", Folder: "INBOX", LastMessage: time.Now()}); err != nil {
				t.Fatal(err)
			}
			command := archive.SendCommand{Kind: "send_text", ID: uuid.NewString(), Connection: "connection", ConversationID: "c", Body: "Synthetic test text"}
			fake := &fakeSender{mode: mode, store: store, t: t}
			session := &sendSession{token: "connection", ctx: context.Background(), client: fake}
			if mode == "offline" {
				session = nil
			}
			if mode == "stale_connection" {
				command.Connection = "old-connection"
			}
			router := &commandRouter{store: store}
			for range 2 {
				if err = router.execute(command, session); err != nil {
					t.Fatal(err)
				}
			}
			expected := map[string]string{"accepted": "accepted", "timeout": "unknown", "reject": "failed", "preflight": "failed", "echo": "confirmed", "offline": "failed", "stale_connection": "failed"}[mode]
			state, _ := store.SendState(command.ID)
			if state != expected {
				t.Fatalf("state %s; want %s", state, expected)
			}
			sends := 1
			if mode == "offline" || mode == "preflight" || mode == "stale_connection" {
				sends = 0
			}
			if fake.sends != sends {
				t.Fatal("incorrect number of wire sends", fake.sends)
			}
			if err = store.RecoverInterruptedSends(); err != nil {
				t.Fatal(err)
			}
			if err = router.execute(command, session); err != nil {
				t.Fatal(err)
			}
			if fake.sends != sends {
				t.Fatal("restart repeated an attempted send")
			}
		})
	}
}
func TestCrashRecoveryDistinguishesBeforeAndAfterSubmission(t *testing.T) {
	store, err := archive.Open(t.TempDir())
	if err != nil {
		t.Fatal(err)
	}
	defer store.Close()
	_ = store.PutConversation(archive.Conversation{ID: "c", LastMessage: time.Now()})
	for _, stage := range []string{"preparing", "sending"} {
		c := archive.SendCommand{Kind: "send_text", ID: uuid.NewString(), ConversationID: "c", Body: "Saved before network"}
		_, err := store.ReserveSend(c)
		if err != nil {
			t.Fatal(err)
		}
		_ = store.SetSendState(c.ID, stage, "")
		if err = store.RecoverInterruptedSends(); err != nil {
			t.Fatal(err)
		}
		state, _ := store.SendState(c.ID)
		expected := "failed"
		if stage == "sending" {
			expected = "unknown"
		}
		if state != expected {
			t.Fatal("incorrect interrupted-send state")
		}
	}
}
func TestCommandParserRejectsMalformedOrOversizedInput(t *testing.T) {
	valid := archive.SendCommand{Kind: "send_text", ID: uuid.NewString(), ConversationID: "c", Body: "Line one\nLine two 😀"}
	encoded, _ := json.Marshal(valid)
	for _, test := range []struct {
		input string
		count int
	}{{string(encoded) + "\n", 1}, {string(encoded) + " {}\n", 0}, {`{"kind":"send_text","id":"bad"}` + "\n", 0}, {strings.Repeat("x", 129*1024), 0}, {strings.TrimSuffix(string(encoded), "}") + `,"unexpected":true}` + "\n", 0}} {
		out := make(chan archive.SendCommand, 2)
		ReadCommands(context.Background(), strings.NewReader(test.input), out)
		count := 0
		for range out {
			count++
		}
		if count != test.count {
			t.Fatal("unsafe command accepted")
		}
	}
}
