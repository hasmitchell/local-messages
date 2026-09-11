package main

import (
	"context"
	"encoding/json"
	"errors"
	"flag"
	"fmt"
	"io"
	"os"
	"os/signal"
	"path/filepath"
	"strings"
	"syscall"
	"time"

	"go.mau.fi/mautrix-gmessages/pkg/libgm/gmproto"
	"local/GoogleMessagingAppMac/internal/archive"
	"local/GoogleMessagingAppMac/internal/google"
	"local/GoogleMessagingAppMac/internal/history"
	"local/GoogleMessagingAppMac/internal/live"
)

const usage = `Google Messages local archive feasibility probe

  gmprobe demo
  gmprobe pair [--data DIRECTORY]
  gmprobe relink [--data DIRECTORY] [--status-json] [--parent-stdin]
  gmprobe sync [--since YYYY-MM-DD] [--resume] [--media MODE]
               [--max-pages 100] [--conversation-limit 1000] [--media-budget-mib 1024]
  gmprobe media [--since YYYY-MM-DD] [--media MODE] [--media-budget-mib 1024]
  gmprobe watch [--data DIRECTORY] [--media MODE] [--parent-stdin]
  gmprobe status [--data DIRECTORY]
  gmprobe search [--data DIRECTORY] [--conversation ID] [--limit 50] QUERY

Default live data: .local-data/live. Demo data: .local-data/demo.
This client only reads from the phone; it does not send messages or mark them read.
The archive is local SQLite with user-only permissions, not application-level encryption.
Pairing credentials are stored separately in macOS Keychain.
`

func main() {
	// SQLite WAL files and media inherit private permissions too.
	syscall.Umask(0077)
	ctx, cancel := signal.NotifyContext(context.Background(), os.Interrupt, syscall.SIGTERM)
	defer cancel()
	if err := run(ctx, os.Args[1:]); err != nil {
		fmt.Fprintln(os.Stderr, "Error:", err)
		os.Exit(1)
	}
}

