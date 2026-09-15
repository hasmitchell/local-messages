package archive

import (
	"database/sql"
	"encoding/json"
	"fmt"
	"net/url"
	"os"
	"path/filepath"
	"strconv"
	"strings"
	"time"

	_ "github.com/mattn/go-sqlite3"
)

type Attachment struct {
	ID       string `json:"id"`
	ActionID string `json:"action_id,omitempty"`
	Name     string `json:"name"`
	MIME     string `json:"mime"`
	Size     int64  `json:"size"`
	MediaID  string `json:"media_id,omitempty"`
	Key      []byte `json:"key,omitempty"`
	Path     string `json:"path,omitempty"`
	State    string `json:"state"`
	// Source is "sent" for an original kept from this Mac's own upload.
	Source string `json:"source,omitempty"`
	// Failed original lookups back off so the phone is not asked again every batch.
	Attempts    int   `json:"attempts,omitempty"`
	NextAttempt int64 `json:"next_attempt,omitempty"`
}

// Due reports whether an attachment may be requested from the phone now.
func (a Attachment) Due(now time.Time) bool {
	return a.NextAttempt == 0 || now.UnixMicro() >= a.NextAttempt
}

// RecordFailure schedules the next lookup: 1 hour, then 6, then a day, then weekly.
func (a *Attachment) RecordFailure(now time.Time) {
	a.Attempts++
	delay := 7 * 24 * time.Hour
	switch a.Attempts {
	case 1:
		delay = time.Hour
	case 2:
		delay = 6 * time.Hour
	case 3:
		delay = 24 * time.Hour
	}
	a.NextAttempt = now.Add(delay).UnixMicro()
}

type Reaction struct {
	Emoji        string   `json:"emoji"`
	Participants []string `json:"participants"`
}

type Message struct {
	ClientID       string       `json:"client_id,omitempty"`
	ID             string       `json:"id"`
	ConversationID string       `json:"conversation_id"`
	Timestamp      time.Time    `json:"timestamp"`
	Body           string       `json:"body"`
	Sender         string       `json:"sender"`
	Outgoing       bool         `json:"outgoing"`
	Transport      string       `json:"transport"`
	Status         string       `json:"status"`
	ReplyTo        string       `json:"reply_to,omitempty"`
	Reactions      []Reaction   `json:"reactions,omitempty"`
	Attachments    []Attachment `json:"attachments,omitempty"`
}

type Conversation struct {
	ID           string        `json:"id"`
	Name         string        `json:"name"`
	Folder       string        `json:"folder"`
	LastMessage  time.Time     `json:"last_message"`
	Unread       bool          `json:"unread"`
	Participants []Participant `json:"participants,omitempty"`
}

type Participant struct {
	ID        string `json:"id"`
	Name      string `json:"name"`
	Number    string `json:"number"`
	IsMe      bool   `json:"is_me"`
	ContactID string `json:"contact_id,omitempty"`
}

type Progress struct {
	ConversationID string          `json:"conversation_id"`
	Since          time.Time       `json:"since"`
	Cursor         json.RawMessage `json:"cursor,omitempty"`
	State          string          `json:"state"`
	Pages          int             `json:"pages"`
	Oldest         *time.Time      `json:"oldest,omitempty"`
}

type Stats struct {
	Conversations int            `json:"conversations"`
	Messages      int            `json:"messages"`
	Oldest        string         `json:"oldest,omitempty"`
	Newest        string         `json:"newest,omitempty"`
	Attachments   map[string]int `json:"attachments"`
	HistoryStates map[string]int `json:"history_states"`
	Inventory     string         `json:"inventory"`
}

type Store struct {
	db  *sql.DB
	Dir string
}

