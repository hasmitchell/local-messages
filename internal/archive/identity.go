package archive

import (
	"database/sql"
	"encoding/hex"
	"encoding/json"
	"errors"
	"net/url"
	"path/filepath"
)

var ErrIdentityMismatch = errors.New("pairing identity does not match this archive")

// Only fingerprints are stored here; cookies and account names stay out of SQLite.
type PairingIdentity struct {
	Version int    `json:"version"`
	Account string `json:"account"`
	Phone   string `json:"phone"`
}

func (p PairingIdentity) Valid() bool {
	a, ea := hex.DecodeString(p.Account)
	b, eb := hex.DecodeString(p.Phone)
	return p.Version == 1 && ea == nil && eb == nil && len(a) == 32 && len(b) == 32
}

func (s *Store) PairingIdentity() (PairingIdentity, error) {
	var identity PairingIdentity
	value, err := s.Meta("pairing_identity")
	if err != nil || value == "" {
		return identity, err
	}
	if json.Unmarshal([]byte(value), &identity) != nil || !identity.Valid() {
		return identity, ErrIdentityMismatch
	}
	return identity, nil
}

// Bind once. A later process cannot silently change the owner of an archive.
func (s *Store) BindPairingIdentity(identity PairingIdentity) error {
	if !identity.Valid() {
		return ErrIdentityMismatch
	}
	data, err := json.Marshal(identity)
	if err != nil {
		return err
	}
	tx, err := s.db.Begin()
	if err != nil {
		return err
	}
	defer tx.Rollback()
	if _, err = tx.Exec(`INSERT OR IGNORE INTO metadata(key,value) VALUES('pairing_identity',?)`, string(data)); err != nil {
		return err
	}
	var saved string
	if err = tx.QueryRow(`SELECT value FROM metadata WHERE key='pairing_identity'`).Scan(&saved); err != nil {
		return err
	}
	var original PairingIdentity
	if json.Unmarshal([]byte(saved), &original) != nil || original != identity {
		return ErrIdentityMismatch
	}
	return tx.Commit()
}

// A new pairing may invalidate opaque pagination cursors. Keep completed
// coverage and time-based live checkpoints, but restart unfinished page walks.
func (s *Store) ResetIncompleteHistory() error {
	tx, err := s.db.Begin()
	if err != nil {
		return err
	}
	defer tx.Rollback()
	rows, err := tx.Query(`SELECT payload FROM progress`)
	if err != nil {
		return err
	}
	var changes []Progress
	for rows.Next() {
		var data []byte
		var p Progress
		if err = rows.Scan(&data); err != nil {
			rows.Close()
			return err
		}
		if err = json.Unmarshal(data, &p); err != nil {
			rows.Close()
			return err
		}
		if p.State != "boundary_reached" && p.State != "source_exhausted" && len(p.Cursor) > 0 {
			p.Cursor = nil
			p.Pages = 0
			p.Oldest = nil
			p.State = "relink_restart"
			changes = append(changes, p)
		}
	}
	err = rows.Err()
	rows.Close()
	if err != nil {
		return err
	}
	for _, p := range changes {
		data, err := json.Marshal(p)
		if err != nil {
			return err
		}
		if _, err = tx.Exec(`UPDATE progress SET payload=? WHERE conversation_id=?`, data, p.ConversationID); err != nil {
			return err
		}
	}
	return tx.Commit()
}

// Read fingerprints without opening a writer or migrating another archive.
func ReadPairingIdentity(dir string) (PairingIdentity, error) {
	absolute, err := filepath.Abs(dir)
	if err != nil {
		return PairingIdentity{}, err
	}
	file := url.URL{Scheme: "file", Path: filepath.Join(absolute, "archive.db")}
	db, err := sql.Open("sqlite3", file.String()+"?mode=ro&_query_only=1&_busy_timeout=1500")
	if err != nil {
		return PairingIdentity{}, err
	}
	defer db.Close()
	return (&Store{db: db, Dir: absolute}).PairingIdentity()
}
