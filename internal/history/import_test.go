package history

import (
	"context"
	"encoding/json"
	"errors"
	"local/GoogleMessagingAppMac/internal/archive"
	"testing"
	"time"
)

type fakeSource struct {
	pages  map[string]Page
	failAt string
	calls  []string
}

func (f *fakeSource) Fetch(ctx context.Context, id string, cursor json.RawMessage) (Page, error) {
	key := string(cursor)
	f.calls = append(f.calls, key)
	if f.failAt != "" && key == f.failAt {
		return Page{}, errors.New("phone offline")
	}
	return f.pages[key], nil
}
func message(id string, at time.Time) archive.Message {
	return archive.Message{ID: id, ConversationID: "chat", Timestamp: at, Body: "booking " + id}
}
func setup(t *testing.T) (*archive.Store, time.Time) {
	t.Helper()
	s, err := archive.Open(t.TempDir())
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { s.Close() })
	return s, time.Now().UTC().AddDate(-1, 0, 0).Truncate(time.Second)
}

func TestYearCutoffInclusiveAcrossOverlappingPages(t *testing.T) {
	s, since := setup(t)
	source := &fakeSource{pages: map[string]Page{
		"":       {Messages: []archive.Message{message("new", since.Add(24*time.Hour))}, Cursor: json.RawMessage(`"next"`)},
		`"next"`: {Messages: []archive.Message{message("new", since.Add(24*time.Hour)), message("boundary", since), message("old", since.Add(-time.Microsecond))}, Cursor: json.RawMessage(`"end"`)},
	}}
	p, err := Import(context.Background(), s, source, "chat", Options{Since: since, MaxPages: 10})
	if err != nil {
		t.Fatal(err)
	}
	stats, err := s.Stats()
	if err != nil {
		t.Fatal(err)
	}
	if p.State != "boundary_reached" || stats.Messages != 2 || len(source.calls) != 2 {
		t.Fatalf("bad boundary: %+v %+v", p, stats)
	}
}

func TestInterruptedHistoryResumesCommittedCursor(t *testing.T) {
	s, since := setup(t)
	source := &fakeSource{failAt: `"next"`, pages: map[string]Page{
		"":       {Messages: []archive.Message{message("new", since.Add(time.Hour))}, Cursor: json.RawMessage(`"next"`)},
		`"next"`: {Messages: []archive.Message{message("boundary", since), message("old", since.Add(-time.Second))}},
	}}
	p, err := Import(context.Background(), s, source, "chat", Options{Since: since, MaxPages: 10})
	if err == nil || p.State != "failed" {
		t.Fatalf("failure not recorded: %+v %v", p, err)
	}
	source.failAt = ""
	source.calls = nil
	p, err = Import(context.Background(), s, source, "chat", Options{Since: since, MaxPages: 10, Resume: true})
	if err != nil {
		t.Fatal(err)
	}
	if len(source.calls) != 1 || source.calls[0] != `"next"` || p.State != "boundary_reached" {
		t.Fatalf("not resumed: %+v %+v", source.calls, p)
	}
	stats, _ := s.Stats()
	if stats.Messages != 2 {
		t.Fatal("resume duplicated or lost a message")
	}
}

func TestLimitsAndStallsAreNotReportedAsComplete(t *testing.T) {
	for _, state := range []string{"page_limit", "stalled", "unordered_page", "invalid_timestamp"} {
		t.Run(state, func(t *testing.T) {
			s, since := setup(t)
			page := Page{Messages: []archive.Message{message("a", since.Add(time.Hour))}, Cursor: json.RawMessage(`"next"`)}
			switch state {
			case "stalled":
				page.Cursor = nil
			case "unordered_page":
				page.Messages = append(page.Messages, message("b", since.Add(2*time.Hour)))
			case "invalid_timestamp":
				page.Messages[0].Timestamp = time.Time{}
			}
			source := &fakeSource{pages: map[string]Page{"": page}}
			p, _ := Import(context.Background(), s, source, "chat", Options{Since: since, MaxPages: 1})
			if p.State != state {
				t.Fatalf("got %s, expected %s", p.State, state)
			}
		})
	}
}

func TestEmptyPageWithCursorIsNotExhaustion(t *testing.T) {
	s, since := setup(t)
	source := &fakeSource{pages: map[string]Page{"": {Cursor: json.RawMessage(`"next"`)}}}
	p, err := Import(context.Background(), s, source, "chat", Options{Since: since, MaxPages: 5})
	if err == nil || p.State != "stalled" {
		t.Fatalf("false exhaustion: %+v %v", p, err)
	}
}

func TestResumeRejectsChangedDateAndFreshImportRefreshesEdits(t *testing.T) {
	s, since := setup(t)
	source := &fakeSource{pages: map[string]Page{"": {Messages: []archive.Message{message("a", since.Add(time.Hour))}, Cursor: json.RawMessage(`"next"`)}}}
	if _, err := Import(context.Background(), s, source, "chat", Options{Since: since, MaxPages: 5}); err != nil {
		t.Fatal(err)
	}
	if _, err := Import(context.Background(), s, source, "chat", Options{Since: since.Add(-time.Hour), MaxPages: 5, Resume: true}); err == nil {
		t.Fatal("changed cutoff silently reused cursor")
	}
	m := message("a", since.Add(time.Hour))
	m.Body = "updated itinerary"
	source.pages[""] = Page{Messages: []archive.Message{m}, Cursor: json.RawMessage(`"next"`)}
	if _, err := Import(context.Background(), s, source, "chat", Options{Since: since, MaxPages: 5}); err != nil {
		t.Fatal(err)
	}
	found, err := s.Search("updated itinerary", "", 10)
	if err != nil || len(found) != 1 {
		t.Fatal("fresh import did not update archive")
	}
}

func TestOldConversationsAreSkippedButUnknownOrBoundaryDatesAreFetched(t *testing.T) {
	for _, test := range []struct {
		name    string
		offset  time.Duration
		unknown bool
		skip    bool
	}{
		{"older", -time.Second, false, true},
		{"boundary", 0, false, false},
		{"newer", time.Hour, false, false},
		{"unknown", 0, true, false},
	} {
		t.Run(test.name, func(t *testing.T) {
			s, since := setup(t)
			latest := since.Add(test.offset)
			if test.unknown {
				latest = time.Time{}
			}
			source := &fakeSource{pages: map[string]Page{}}
			p, err := Import(context.Background(), s, source, "chat", Options{Since: since, MaxPages: 5, LatestMessage: latest})
			if err != nil {
				t.Fatal(err)
			}
			if test.skip {
				if len(source.calls) != 0 || p.State != "conversation_before_cutoff" {
					t.Fatalf("old thread fetched: %+v", p)
				}
			} else if len(source.calls) != 1 || p.State != "source_exhausted" {
				t.Fatalf("eligible or unknown thread skipped: %+v", p)
			}
		})
	}
}