func Open(dir string) (*Store, error) {
	dir, err := filepath.Abs(dir)
	if err != nil {
		return nil, err
	}
	if err = os.MkdirAll(dir, 0700); err != nil {
		return nil, err
	}
	if err = os.Chmod(dir, 0700); err != nil {
		return nil, err
	}
	file := filepath.Join(dir, "archive.db")
	f, err := os.OpenFile(file, os.O_CREATE|os.O_RDWR, 0600)
	if err != nil {
		return nil, err
	}
	if err = f.Chmod(0600); err != nil {
		f.Close()
		return nil, err
	}
	if err = f.Close(); err != nil {
		return nil, err
	}
	u := url.URL{Scheme: "file", Path: file}
	db, err := sql.Open("sqlite3", u.String()+"?_journal_mode=WAL&_busy_timeout=5000&_foreign_keys=on&_secure_delete=on")
	if err != nil {
		return nil, err
	}
	db.SetMaxOpenConns(1)
	s := &Store{db: db, Dir: dir}
	_, err = db.Exec(`
      CREATE TABLE IF NOT EXISTS conversations(id TEXT PRIMARY KEY, name TEXT NOT NULL, folder TEXT NOT NULL, last_message INTEGER NOT NULL, unread INTEGER NOT NULL);
      CREATE TABLE IF NOT EXISTS messages(id TEXT PRIMARY KEY, conversation_id TEXT NOT NULL, timestamp INTEGER NOT NULL, body TEXT NOT NULL, sender TEXT NOT NULL, payload BLOB NOT NULL);
      CREATE INDEX IF NOT EXISTS messages_conversation_time ON messages(conversation_id,timestamp);
      CREATE VIRTUAL TABLE IF NOT EXISTS message_search USING fts5(body,sender,content='messages',content_rowid='rowid',tokenize='unicode61 remove_diacritics 2');
      CREATE TRIGGER IF NOT EXISTS messages_insert AFTER INSERT ON messages BEGIN
        INSERT INTO message_search(rowid,body,sender) VALUES(new.rowid,new.body,new.sender);
      END;
      CREATE TRIGGER IF NOT EXISTS messages_delete AFTER DELETE ON messages BEGIN
        INSERT INTO message_search(message_search,rowid,body,sender) VALUES('delete',old.rowid,old.body,old.sender);
      END;
      CREATE TRIGGER IF NOT EXISTS messages_update AFTER UPDATE ON messages BEGIN
        INSERT INTO message_search(message_search,rowid,body,sender) VALUES('delete',old.rowid,old.body,old.sender);
        INSERT INTO message_search(rowid,body,sender) VALUES(new.rowid,new.body,new.sender);
      END;
      CREATE TABLE IF NOT EXISTS outbox(id TEXT PRIMARY KEY,conversation_id TEXT NOT NULL,body TEXT NOT NULL,state TEXT NOT NULL,reason TEXT NOT NULL,created INTEGER NOT NULL,updated INTEGER NOT NULL,remote_id TEXT NOT NULL);
      CREATE INDEX IF NOT EXISTS outbox_conversation ON outbox(conversation_id,created);
      CREATE TABLE IF NOT EXISTS arrivals(sequence INTEGER PRIMARY KEY AUTOINCREMENT,message_id TEXT NOT NULL UNIQUE,conversation_id TEXT NOT NULL,timestamp INTEGER NOT NULL);
      CREATE TABLE IF NOT EXISTS progress(conversation_id TEXT PRIMARY KEY,payload BLOB NOT NULL);
      CREATE TABLE IF NOT EXISTS metadata(key TEXT PRIMARY KEY,value TEXT NOT NULL);
      CREATE TABLE IF NOT EXISTS conversation_details(id TEXT PRIMARY KEY,payload BLOB NOT NULL);
      CREATE TABLE IF NOT EXISTS outbox_commands(id TEXT PRIMARY KEY,payload BLOB NOT NULL);
      CREATE TABLE IF NOT EXISTS media_gc(path TEXT PRIMARY KEY);
      CREATE TABLE IF NOT EXISTS participant_avatars(participant_id TEXT PRIMARY KEY,path TEXT NOT NULL,hash TEXT NOT NULL,updated INTEGER NOT NULL);
      CREATE TABLE IF NOT EXISTS contacts(participant_id TEXT PRIMARY KEY,name TEXT NOT NULL,number TEXT NOT NULL,contact_id TEXT NOT NULL,updated INTEGER NOT NULL);
    `)
	if err != nil {
		db.Close()
		return nil, fmt.Errorf("initialise SQLite with FTS5: %w", err)
	}
	return s, nil
}

func (s *Store) Close() error { return s.db.Close() }

// SetUnread mirrors a read state the phone has just accepted, so the sidebar
// does not wait for the next inventory pass.
func (s *Store) SetUnread(id string, unread bool) error {
	_, err := s.db.Exec(`UPDATE conversations SET unread=? WHERE id=?`, unread, id)
	return err
}