func run(ctx context.Context, args []string) (runErr error) {
	if len(args) == 0 || args[0] == "help" || args[0] == "--help" {
		fmt.Print(usage)
		return nil
	}
	command := args[0]
	switch command {
	case "demo", "pair", "relink", "sync", "media", "watch", "status", "search":
	default:
		return fmt.Errorf("unknown command %q; run help", command)
	}
	fs := flag.NewFlagSet(command, flag.ContinueOnError)
	defaultDir := ".local-data/live"
	if command == "demo" {
		defaultDir = ".local-data/demo"
	}
	dir := fs.String("data", defaultDir, "local archive directory")
	since := fs.String("since", time.Now().AddDate(-1, 0, 0).Format("2006-01-02"), "inclusive history start date (UTC)")
	resume := fs.Bool("resume", false, "continue the earlier snapshot; use the same --since date")
	media := fs.String("media", "photos", "download photos, contacts, photos-and-contacts, all, or none")
	pages := fs.Int("max-pages", 100, "maximum 100-message pages per conversation for this run")
	convLimit := fs.Int("conversation-limit", 1000, "maximum requested conversations per folder")
	mediaBudget := fs.Int64("media-budget-mib", 1024, "maximum newly downloaded media MiB for this run")
	limit := fs.Int("limit", 50, "maximum search results")
	commandsStdin := fs.Bool("commands-stdin", false, "accept explicit text-send commands on private stdin")
	parentStdin := fs.Bool("parent-stdin", false, "stop the worker when its parent closes stdin")
	statusJSON := fs.Bool("status-json", false, "emit private pairing status records")
	var existingArchives archivePaths
	fs.Var(&existingArchives, "existing-archive", "an account archive already saved in the switcher; repeat for each archive")
	conversation := fs.String("conversation", "", "restrict search to this conversation ID")
	if err := fs.Parse(args[1:]); err != nil {
		return err
	}
	if (command == "relink" || command == "pair") && *statusJSON {
		defer func() {
			state := "complete"
			if runErr != nil {
				state = google.PairingFailureState(runErr)
			}
			_ = json.NewEncoder(os.Stdout).Encode(google.PairingStatus{State: state})
		}()
	}
	cutoff, err := time.Parse("2006-01-02", *since)
	if err != nil {
		return fmt.Errorf("--since must be YYYY-MM-DD")
	}
	if *pages < 1 || *pages > 10000 || *convLimit < 1 || *convLimit > 10000 || *mediaBudget < 0 || *mediaBudget > 102400 {
		return fmt.Errorf("history or media limits are out of range")
	}
	if *media != "photos" && *media != "contacts" && *media != "photos-and-contacts" && *media != "all" && *media != "none" {
		return fmt.Errorf("--media must be photos, contacts, photos-and-contacts, all, or none")
	}
	if command != "search" && fs.NArg() != 0 {
		return fmt.Errorf("unexpected arguments")
	}
	if command == "search" && strings.TrimSpace(strings.Join(fs.Args(), " ")) == "" {
		return fmt.Errorf("provide a search query")
	}
	// Read-only commands don't create an empty archive as a side effect.
	if command == "status" || command == "search" || command == "watch" || command == "relink" {
		if _, err = os.Stat(filepath.Join(*dir, "archive.db")); err != nil {
			return fmt.Errorf("no archive at %s; run demo or pair and sync", *dir)
		}
	}
	store, err := archive.Open(*dir)
	if err != nil {
		return err
	}
	defer store.Close()
	// One process owns each archive at a time, including pairing operations.
	lock, err := os.OpenFile(filepath.Join(store.Dir, ".lock"), os.O_CREATE|os.O_RDWR, 0600)
	if err != nil {
		return err
	}
	defer lock.Close()
	if err = syscall.Flock(int(lock.Fd()), syscall.LOCK_EX|syscall.LOCK_NB); err != nil {
		return google.ErrArchiveBusy
	}
	defer syscall.Flock(int(lock.Fd()), syscall.LOCK_UN)
	kind, err := store.Meta("kind")
	if err != nil {
		return err
	}
	if command == "demo" {
		stats, err := store.Stats()
		if err != nil {
			return err
		}
		if kind != "demo" && (kind != "" || stats.Messages > 0) {
			return fmt.Errorf("demo requires a separate empty or existing demo archive")
		}
		if err = store.SetMeta("kind", "demo"); err != nil {
			return err
		}
		return seedDemo(ctx, store, cutoff)
	}
	if (command == "pair" || command == "sync" || command == "media") && kind != "" && kind != "live" {
		return fmt.Errorf("synthetic archives cannot connect to Google; use a separate --data directory")
	}
	switch command {
	case "relink":
		if kind != "live" {
			return fmt.Errorf("reconnect requires an existing live archive")
		}
		pairCtx, cancel := context.WithTimeout(ctx, 10*time.Minute)
		defer cancel()
		if *parentStdin {
			go func() { _, _ = io.Copy(io.Discard, os.Stdin); cancel() }()
		}
		go func() { <-pairCtx.Done(); time.Sleep(5 * time.Second); os.Exit(1) }()
		err = google.Relink(pairCtx, store, func(status google.PairingStatus) {
			if *statusJSON {
				_ = json.NewEncoder(os.Stdout).Encode(status)
			} else if status.Emoji != "" {
				fmt.Fprintf(os.Stdout, "On your original phone, confirm this emoji in Google Messages: %s\n", status.Emoji)
			}
		})
		if err != nil && pairCtx.Err() != nil {
			return pairCtx.Err()
		}
		if err == nil && !*statusJSON {
			fmt.Fprintln(os.Stdout, "Reconnected. Your saved archive is ready to sync.")
		}
		return err
	case "watch":
		if kind != "live" {
			return fmt.Errorf("live sync requires a paired live archive")
		}
		settings, err := archive.ReadSettings(store.Dir)
		if err != nil {
			return err
		}
		cutoff = settings.Cutoff(cutoff, time.Now().UTC())
		watchCtx, cancel := context.WithCancel(ctx)
		defer cancel()
		var commands chan archive.SendCommand
		if *commandsStdin {
			commands = make(chan archive.SendCommand)
			go func() { live.ReadCommands(watchCtx, os.Stdin, commands); cancel() }()
		} else if *parentStdin {
			go func() { _, _ = io.Copy(io.Discard, os.Stdin); cancel() }()
		}
		// A parent exit, sleep or SIGTERM must not leave an orphaned network
		// client, even if an upstream media request ignores cancellation.
		go func() { <-watchCtx.Done(); time.Sleep(5 * time.Second); os.Exit(0) }()
		return live.Watch(watchCtx, store, live.Options{Commands: commands, Since: cutoff, MaxPages: *pages, ConversationLimit: *convLimit, Media: *media, MediaBudget: *mediaBudget << 20, RetentionDays: settings.RetentionDays}, os.Stdout)
	case "pair":
		stats, err := store.Stats()
		if err != nil {
			return err
		}
		if stats.Messages > 0 || stats.Conversations > 0 {
			return fmt.Errorf("this archive already contains history; use relink to verify the original account and phone")
		}
		if err = store.SetMeta("kind", "live"); err != nil {
			return err
		}
		pairCtx, cancel := context.WithTimeout(ctx, 10*time.Minute)
		defer cancel()
		if *parentStdin {
			go func() { _, _ = io.Copy(io.Discard, os.Stdin); cancel() }()
		}
		go func() { <-pairCtx.Done(); time.Sleep(5 * time.Second); os.Exit(1) }()
		var known []archive.PairingIdentity
		for _, path := range existingArchives {
			identity, readErr := archive.ReadPairingIdentity(path)
			if readErr != nil {
				return errors.New("an existing account archive could not be checked; restore access before adding an account")
			}
			if identity.Valid() {
				known = append(known, identity)
			}
		}
		err = google.PairWithStatus(pairCtx, store, known, func(status google.PairingStatus) {
			if *statusJSON {
				_ = json.NewEncoder(os.Stdout).Encode(status)
			} else if status.Emoji != "" {
				fmt.Fprintf(os.Stdout, "On your phone, confirm this emoji in Google Messages: %s\n", status.Emoji)
			}
		})
		if err != nil && pairCtx.Err() != nil {
			return pairCtx.Err()
		}
		if err == nil && !*statusJSON {
			fmt.Fprintln(os.Stdout, "Paired. Session saved in this Mac's Keychain.")
		}
		return err
	case "status":
		return printStats(store)
	case "search":
		messages, err := store.Search(strings.Join(fs.Args(), " "), *conversation, *limit)
		if err != nil {
			return err
		}
		// Never export media decryption keys or protocol identifiers beyond local IDs.
		for i := range messages {
			for j := range messages[i].Attachments {
				messages[i].Attachments[j].Key = nil
				messages[i].Attachments[j].MediaID = ""
			}
		}
		return printJSON(messages)
	case "sync", "media":
		if err = store.SetMeta("kind", "live"); err != nil {
			return err
		}
		fmt.Fprintln(os.Stderr, "Connecting to your paired Pixel…")
		c, err := google.Connect(ctx, store)
		if err != nil {
			return err
		}
		defer c.Close()
		c.MediaProgress = func(message string) { fmt.Fprintln(os.Stderr, message) }
		// Persist rotated credentials even when an import is interrupted.
		defer func() {
			saveCtx, cancel := context.WithTimeout(context.Background(), 10*time.Second)
			defer cancel()
			if err := c.Save(saveCtx); err != nil {
				fmt.Fprintln(os.Stderr, "Pairing refresh could not be saved to Keychain.")
			}
		}()
		if command == "media" {
			fmt.Fprintln(os.Stderr, "Fetching originals for already archived attachments…")
			if err = c.Download(ctx, store, cutoff, *media, *mediaBudget<<20); err != nil {
				return err
			}
			return printStats(store)
		}
		inventory := "unverified: upstream conversation-list helper has no pagination argument; inbox and archive requests are bounded"
		if err = store.SetMeta("inventory", inventory); err != nil {
			return err
		}
		fmt.Fprintf(os.Stderr, "Importing since %s UTC. Conversation inventory remains unverified.\n", *since)
		folders := []gmproto.ListConversationsRequest_Folder{gmproto.ListConversationsRequest_INBOX, gmproto.ListConversationsRequest_ARCHIVE}
		failures := 0
		for _, folder := range folders {
			conversations, err := c.Conversations(ctx, folder, *convLimit)
			if err != nil {
				fmt.Fprintf(os.Stderr, "%s listing failed: %v\n", folder.String(), err)
				failures++
				continue
			}
			fmt.Fprintf(os.Stderr, "%s returned %d conversations (requested %d).\n", folder.String(), len(conversations), *convLimit)
			for i, conv := range conversations {
				if ctx.Err() != nil {
					return ctx.Err()
				}
				if err = store.PutConversation(conv); err != nil {
					return err
				}
				p, err := history.Import(ctx, store, c, conv.ID, history.Options{Since: cutoff, MaxPages: *pages, Resume: *resume, LatestMessage: conv.LastMessage})
				fmt.Fprintf(os.Stderr, "%s %d/%d: %s, %d pages\n", folder.String(), i+1, len(conversations), p.State, p.Pages)
				if err != nil {
					failures++
					if ctx.Err() != nil {
						return ctx.Err()
					}
				}
			}
		}
		if err = c.Download(ctx, store, cutoff, *media, *mediaBudget<<20); err != nil {
			return err
		}
		if err = printStats(store); err != nil {
			return err
		}
		if failures > 0 {
			return fmt.Errorf("%d history/listing operations were incomplete; see status before interpreting search coverage", failures)
		}
		return nil
	}
	return nil
}