// UpdateUnread applies a read-state change reported by the phone, unless the
// report refers to older activity than the conversation already has saved.
func (s *Store) UpdateUnread(id string, unread bool, lastMessage time.Time) error {
	_, err := s.db.Exec(`UPDATE conversations SET unread=? WHERE id=? AND last_message<=?`, unread, id, lastMessage.UnixMicro())
	return err
}

func (s *Store) SetMeta(key, value string) error {
	_, err := s.db.Exec(`INSERT INTO metadata(key,value) VALUES(?,?) ON CONFLICT(key) DO UPDATE SET value=excluded.value`, key, value)
	return err
}
func (s *Store) Meta(key string) (string, error) {
	var value string
	err := s.db.QueryRow(`SELECT value FROM metadata WHERE key=?`, key).Scan(&value)
	if err == sql.ErrNoRows {
		return "", nil
	}
	return value, err
}

func (s *Store) PutConversation(c Conversation) error {
	if c.ID == "" {
		return fmt.Errorf("conversation has no ID")
	}
	tx, err := s.db.Begin()
	if err != nil {
		return err
	}
	defer tx.Rollback()
	_, err = tx.Exec(`INSERT INTO conversations VALUES(?,?,?,?,?) ON CONFLICT(id) DO UPDATE SET name=excluded.name,folder=excluded.folder,last_message=excluded.last_message,unread=excluded.unread`, c.ID, c.Name, c.Folder, c.LastMessage.UnixMicro(), c.Unread)
	if err != nil {
		return err
	}
	if c.Participants != nil {
		data, err := json.Marshal(c.Participants)
		if err != nil {
			return err
		}
		if _, err = tx.Exec(`INSERT INTO conversation_details VALUES(?,?) ON CONFLICT(id) DO UPDATE SET payload=excluded.payload`, c.ID, data); err != nil {
			return err
		}
	}
	return tx.Commit()
}

// A fetched page and its cursor commit together. A crash can safely replay a page.
func (s *Store) PutPage(messages []Message, p Progress) error {
	tx, err := s.db.Begin()
	if err != nil {
		return err
	}
	defer tx.Rollback()
	if err = putMessages(tx, messages); err != nil {
		return err
	}
	b, err := json.Marshal(p)
	if err != nil {
		return err
	}
	_, err = tx.Exec(`INSERT INTO progress VALUES(?,?) ON CONFLICT(conversation_id) DO UPDATE SET payload=excluded.payload`, p.ConversationID, b)
	if err != nil {
		return err
	}
	return tx.Commit()
}

// Live writes deliberately leave the one-time history import cursor untouched.
func (s *Store) PutUpdates(messages []Message) error {
	tx, err := s.db.Begin()
	if err != nil {
		return err
	}
	defer tx.Rollback()
	if err = putMessages(tx, messages); err != nil {
		return err
	}
	for _, m := range messages {
		_, err = tx.Exec(`INSERT INTO conversations VALUES(?,?,'INBOX',?,0)
            ON CONFLICT(id) DO UPDATE SET last_message=max(last_message,excluded.last_message)`, m.ConversationID, m.Sender, m.Timestamp.UnixMicro())
		if err != nil {
			return err
		}
	}
	return tx.Commit()
}

func putMessages(tx *sql.Tx, messages []Message) error {
	var floorText string
	err := tx.QueryRow(`SELECT value FROM metadata WHERE key='active_retention_floor'`).Scan(&floorText)
	if err != nil && err != sql.ErrNoRows {
		return err
	}
	var floor int64
	if floorText != "" {
		floor, err = strconv.ParseInt(floorText, 10, 64)
		if err != nil {
			return fmt.Errorf("invalid local retention boundary")
		}
	}
	for _, m := range messages {
		if m.ID == "" || m.ConversationID == "" || m.Timestamp.IsZero() {
			return fmt.Errorf("message lacks ID, conversation or timestamp")
		}
		if floor != 0 && m.Timestamp.UnixMicro() < floor {
			continue
		}
		// Keep downloaded originals when an overlapping page is fetched again.
		var previous []byte
		err := tx.QueryRow(`SELECT payload FROM messages WHERE id=?`, m.ID).Scan(&previous)
		if err != nil && err != sql.ErrNoRows {
			return err
		}
		if len(previous) > 0 {
			var old Message
			if err = json.Unmarshal(previous, &old); err != nil {
				return err
			}
			for i := range m.Attachments {
				for _, a := range old.Attachments {
					fresh := &m.Attachments[i]
					if fresh.ID != a.ID || a.State != "downloaded_original" || (a.Source != "sent" && fresh.MediaID != "" && fresh.MediaID != a.MediaID) {
						continue
					}
					// History can omit references that were resolved separately by a
					// full-size request. Keep those originals across a text refresh.
					// A different, nonempty media ID still invalidates the cached file,
					// except for a file sent from this Mac: those bytes are the original.
					fresh.Source = a.Source
					if fresh.MediaID == "" {
						fresh.MediaID = a.MediaID
						fresh.Key = a.Key
						fresh.Size = a.Size
						fresh.MIME = a.MIME
					} else if len(fresh.Key) == 0 {
						fresh.Key = a.Key
					}
					if fresh.ActionID == "" {
						fresh.ActionID = a.ActionID
					}
					fresh.Path = a.Path
					fresh.State = a.State
					break
				}
			}
		}
		if len(previous) == 0 && !m.Outgoing && strings.HasPrefix(m.Status, "INCOMING_") && !strings.Contains(m.Status, "DELETED") && (!strings.Contains(m.Status, "DOWNLOAD") && !strings.Contains(m.Status, "FAILED")) {
			if _, err = tx.Exec(`INSERT OR IGNORE INTO arrivals(message_id,conversation_id,timestamp) VALUES(?,?,?)`, m.ID, m.ConversationID, m.Timestamp.UnixMicro()); err != nil {
				return err
			}
		}
		if m.Outgoing && m.ClientID != "" {
			if _, err = tx.Exec(`UPDATE outbox SET state='confirmed',remote_id=?,updated=? WHERE id=? AND conversation_id=? AND (state!='confirmed' OR remote_id!=?)`, m.ID, time.Now().UnixMicro(), m.ClientID, m.ConversationID, m.ID); err != nil {
				return err
			}
		}
		b, err := json.Marshal(m)
		if err != nil {
			return err
		}
		_, err = tx.Exec(`INSERT INTO messages(id,conversation_id,timestamp,body,sender,payload) VALUES(?,?,?,?,?,?) ON CONFLICT(id) DO UPDATE SET conversation_id=excluded.conversation_id,timestamp=excluded.timestamp,body=excluded.body,sender=excluded.sender,payload=excluded.payload WHERE messages.payload != excluded.payload`, m.ID, m.ConversationID, m.Timestamp.UnixMicro(), m.Body, m.Sender, b)
		if err != nil {
			return err
		}
	}
	return nil
}

func (s *Store) Latest(id string) (time.Time, error) {
	var stamp int64
	err := s.db.QueryRow(`SELECT coalesce(max(timestamp),0) FROM messages WHERE conversation_id=?`, id).Scan(&stamp)
	if stamp == 0 {
		return time.Time{}, err
	}
	return time.UnixMicro(stamp).UTC(), err
}

func (s *Store) Progress(id string) (Progress, error) {
	var b []byte
	var p Progress
	err := s.db.QueryRow(`SELECT payload FROM progress WHERE conversation_id=?`, id).Scan(&b)
	if err == sql.ErrNoRows {
		return p, nil
	}
	if err != nil {
		return p, err
	}
	err = json.Unmarshal(b, &p)
	return p, err
}

// Literal user input is quoted for FTS syntax as well as bound as a SQL value.
func LiteralQuery(q string) string {
	terms := strings.Fields(q)
	for i, t := range terms {
		terms[i] = `"` + strings.ReplaceAll(t, `"`, `""`) + `"`
	}
	return strings.Join(terms, " AND ")
}

func (s *Store) Search(query, conversation string, limit int) ([]Message, error) {
	q := LiteralQuery(query)
	if q == "" {
		return []Message{}, nil
	}
	if limit < 1 || limit > 1000 {
		return nil, fmt.Errorf("limit must be between 1 and 1000")
	}
	rows, err := s.db.Query(`SELECT m.payload FROM message_search JOIN messages m ON m.rowid=message_search.rowid WHERE message_search MATCH ? AND (?='' OR m.conversation_id=?) ORDER BY m.timestamp DESC LIMIT ?`, q, conversation, conversation, limit)
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	result := []Message{}
	for rows.Next() {
		var b []byte
		var m Message
		if err = rows.Scan(&b); err != nil {
			return nil, err
		}
		if err = json.Unmarshal(b, &m); err != nil {
			return nil, err
		}
		result = append(result, m)
	}
	return result, rows.Err()
}