func printJSON(value any) error {
	e := json.NewEncoder(os.Stdout)
	e.SetIndent("", "  ")
	return e.Encode(value)
}
func printStats(store *archive.Store) error {
	stats, err := store.Stats()
	if err != nil {
		return err
	}
	return printJSON(stats)
}

type demoSource struct{ messages []archive.Message }

func (s demoSource) Fetch(ctx context.Context, id string, cursor json.RawMessage) (history.Page, error) {
	if err := ctx.Err(); err != nil {
		return history.Page{}, err
	}
	if len(cursor) > 0 {
		return history.Page{}, nil
	}
	return history.Page{Messages: s.messages, Cursor: json.RawMessage(`{"last":"demo-end"}`)}, nil
}
func seedDemo(ctx context.Context, store *archive.Store, cutoff time.Time) error {
	now := time.Now().UTC().Truncate(time.Second)
	conversations := []archive.Conversation{
		{ID: "demo-coffee", Name: "Alex (demo)", Folder: "INBOX", LastMessage: now},
		{ID: "demo-trip", Name: "Sam (demo)", Folder: "ARCHIVE", LastMessage: now.Add(-48 * time.Hour)},
	}
	datasets := [][]archive.Message{
		{
			{ID: "demo-1", ConversationID: "demo-coffee", Timestamp: now, Body: "Coffee at the harbour tomorrow?", Sender: "Alex", Transport: "RCS", Status: "INCOMING_COMPLETE", Reactions: []archive.Reaction{{Emoji: "👍", Participants: []string{"demo-me"}}}},
			{ID: "demo-2", ConversationID: "demo-coffee", Timestamp: now.Add(-time.Hour), Body: "The booking reference is SYD2048.", Sender: "Me", Outgoing: true, Transport: "SMS", Status: "OUTGOING_COMPLETE"},
			{ID: "demo-old", ConversationID: "demo-coffee", Timestamp: cutoff.Add(-24 * time.Hour), Body: "This old message should stay outside the requested archive.", Sender: "Alex", Transport: "SMS", Status: "INCOMING_COMPLETE"},
		},
		{
			{ID: "demo-3", ConversationID: "demo-trip", Timestamp: now.Add(-48 * time.Hour), Body: "Photos from the coastal walk — two attachments.", Sender: "Sam", Transport: "RCS", Status: "INCOMING_COMPLETE", Attachments: []archive.Attachment{{ID: "demo-photo-1", Name: "coast.jpg", MIME: "image/jpeg", State: "demo_metadata_only"}, {ID: "demo-photo-2", Name: "walk.jpg", MIME: "image/jpeg", State: "demo_metadata_only"}}},
			{ID: "demo-4", ConversationID: "demo-trip", Timestamp: now.AddDate(0, -6, 0), Body: "Our Blue Mountains cabin booking is confirmed.", Sender: "Sam", Transport: "SMS", Status: "INCOMING_COMPLETE"},
		},
	}
	for i, c := range conversations {
		if err := store.PutConversation(c); err != nil {
			return err
		}
		if _, err := history.Import(ctx, store, demoSource{datasets[i]}, c.ID, history.Options{Since: cutoff, MaxPages: 10}); err != nil {
			return err
		}
	}
	if err := store.SetMeta("inventory", "synthetic demo only; no connection to Google"); err != nil {
		return err
	}
	fmt.Fprintln(os.Stderr, "Created synthetic demo data. No Google account or real messages were accessed.")
	return printStats(store)
}

type archivePaths []string

func (p *archivePaths) String() string { return "account archive paths" }
func (p *archivePaths) Set(value string) error {
	if len(*p) >= 100 {
		return errors.New("too many account archives")
	}
	*p = append(*p, value)
	return nil
}