func (s *Store) PendingMedia(since time.Time) ([]Message, error) {
	rows, err := s.db.Query(`SELECT payload FROM messages WHERE timestamp>=? ORDER BY timestamp DESC`, since.UnixMicro())
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	result := []Message{}
	for rows.Next() {
		var b []byte
		var m Message
		if err = rows.Scan(&b); err != nil {
			return nil, err
		}
		if err = json.Unmarshal(b, &m); err != nil {
			return nil, err
		}
		if len(m.Attachments) > 0 {
			result = append(result, m)
		}
	}
	return result, rows.Err()
}

// Media downloads can finish after a live text edit or reaction. Merge only
// matching attachment fields into the current row; never restore stale text.
func (s *Store) UpdateMedia(m Message) error {
	tx, err := s.db.Begin()
	if err != nil {
		return err
	}
	defer tx.Rollback()
	var data []byte
	err = tx.QueryRow(`SELECT payload FROM messages WHERE id=?`, m.ID).Scan(&data)
	if err == sql.ErrNoRows {
		for _, a := range m.Attachments {
			if a.State == "downloaded_original" && a.Path != "" {
				if _, err = tx.Exec(`INSERT OR IGNORE INTO media_gc VALUES(?)`, a.Path); err != nil {
					return err
				}
			}
		}
		return tx.Commit()
	}
	if err != nil {
		return err
	}
	var current Message
	if err = json.Unmarshal(data, &current); err != nil {
		return err
	}
	for i := range current.Attachments {
		fresh := &current.Attachments[i]
		for _, update := range m.Attachments {
			if fresh.ID != update.ID || (fresh.MediaID != "" && update.MediaID != "" && fresh.MediaID != update.MediaID) {
				continue
			}
			if (update.MediaID == "" && fresh.MediaID != "") || (fresh.State == "downloaded_original" && update.State != "downloaded_original") {
				continue
			}
			fresh.MediaID, fresh.Key, fresh.Size = update.MediaID, update.Key, update.Size
			fresh.MIME, fresh.Path, fresh.State = update.MIME, update.Path, update.State
			fresh.Source = update.Source
			fresh.Attempts, fresh.NextAttempt = update.Attempts, update.NextAttempt
			if update.ActionID != "" {
				fresh.ActionID = update.ActionID
			}
		}
	}
	data, err = json.Marshal(current)
	if err != nil {
		return err
	}
	_, err = tx.Exec(`UPDATE messages SET payload=? WHERE id=? AND payload!=?`, data, m.ID, data)
	if err != nil {
		return err
	}
	return tx.Commit()
}

func (s *Store) Stats() (Stats, error) {
	out := Stats{Attachments: map[string]int{}, HistoryStates: map[string]int{}}
	err := s.db.QueryRow(`SELECT count(*) FROM conversations`).Scan(&out.Conversations)
	if err != nil {
		return out, err
	}
	var oldest, newest sql.NullInt64
	err = s.db.QueryRow(`SELECT count(*),min(timestamp),max(timestamp) FROM messages`).Scan(&out.Messages, &oldest, &newest)
	if err != nil {
		return out, err
	}
	if oldest.Valid {
		out.Oldest = time.UnixMicro(oldest.Int64).UTC().Format(time.RFC3339)
		out.Newest = time.UnixMicro(newest.Int64).UTC().Format(time.RFC3339)
	}
	out.Inventory, err = s.Meta("inventory")
	if err != nil {
		return out, err
	}
	if out.Inventory == "" {
		out.Inventory = "not_started"
	}
	rows, err := s.db.Query(`SELECT payload FROM progress`)
	if err != nil {
		return out, err
	}
	for rows.Next() {
		var b []byte
		var p Progress
		if err = rows.Scan(&b); err != nil {
			rows.Close()
			return out, err
		}
		if err = json.Unmarshal(b, &p); err != nil {
			rows.Close()
			return out, err
		}
		out.HistoryStates[p.State]++
	}
	err = rows.Err()
	rows.Close()
	if err != nil {
		return out, err
	}
	media, err := s.PendingMedia(time.Unix(0, 0))
	if err != nil {
		return out, err
	}
	for _, m := range media {
		for _, a := range m.Attachments {
			out.Attachments[a.State]++
		}
	}
	return out, nil
}

// DB exposes the connection for tests and diagnostics.
func (s *Store) DB() *sql.DB { return s.db }
